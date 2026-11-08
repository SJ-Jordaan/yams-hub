# Integration spec: Seerr + Jellyfin + Jellystat

This is the spec for whoever implements the `yams-hub` gateway (Dart/shelf). Everything below was checked on the live
Zenith NAS on 2026-11-08. Source of each fact:

- **live**: a real GET (plus read-only stats POSTs, see section 3.1) against the running containers.
- **source**: read from the code inside the container (`/app/server/**` in seerr, `/app/backend/**` in jellystat),
  or from Jellyfin's own `/api-docs/openapi.json` (12.4.0).

No write endpoint was called. Write shapes come from source and OpenAPI only. Secrets are shown as `<…>`.

Fixtures for every captured response are in `fixtures/seerr/` (index in section 6). Arrays are cut to 5 items (TV
`seasons` keep up to 10). Emails are set to `redacted@example.com`. Field names and nesting are unchanged.

---

## 0. Quick reference

| Service | Version (live) | Internal base URL (yams_network) | Host-published (NAS LAN) | Auth |
|---|---|---|---|---|
| Seerr (Jellyseerr fork) | 3.5.1 (`ghcr.io/seerr-team/seerr:latest`, commit 564bfb0) | `http://seerr:5055/api/v1` | `http://192.168.10.183:5055/api/v1` | `X-Api-Key: <SEERR_KEY>` (+ optional `X-API-User: <seerrUserId>`) |
| Jellyfin | 12.4.0 (`lscr.io/linuxserver/jellyfin`) | `http://jellyfin:8096` | `http://192.168.10.183:8096` | `Authorization: MediaBrowser Token="<JELLYFIN_KEY>"` |
| Jellystat | 1.1.12 (`cyfershepard/jellystat`) | `http://jellystat:3000` | `http://192.168.10.183:3002` | `x-api-token: <JELLYSTAT_KEY>` |

Secrets on the NAS are in `/opt/yams/monitoring/secrets/homepage.env`: `HOMEPAGE_VAR_SEERR_KEY`,
`HOMEPAGE_VAR_JELLYFIN_KEY` and `HOMEPAGE_VAR_JELLYSTAT_KEY`. The Seerr key also sits at `.main.apiKey` in
`/app/config/settings.json` inside the seerr container (host path `/volume1/mediashare/config/jellyseer/settings.json`;
the folder is spelled **jellyseer**, not seerr).

Shared identifiers in this install:

- Jellyfin serverId: `79315eab3c4c401f8391d5c26210b6d7`. It appears in Seerr `mediaUrl` and Jellystat `ServerId`.
- Libraries. The ids are the same in Jellyfin, Seerr settings and Jellystat:
  - Movies `f137a2dd21bbc1b99aa5c0f6bf02a805` (`movies`)
  - Shows `a656b907eb3a73532e40e44b968d0225` (`tvshows`)
  - Music `7e64e319657a9516ec78490da03edccb`
  - Books `4e985111ed7f570b595204d82adb02f3`
- Seerr users:
  - id 1 "Paul Greyrat": admin, `permissions=2`, jellyfinUserId `4c0628aa…`
  - id 2 "Zenith Greyrat": `permissions=32`, REQUEST only, jellyfinUserId `8bed8d8c…`
  - Jellyfin also has "Rudeus Greyrat" and "Zonika". Neither is imported into Seerr.
- Seerr's Radarr/Sonarr server **id is `0`**. Never use a truthiness check on `serverId`.

---

## 1. Seerr (`/api/v1`)

### 1.1 Auth and which user a request belongs to

Source: `server/middleware/auth.ts`.

```ts
if (req.header('X-API-Key') === settings.main.apiKey) {
  let userId = 1;                        // "original administrator account"
  if (req.header('X-API-User')) userId = Number(req.header('X-API-User'));
  user = await userRepository.findOne({ where: { id: userId } });
}
```

- **Key only:** every call runs as **Seerr user id 1, the admin**. Requests created this way show "requested by Paul
  Greyrat" and are **auto-approved**.
- **Key plus `X-API-User: <id>`:** the call runs fully as that user, with that user's permission checks, visibility and
  quotas.
  - Live check: `GET /auth/me` with `X-API-User: 2` returned id 2, `permissions:32`.
  - Live check: `GET /request` with `X-API-User: 2` returned only that user's 2 requests (`requestedBy.id == 2`).
  - Requests made as user 2 are created as **PENDING** (status 1), because user 2 lacks AUTO_APPROVE.
- **Unknown `X-API-User` id:** `user` is null, so every `isAuthenticated()` route returns 403. A non-numeric value gives
  `NaN`, which is also not found and also 403.
- **Recommended gateway behaviour:**
  1. Map each hub user to a Seerr user once, with `GET /user/jellyfin/{jellyfinUserId}`. It accepts the dashed or
     undashed GUID (live, 200). An unknown id returns 404 `{"message":"User not found."}`.
  2. Send `X-API-User` on calls made on that user's behalf: requests, "my requests", issues.
  3. Send no `X-API-User` for admin actions: approve, decline, delete, the counts dashboard.
- **Alternative:** stay as admin and pass `"userId": <id>` in `POST /request`.
  - The request is attributed to that user.
  - Auto-approve is decided by the **caller** (`user`), not `requestUser`. So admin plus `userId` still gives an
    auto-approved request that shows the right requester.
  - Moving ownership needs MANAGE_USERS or MANAGE_REQUESTS (the admin has both).
- **Auth errors:**
  - No key at all: **401** from the OpenAPI validator, `{"message":"cookie 'connect.sid' required","errors":[…]}`
    (fixture `seerr_error_401_no_auth.json`).
  - Wrong key: **403** `{"status":403,"error":"You do not have permission to access this endpoint"}`
    (`seerr_error_403_bad_key.json`). Note this body has `error`, not `message`.
- `GET /status`, `GET /settings/public` and `/imageproxy/**` need no auth.

### 1.2 Error model, request validation and encoding

- Express 5 with `express-openapi-validator` (`validateRequests: true`, spec `/app/seerr-api.yml`, served as Swagger UI
  at `/api-docs`).
- Usual error body: `{"message": string, "errors"?: [{path, message, errorCode?}]}`. `errors` is only present on
  validator 400s.
- **Query-string encoding (empirical, important):**
  - The validator rejects any **reserved character left unencoded** in `query`, returning **400** `Parameter 'query'
    must be url encoded. Its value may not contain reserved characters.`
  - Live 400s: `the+office` (a `+` for space), `wow!`, `grey's`, `dune(2021)`, `a*b`, `tmdb:603`.
  - Live 200s: `the%20office`, `grey%27s`, `dune%282021%29`, `tmdb%3A603`, `a~b`.
  - **Dart gotcha:**
    - `Uri.encodeQueryComponent` turns spaces into `+`, which fails.
    - `Uri.encodeComponent` leaves `! ' ( ) *` unencoded, which also fails.
    - Use `Uri.encodeComponent(q)` followed by replacing `!`→`%21`, `'`→`%27`, `(`→`%28`, `)`→`%29`, `*`→`%2A`.
    - Build the URL string by hand, not with `Uri(queryParameters:)`.
- Enum query params are validated too. Example: `GET /request?filter=bogus` gives 400 `request/query/filter must be
  equal to one of the allowed values: all, approved, available, pending, processing, unavailable, failed, deleted,
  completed`.
- TMDB-backed lookups of an id that does not exist return **500**, not 404:
  - `GET /movie/999999999` gives 500 `{"message":"Unable to retrieve movie."}`.
  - `GET /tv/10545/season/99` gives 500 `{"message":"Unable to retrieve season."}`.
  - The gateway should map these to 404.
- A missing Seerr DB row gives 404, e.g. `GET /request/999999` → `{"message":"Request not found."}`.

### 1.3 Enums (source: `server/constants/*.ts`, `server/lib/permissions.ts`)

**MediaStatus** is used for `mediaInfo.status`, `status4k` and `mediaInfo.seasons[].status`:

| value | name | UI meaning |
|---|---|---|
| 1 | UNKNOWN | not requested / not tracked |
| 2 | PENDING | request awaiting approval |
| 3 | PROCESSING | approved, in Sonarr/Radarr, not downloaded |
| 4 | PARTIALLY_AVAILABLE | some seasons/episodes in Jellyfin |
| 5 | AVAILABLE | in Jellyfin |
| 6 | BLOCKLISTED | |
| 7 | DELETED | was available, removed (seen live on media rows 182/183) |

**MediaRequestStatus** is used for `request.status` **and** `request.seasons[].status`:

| value | name |
|---|---|
| 1 | PENDING |
| 2 | APPROVED |
| 3 | DECLINED |
| 4 | FAILED (failed to send to *arr; live: request 189) |
| 5 | COMPLETED |

**Gotcha:** two different enums share the field name `status`.
- `request.seasons[]` (SeasonRequest) uses **MediaRequestStatus**.
- `media.seasons[]` (Season) uses **MediaStatus**.

Live example from request 187: `request.status=2`, `request.seasons[0].status=2` (approved), `media.status=3`
(processing).

**IssueType:** 1 VIDEO, 2 AUDIO, 3 SUBTITLES, 4 OTHER. **IssueStatus:** 1 OPEN, 2 RESOLVED.

**userType:** 1 PLEX, 2 LOCAL, 3 JELLYFIN, 4 EMBY. Both live users are 3.

**Permission bitmask.** ADMIN (2) passes every check. Selected bits:

| bit | name | bit | name |
|---|---|---|---|
| 2 | ADMIN | 1024 | REQUEST_4K |
| 4 | MANAGE_SETTINGS | 8192 | REQUEST_ADVANCED (pick server/profile/folder) |
| 8 | MANAGE_USERS | 16384 | REQUEST_VIEW (see others' requests) |
| 16 | MANAGE_REQUESTS (approve/decline/delete) | 262144 / 524288 | REQUEST_MOVIE / REQUEST_TV |
| 32 | REQUEST | 1048576 | MANAGE_ISSUES |
| 64 | VOTE | 2097152 | VIEW_ISSUES |
| 128 | AUTO_APPROVE | 4194304 | CREATE_ISSUES |
| 256 / 512 | AUTO_APPROVE_MOVIE / _TV | 67108864 | RECENT_VIEW |

`settings.main.defaultPermissions = 32`. The full list is in `src/seerr/lib/permissions.ts` in the capture, and the
same code is in the container at `/app/server/lib/permissions.ts`.

### 1.4 Images

- Seerr returns bare TMDB paths, e.g. `"posterPath": "/n8V61f1v7idya4WJzGEJNoIp9iL.jpg"`. Paths can be `null`; this was
  seen live on an upcoming TV item's `backdropPath`.
- Direct TMDB: `https://image.tmdb.org/t/p/{size}{path}`. Live: w500 gave 200 `image/jpeg`, 113 KB, 1.2 s from the NAS.
  - Posters: `w92 w154 w185 w342 w500 w780 original`.
  - Backdrops: `w300 w780 w1280 original`.
  - Profiles: `w45 w185 h632 original`.
  - Seerr's own web UI uses `w300_and_h450_face` (posters) and `w1920_and_h800_multi_faces` (backdrops). TMDB accepts
    both.
- Through Seerr: `GET http://seerr:5055/imageproxy/tmdb/t/p/{size}{path}` needs no auth (live: 200 `image/jpg`).
  - `cacheImages` is `false` here, so this is a pass-through with a rate limit (20 req, 50 rps). It brings no benefit.
  - **Recommendation:** the app loads TMDB URLs directly. The gateway only builds them, or proxies with its own cache
    if offline/Tailscale-only phones must work without internet. They cannot; TMDB needs internet anyway.
- User avatars: `user.avatar` is a Seerr-relative path such as `/avatarproxy/4c0628aa…?v=1791693617000`. Fetch it as
  `http://seerr:5055{avatar}`. The gateway must proxy it, because the phone cannot reach seerr.

### 1.5 Search: `GET /search`

| param | type | notes |
|---|---|---|
| `query` | string, **required** | strict encoding, see 1.2. Missing gives 400 `request/query must have required property 'query'`. |
| `page` | int, 1-based | **Send it explicitly.** `page=0` or `page=999` returns `{"page":1,"totalPages":1,"totalResults":0,"results":[]}`, which reads as empty. TMDB caps at page 500. |
| `language` | ISO 639-1 | defaults to the user/server locale (`en`) |

- Special prefixes (`server/lib/search.ts`):
  - `tmdb:<id>` returns up to 3 results (movie, tv, person with that id). Live: `tmdb%3A603` gave The Matrix, Veronica's
    Closet and a person.
  - `imdb:tt…|nm…`, `tvdb:<id>`, `year:<yyyy>`. `year%3A1999` alone returned 0 results, so it needs other words too.
- Response: `{page:int, totalPages:int, totalResults:int, results:[…]}`. There are 20 results per page, and
  `mediaType` decides the shape:
  - `movie`: `id`(tmdb) `title` `originalTitle` `releaseDate` (`YYYY-MM-DD`, may be `""`) `overview` `posterPath?`
    `backdropPath?` `voteAverage` `voteCount` `popularity` `genreIds[]` `originalLanguage` `adult` `video`
    `mediaInfo?`
  - `tv`: `id` `name` `originalName` `firstAirDate` `originCountry[]` and the same common fields, plus `mediaInfo?`
  - `person`: `id` `name` `profilePath?` `popularity` `adult` `knownFor[]`. Filter persons out, or show them separately.
- `mediaInfo` is present only when Seerr has a DB row for that tmdbId. Read the status from it:
  `mediaInfo?.status ?? 1`.

```json
{"id":438631,"mediaType":"movie","title":"Dune","releaseDate":"2021-09-15","posterPath":"/v1tRXZ4JtD2Iv6fjkPvT4GiwslV.jpg",
 "voteAverage":7.786,"mediaInfo":{"id":79,"status":5,"status4k":1,"jellyfinMediaId":"4f5731b2c357273bf4002dd8d042a856",
 "mediaUrl":"http://192.168.10.183:8096/web/index.html#!/details?id=4f57…&context=home&serverId=7931…","downloadStatus":[]}}
```

Latency (live): about 230–700 ms uncached and about 20 ms when repeated, because Seerr caches TMDB.

### 1.6 Discover

All of these return `{page,totalPages,totalResults,results[]}`, 20 per page, with result items shaped as in 1.5. Live
latency is 200–330 ms.

| Feature | Endpoint | Params (all optional) |
|---|---|---|
| Trending (mixed) | `GET /discover/trending` | `page`, `mediaType=all\|movie\|tv`, `timeWindow=day\|week` (default day), `language` |
| Popular movies | `GET /discover/movies` | `page`, `sortBy` (default `popularity.desc`), `genre` (ids, comma-separated), `studio`, `keywords`, `excludeKeywords`, `primaryReleaseDateGte/Lte` (`YYYY-MM-DD`), `withRuntimeGte/Lte`, `voteAverageGte/Lte`, `voteCountGte/Lte`, `watchProviders`, `watchRegion`, `certification*` |
| Popular TV | `GET /discover/tv` | same as movies, using `firstAirDateGte/Lte` and `network`, plus `status` |
| Upcoming movies | `GET /discover/movies/upcoming` | `page`, `language` (release date ≥ today) |
| Upcoming TV | `GET /discover/tv/upcoming` | `page`, `language` (first air date ≥ today) |
| Genre sliders | `GET /discover/genreslider/movie`, `/discover/genreslider/tv` | `language` |
| Per genre/studio/network | `GET /discover/movies/genre/{id}`, `/discover/movies/studio/{id}`, `/discover/tv/genre/{id}`, `/discover/tv/network/{id}` | `page` |
| Seerr watchlist | `GET /discover/watchlist` | `page`. Returns `{page,totalPages,totalResults,results:[{id, ratingKey, title, mediaType, tmdbId, createdAt, requestedBy:User…}]}`. This is a **different item shape** (Seerr Watchlist rows, not TMDB results). |
| Genre names | `GET /genres/movie`, `GET /genres/tv` | returns `[{id:int,name:string}]` |

Gotchas:

- `/discover/movies` returns an extra `keywords: []` array.
- On `/discover/movies` and `/discover/tv`, the **`language` param filters by *original* language** (TMDB
  `with_original_language`). The display language comes from the user locale. On `trending` and `upcoming`,
  `language` is the display language.
- `totalPages` can be 500 or 1001 (TMDB reports more than it serves). Clamp infinite scroll at `min(totalPages, 500)`.
- Discover items include `mediaInfo` when known, and with `includeActiveRequest`, so the "Requested" or "Available"
  badge can be shown without extra calls.
- The admin-configured home sliders are at `GET /settings/discover`, which is admin only (fixture not kept; the response
  is sliders config). They can be used to copy the Seerr home layout.

### 1.7 Details

#### Movie: `GET /movie/{tmdbId}`

The response is about 100 KB, because it carries the full credits and watch providers for 60+ countries. **The gateway
should slim it.** Important fields:

- `id` (tmdb), `imdbId`, `title`, `originalTitle`, `tagline`, `overview`, `releaseDate`, `runtime` (min), `status`
  ("Released"…), `genres[{id,name}]`, `posterPath`, `backdropPath`, `voteAverage`, `voteCount`, `budget`, `revenue`
- `collection {id,name,posterPath,backdropPath}?`, `externalIds {imdbId,…}`, `onUserWatchlist:bool`
- `credits.cast[{id,name,character,profilePath,order}]` (124 live), `credits.crew[{job,department,name,…}]`
- `relatedVideos[{site:"YouTube",key,name,size,type:"Trailer"|"Clip"|…,url}]`
- `releases.results[{iso_3166_1, release_dates[{certification,type,release_date}]}]`
- `watchProviders[{iso_3166_1, link, flatrate[], buy[], rent[]}]`. Filter it to the user's region (ZA).
- `mediaInfo`: `null` when the title is not in the Seerr DB (live: `/movie/603` → `"mediaInfo":null`). Otherwise it is
  the Media object (1.8) **plus** `requests[]` (full MediaRequest objects), `issues[]`, `downloadStatus[]` and
  `downloadStatus4k[]`.

Extras:

- `GET /movie/{id}/recommendations?page=`, `GET /movie/{id}/similar?page=` (paged results, as in 1.5)
- `GET /movie/{id}/ratingscombined` returns
  `{"rt":{title,url,criticsRating,criticsScore,audienceRating,audienceScore,year},"imdb":{title,url,criticsScore,criticsScoreCount}}`.
  This is slow: 1.1 s live, because it scrapes RT and IMDb. Load it lazily.

#### TV: `GET /tv/{tmdbId}`

About 150 KB. Fields:

- `id`, `name`, `originalName`, `overview`, `tagline`, `firstAirDate`, `lastAirDate`, `status` ("Ended" /
  "Returning Series"), `inProduction`, `type`, `numberOfSeasons`, `numberOfEpisodes`, `episodeRunTime[]`
- `networks[]`, `createdBy[]`, `genres[]`, `keywords[]`, `contentRatings`, `posterPath`, `backdropPath`
- `externalIds {tvdbId,imdbId,…}`
- `nextEpisodeToAir?`, `lastEpisodeToAir {airDate,episodeNumber,seasonNumber,name,stillPath,…}`
- `seasons[]`: the **TMDB season list** `{id, seasonNumber, episodeCount, name, airDate, overview, posterPath}`. This
  includes season 0 "Specials".
- `mediaInfo.seasons[]`: the **Seerr status per season** `{id, seasonNumber, status, status4k, createdAt, updatedAt}`.
  - Only seasons Seerr knows about are listed. A missing season means UNKNOWN (1).
  - Season 0 is absent here, and `enableSpecialEpisodes=false`.

Live excerpt from tv 10545, True Blood, `mediaInfo.status=4` (partially available). Season 3 shows PROCESSING with no
request, because it is monitored in Sonarr.

```json
"mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5,"status4k":1},{"seasonNumber":2,"status":5,"status4k":1},
 {"seasonNumber":3,"status":3,"status4k":1},{"seasonNumber":4,"status":1,"status4k":1}, …7],
 "requests":[{"id":178,"status":5,"seasons":[{"seasonNumber":1,"status":5}]}]}
```

To build the season picker for "Request more seasons":

1. Take `tv.seasons` where `seasonNumber > 0` and `episodeCount > 0`.
2. Mark a season **not requestable** when its `mediaInfo.seasons[n].status` is not in {1 UNKNOWN, 7 DELETED}, **or**
   when it appears in `mediaInfo.requests[r].seasons` of a request whose status is not in {3 DECLINED, 5 COMPLETED}.
   This is the exact server rule from `MediaRequest.createRequest`.

Extras:

- `GET /tv/{id}/season/{n}` returns `{id, seasonNumber, name, overview, airDate, posterPath, externalIds,
  episodes[{id, episodeNumber, seasonNumber, name, overview, airDate, stillPath, voteAverage, voteCount, showId,
  productionCode}]}`. Episodes carry no Seerr availability; take that from Sonarr or Jellyfin.
- `GET /tv/{id}/ratings` returns `{title,url,criticsRating,criticsScore,audienceRating,audienceScore,year}` (RT only).
- `GET /tv/{id}/recommendations`, `/tv/{id}/similar`.

### 1.8 The Media (`mediaInfo` / `request.media`) object

```
id:int (Seerr media id. Issues use THIS id, not tmdbId)   mediaType:"movie"|"tv"
tmdbId:int  tvdbId:int?  imdbId:string?  status:MediaStatus  status4k:MediaStatus
createdAt updatedAt lastSeasonChange mediaAddedAt:ISO-8601 string (mediaAddedAt is null until available)
serviceId:int? (Radarr/Sonarr server id, 0 here)  externalServiceId:int? (Radarr movie id / Sonarr series id)
externalServiceSlug:string? ("818" for Radarr, "the-legend-of-korra" for Sonarr)
jellyfinMediaId:string? (Jellyfin item Id, 32 hex chars, no dashes) jellyfinMediaId4k  ratingKey* (Plex, null)
mediaUrl:string? (Jellyfin web link; see below)  serviceUrl:string? ("http://radarr:7878/movie/818", internal hostname)
seasons:[Season] (tv)  downloadStatus:[DownloadingItem]  downloadStatus4k:[DownloadingItem]
```

- **`mediaUrl`** uses the Jellyfin host configured in Seerr: `http://192.168.10.183:8096/web/index.html#!/details?id=…`.
  It is LAN only, and `externalHostname` is empty. **Rebuild it** from `jellyfinMediaId` and the hub's configured public
  Jellyfin URL (section 2.9). Do not pass it through.
- **`serviceUrl`** uses Docker hostnames, which the phone cannot reach. Drop it or rewrite it.
- **`downloadStatus[]`** is filled from Seerr's in-memory download tracker, which polls Radarr/Sonarr queues (source
  `server/lib/downloadtracker.ts`). Shape:
  `{mediaType, externalId:int, size:int(bytes), sizeLeft:int, status:string, timeLeft:string, estimatedCompletionTime:ISO, title:string, downloadId:string, episode?:{seasonNumber,episodeNumber,absoluteEpisodeNumber,id}}`.
  - It was empty live, because nothing was downloading. Good enough for a progress bar on the details page.
  - For the full queue, use Sonarr/Radarr/qBittorrent directly.
- `GET /media?take&skip&filter&sort` lists Seerr media rows.
  - `filter`: `all | available | partial | allavailable | processing | pending | deleted`.
  - `sort`: `added | modified | mediaAdded` (`mediaAdded` gives "recently available").
  - Response: `{pageInfo:{pages,pageSize,results,page}, results:[Media]}`.
  - **No title or poster.** The gateway must join against `/movie/{tmdbId}` or `/tv/{tmdbId}` (cache them).

### 1.9 Requests

#### List: `GET /request`

| param | values | default |
|---|---|---|
| `take` | int (no server cap; `take=500` worked live, 316 KB, 182 ms) | 10 |
| `skip` | int | 0 |
| `filter` | `all` `approved` `available` `pending` `processing` `unavailable` `failed` `deleted` `completed` | all |
| `sort` | `added` (= by `request.id`) \| `modified` (= `updatedAt`) | added |
| `sortDirection` | `asc` \| `desc` | desc |
| `requestedBy` | Seerr user id. Non-managers asking for another user get 403. | — |
| `mediaType` | `movie` \| `tv` \| `all` | all |

Filter semantics (source):

| filter | request.status in | media.status in |
|---|---|---|
| pending | 1 | any |
| approved / processing | 2 | processing: {1,2,3,4} |
| unavailable | {1,2} | {1,2,3,4} |
| failed | 4 | any |
| completed / available / deleted | 5 | available: 5, deleted: 7 |
| all | any | any |

Response `{pageInfo:{pages,pageSize,results,page}, results:[MediaRequest], serviceErrors:{radarr:[{id,name}],sonarr:[{id,name}]}}`.
`page` is computed as `ceil(skip/take)+1`.

MediaRequest fields:

- `id`, `status` (MediaRequestStatus), `type` ("movie"|"tv"), `is4k`, `createdAt`, `updatedAt`
- `serverId`, `profileId`, `rootFolder`, `languageProfileId`, `tags`. Each is `null` unless overridden at creation.
- `isAutoRequest`, `ignoreQuota`, `seasonCount:int`, `seasons[{id,seasonNumber,status(MediaRequestStatus),createdAt,updatedAt}]`
- `media` (Media, 1.8), `requestedBy` (User), `modifiedBy` (User|null)
- List only:
  - `profileName?` (resolved from the *arr profiles; only when `profileId` is set)
  - `canRemove?` (only for MANAGE_REQUESTS users; true when the *arr server is configured)

**Requests contain no title or poster.** The UI must fetch `/movie/{media.tmdbId}` or `/tv/{media.tmdbId}`, as Seerr's
own web does. The gateway should do this join with an LRU or TTL cache keyed by `type:tmdbId` (titles change rarely),
and return slim DTOs.

Live excerpt (requestedBy and modifiedBy trimmed):

```json
{"id":196,"status":5,"type":"tv","is4k":false,"serverId":null,"profileId":null,"rootFolder":null,"seasonCount":4,
 "canRemove":true,"media":{"id":428,"mediaType":"tv","tmdbId":33880,"tvdbId":251085,"status":5,"serviceId":0,
 "externalServiceId":163,"jellyfinMediaId":"6e332b664756b794942cae8a5ea3b1c0", …},
 "seasons":[{"id":278,"seasonNumber":1,"status":5,…}, …]}
```

User object (embedded in requests, issues and user lists). The gateway must **never forward `email`**.

```
id:int email:string(PII) displayName:string username:string? jellyfinUsername:string? jellyfinUserId:string?
userType:int permissions:int avatar:string requestCount:int movieQuotaLimit? movieQuotaDays? tvQuotaLimit? tvQuotaDays?
createdAt updatedAt warnings:[] settings? (null via list endpoints)
```

#### Single: `GET /request/{id}`

Returns the MediaRequest with `requestedBy` and `modifiedBy`. A request belonging to someone else, asked for without
MANAGE_REQUESTS or REQUEST_VIEW, gives 403. A missing one gives 404.

#### Counts: `GET /request/count`

Live: 20 ms.

```json
{"total":127,"movie":42,"tv":85,"pending":0,"approved":4,"declined":0,"processing":3,"available":1,"completed":122}
```

- `processing` and `available` are **subsets of `approved`**: approved requests whose media is not yet available, or
  already is. `failed` has no counter (`total - pending - approved - declined - completed` = 1 live).
- These are **global counts**. They are not filtered by user, and any authenticated user can read them.

#### Create: `POST /request`

Not called. The body comes from `MediaRequestBody` plus the OpenAPI spec.

```jsonc
{
  "mediaType": "movie" | "tv",          // required
  "mediaId": 818,                        // required, TMDB id
  "tvdbId": 82283,                       // optional (tv), default = TMDB external_ids.tvdb_id
  "seasons": [4,5,6,7] | "all",          // tv only; numbers >= 0
  "is4k": false,                         // optional; 4K is disabled on this server (movie4kEnabled=false)
  "serverId": 0,                         // optional override (needs REQUEST_ADVANCED or MANAGE_REQUESTS)
  "profileId": 7,                        // optional override
  "rootFolder": "/data/movies",          // optional override
  "languageProfileId": 1,                // optional (tv; unused on Sonarr v4 → null)
  "tags": [1,2],                         // optional (in TS type; not declared in OpenAPI schema; verify before use)
  "userId": 2,                           // optional: request on behalf of (needs MANAGE_USERS|MANAGE_REQUESTS)
  "ignoreQuota": false                   // optional, MANAGE_REQUESTS only
}
```

- **Minimal movie:** `{"mediaType":"movie","mediaId":818}`.
- **Minimal TV:** `{"mediaType":"tv","mediaId":10545,"seasons":"all"}`.
  - `"all"` expands to TMDB seasons where `season_number != 0 && episode_count > 0`.
  - Season 0 is then dropped, because `enableSpecialEpisodes=false`.
  - Seasons that are already requested or available are silently removed (the 1.7 rule). The request carries only the
    remaining seasons.
- **Profile and folder defaults.** When overrides are left out, Seerr uses the server defaults:
  - Radarr profile 7 "HD Bluray + WEB", `/data/movies`.
  - Sonarr profile 9 (`WEB-1080p`), and anime profile 7 "[Anime] Remux-1080p" when TMDB keywords mark the show as
    anime, `/data/tvshows`.
  - Override Rules (`/overrideRule`) may also apply.
  - Leave overrides out unless the user picked an "advanced" option.
  - For advanced users the options come from `GET /service/radarr/{serverId}` and `GET /service/sonarr/{serverId}`
    (section 1.10).
- **Responses:**
  - **201**: the MediaRequest (the `status` field tells you pending (1) or approved (2)).
  - **202** `{"message":"No seasons available to request"}`: all requested seasons are already covered. **This is not
    an error.** Show "already requested".
  - **409** `{"message":"Request for this media already exists."}`: a duplicate (DuplicateMediaRequestError, verified in source).
  - **403**:
    - RequestPermissionError (`You do not have permission to request …`)
    - QuotaRestrictedError (`Movie Quota exceeded.` / `Series Quota exceeded.`)
    - BlocklistedMediaError (`This media is blocklisted.`)
  - **401** no user. **500** other errors, e.g. a TMDB failure.
- **Side effects** are synchronous and happen inside the call:
  - A new request that is APPROVED is sent to Radarr/Sonarr straight away. The request turns into FAILED (4) if the
    *arr rejects it.
  - Discord `#requests` is notified.
  - Expect 0.5–2 s latency.
  - Per-user and per-media locks serialise concurrent requests (`server/utils/requestLock.ts`).

#### Edit pending request: `PUT /request/{id}`

- Body: `{"mediaType":"movie"|"tv" (required), "seasons":[int] (tv, required non-empty), "serverId","profileId","rootFolder","languageProfileId","tags","userId"}`.
- Only **PENDING** requests can be edited (otherwise 409 `Only pending requests can be modified.`).
- Allowed for MANAGE_REQUESTS, or for the owner (non-tv edits by the owner also need REQUEST_ADVANCED).
- Returns 200 with the request, or 202 when no seasons remain.

#### Approve / decline: `POST /request/{id}/approve` and `POST /request/{id}/decline`

- No body.
- Needs MANAGE_REQUESTS, so call without `X-API-User`, or with an admin.
- Only PENDING requests (409 `Only pending requests can be approved or declined.`). 404 if missing. 400 if the status
  segment is invalid (the validator enum is `approve|decline`).
- Returns 200 with the updated MediaRequest (`modifiedBy` = admin).
- Approving sends the request to the *arr server.

#### Retry failed: `POST /request/{id}/retry`

- No body. Needs MANAGE_REQUESTS.
- Only FAILED (4), otherwise 409 `Only failed requests can be retried.`
- Sets the request back to APPROVED and sends it to the *arr again. Returns 200.

#### Delete: `DELETE /request/{id}`

- Returns **204**, no body.
- Allowed for MANAGE_REQUESTS, or for the owner when the request is still PENDING. Anyone else gets **401** (not 403)
  `You do not have permission to delete this request.` 404 if missing.
- **Only deletes the Seerr request row.** It does **not** remove anything from Radarr/Sonarr or disk.
- For "remove from library" use `DELETE /media/{mediaId}/file` (1.11), or the *arr APIs directly.

#### Per-user lists and quota

- `GET /user/{id}/requests?take=&skip=` (default take 20) returns `{pageInfo, results:[MediaRequest]}`.
- `GET /user/{id}/quota` returns `{"movie":{"limit"?:int,"days"?:int,"used":int,"remaining"?:int,"restricted":bool},"tv":{…}}`.
  - Admin live: `limit:0,used:0,restricted:false`. User 2 has no `limit` key at all (no quota).
  - Treat a missing `limit`, or `limit` 0, as unlimited.

### 1.10 Services: options for the advanced request sheet

- `GET /service/radarr` returns `[{id:0,name:"Radarr",is4k:false,isDefault:true,activeDirectory:"/data/movies",activeProfileId:7,activeTags:[]}]`.
- `GET /service/sonarr` returns the same plus `activeAnimeProfileId:7` (live). Detail adds `activeAnimeTags`.
- `GET /service/radarr/{id}` (260 ms) returns:
  ```
  {server:{…}, profiles:[{id,name}], rootFolders:[{id,freeSpace:int(bytes),path}], tags:[{id,label}]}
  ```
  Live profiles: Any, SD, HD-720p, HD-1080p, Ultra-HD, "HD - 720p/1080p", "HD Bluray + WEB". Free space is 4.05 TB.
- `GET /service/sonarr/{id}` returns the same shape plus `languageProfiles` (`null` on Sonarr v4). Live: 9 profiles.
- `GET /service/sonarr/lookup/{tmdbId}` is a Sonarr series lookup (844 ms, 40 KB). The app does not need it.

### 1.11 Media management (admin)

These were not called; they come from source.

- `POST /media/{mediaId}/{status}`. Body `{"is4k":false}` (optional). For `available` on TV it also takes
  `"seasons":[{"seasonNumber":n}]`.
  - `status` is one of `available | partial | processing | pending | unknown` (`deleted` is in the spec enum).
  - Needs MANAGE_REQUESTS. Manually sets the Seerr status ("Mark as available"). `partial` on a movie gives 400.
  - Returns 200 with the Media.
- `DELETE /media/{mediaId}` needs MANAGE_REQUESTS. Clears Seerr's media row and its requests ("Clear data"). Returns 204.
- `DELETE /media/{mediaId}/file?is4k=false` needs MANAGE_REQUESTS. **Deletes the movie or series from Radarr/Sonarr,
  including files** (`removeMovie(tmdbId)` / `removeSeries(tvdbId)`), and resets the Seerr status. Returns 204.
  - **Destructive.** Put it behind a confirm dialog.
  - Errors: 404 if no *arr server is configured; 409 if the *arr item is not found.
- `{mediaId}` here is **Seerr's Media `id`** (`mediaInfo.id`), not tmdbId.

### 1.12 Issues

- `GET /issue?take=&skip=&filter=all|open|resolved&sort=added|modified&createdBy=<userId>` returns
  `{pageInfo, results:[Issue]}`.
  - The OpenAPI spec says the default filter is `open`. The source default (when the param is absent) is **all**, so
    pass `filter` explicitly.
  - Needs MANAGE_ISSUES, VIEW_ISSUES or CREATE_ISSUES. Without MANAGE/VIEW you only see your own issues.
  - Live: 0 issues (`seerr_issue_list_empty.json`).
- Issue: `{id, issueType:1-4, status:1|2, problemSeason:int(0=all), problemEpisode:int(0=all), createdAt, updatedAt, media:Media, createdBy:User, modifiedBy:User?, comments:[{id,message,createdAt,updatedAt,user:User}]}`.
- `GET /issue/count` returns `{"total":0,"video":0,"audio":0,"subtitles":0,"others":0,"open":0,"closed":0}` (global).
- `GET /issue/{id}` returns the Issue with comments.
- **Create** `POST /issue` (needs MANAGE_ISSUES or CREATE_ISSUES):
  ```json
  {"issueType": 1, "message": "Audio out of sync from 12:30", "mediaId": 427, "problemSeason": 0, "problemEpisode": 0, "userId": null}
  ```
  - **`mediaId` is the Seerr Media id** (`mediaInfo.id`), not tmdbId. With no Media row you get 404
    `Media does not exist.` That means only titles Seerr knows (requested or synced) can have issues.
  - `userId` (on behalf of another user) needs MANAGE_ISSUES.
  - The OpenAPI schema lists only `issueType, message, mediaId, userId`. `problemSeason` and `problemEpisode` are read
    from the body in source.
  - Returns 201 with the Issue.
- **Comment** `POST /issue/{id}/comment` with `{"message": "…"}` returns 200 with the Issue.
- **Resolve / reopen** `POST /issue/{id}/resolved` and `POST /issue/{id}/open`, no body. MANAGE_ISSUES, or the issue
  creator. Returns 200 with the Issue.
- **Delete** `DELETE /issue/{id}` returns 204. Edit or delete a comment: `PUT|DELETE /issueComment/{commentId}`
  `{"message"}`.

### 1.13 Users

- `GET /auth/me` returns the current User, including `settings` (null here). With `X-API-User` you get that user.
- `GET /user?take=&skip=&sort=created|updated|requests|displayname|usertype|role&sortDirection=asc|desc&q=<search>` returns `{pageInfo, results:[User]}`.
  Live: 2 users, 75 ms.
- `GET /user/{id}` returns the User. `GET /user/jellyfin/{jellyfinUserId}` returns the User or 404 (see 1.1).
- `GET /user/{id}/watchlist?page=` has the same shape as `/discover/watchlist`.

### 1.14 Server status

- `GET /status` (no auth) returns `{"version":"3.5.1","commitTag":"564bfb0…","updateAvailable":false,"commitsBehind":0,"restartRequired":false}`.
  Use it as the health check.
- `GET /settings/public` (no auth) has, among other fields:
  - `applicationTitle:"Jellyseerr"`
  - `mediaServerType:2` (Jellyfin)
  - `movie4kEnabled:false`, `series4kEnabled:false` (**hide the 4K toggle**)
  - `partialRequestsEnabled:true` (season picker allowed)
  - `enableSpecialEpisodes:false`, `locale:"en"`, `cacheImages:false`, `jellyfinExternalHost:""`

### 1.15 Latency and caching summary (live, from the NAS)

| call | cold | warm |
|---|---|---|
| status / settings / counts / request list (take 20) / users | 10–75 ms | same |
| search, discover (TMDB) | 200–700 ms | ~20 ms (Seerr TMDB cache) |
| movie / tv details | 300–600 ms (first), 100–150 KB | ~40 ms |
| ratingscombined | ~1.1 s | |
| service/radarr/{id} (calls Radarr) | ~260 ms | |

- The request list calls Radarr and Sonarr `getProfiles` on **every** call. That is cheap here (about 50 ms total), but
  it fails soft into `serviceErrors`.
- Gateway suggestions:
  - Cache TMDB-derived details for 6–24 h.
  - Cache counts and lists for 10–30 s.
  - Do not poll Seerr faster than about every 30 s. For live updates, fall back to Seerr webhooks (Settings ->
    Notifications -> Webhook) pointed at the gateway.

---

## 2. Jellyfin 12.4.0

### 2.1 Auth

- **Accepted:** `Authorization: MediaBrowser Token="<key>"` (live, 200).
- **Rejected with 401 and an empty body** (live): `X-Emby-Token: <key>`, `?api_key=<key>`, and no auth.
- OpenAPI `securitySchemes`: `CustomAuthentication` = apiKey in header `Authorization`.
- Recommended full form:
  `Authorization: MediaBrowser Client="YAMS Hub", Device="yams-hub", DeviceId="yams-hub-gateway", Version="1.0.0", Token="<key>"`.
  - API-key calls show up as a pseudo-session in `/Sessions`. Live examples: a `Client:"Homepage"` session with
    `UserName:null`, and a `Client:"Seerr"` session.
  - A **stable DeviceId** keeps this to one entry. Filter these clients out of the "now playing" list.
- With an API key there is no implicit user, so **user-scoped endpoints need `userId=`**:
  - `GET /Items/Latest` without `userId` gives 400 `Error processing request.`
  - `GET /Items/{id}` without `userId` gives 400.
  - Use the admin user `4c0628aacef24bdfacd40f946ea33ee7`, or the hub user's Jellyfin id.
- Unauthenticated: `GET /System/Info/Public`, `GET /System/Ping` (returns `"Jellyfin Server"`), and **images**.

### 2.2 Server info

- `GET /System/Info/Public` (no auth) returns
  `{"LocalAddress":"http://172.28.0.3:8096","ServerName":"Zenith","Version":"12.4.0","ProductName":"Jellyfin Server","Id":"79315eab…","StartupWizardCompleted":true}`.
- `GET /System/Info` adds `HasPendingRestart`, `IsShuttingDown`, `HasUpdateAvailable`, `CanSelfRestart`,
  `EncoderLocation`, `SystemArchitecture:"X64"`, `TranscodingTempPath`, `CachePath`, `LogPath`, `WebSocketPortNumber`,
  `CastReceiverApplications`.
- `GET /System/Configuration/encoding` (admin) has `HardwareAccelerationType:"qsv"`,
  `QsvDevice:"/dev/dri/renderD128"`, `EnableVppTonemapping:true`, `EnableHardwareEncoding:true`,
  `EnableIntelLowPowerH264HwEncoder:true`, `EnableIntelLowPowerHevcHwEncoder:true`,
  `HardwareDecodingCodecs:["h264","hevc","mpeg2video","vc1","vp8","vp9","av1"]`, `AllowHevcEncoding:false`. Show these
  on a "Transcoding: Intel QSV" card.

### 2.3 Sessions / now playing: `GET /Sessions?activeWithinSeconds=960`

- `960` is what Jellyfin's dashboard uses. Without it, stale sessions are included (live: 10 KB with, 8.4 KB without).
- Optional `controllableByUserId`, `deviceId`. Returns `SessionInfoDto[]`, about 12 ms.
- Keep a session for "now playing" when `NowPlayingItem != null`. Live: 1 of 4 sessions (an Android TV DirectPlay).

Fields:

| field | type | notes |
|---|---|---|
| `Id` | string | session id (for commands) |
| `UserId`, `UserName` | string? | null for API-key sessions |
| `Client`, `DeviceName`, `DeviceId`, `DeviceType?`, `ApplicationVersion` | string | e.g. "Jellyfin Android TV", "Xiaomi TV Box", "0.19.10" |
| `RemoteEndPoint` | string | client IP (e.g. 192.168.10.160) |
| `LastActivityDate`, `LastPlaybackCheckIn`, `LastPausedDate?` | ISO-8601 with 7 fractional digits (`2026-11-08T08:56:09.4422181Z`) |
| `IsActive`, `SupportsRemoteControl`, `SupportsMediaControl` | bool | |
| `PlayState.PositionTicks` | int64 | **ticks = 100 ns; seconds = ticks / 10 000 000** |
| `PlayState.IsPaused`, `IsMuted`, `CanSeek`, `VolumeLevel?`, `AudioStreamIndex?`, `SubtitleStreamIndex?`, `MediaSourceId`, `RepeatMode`, `PlaybackOrder` | | |
| `PlayState.PlayMethod` | `"DirectPlay" \| "DirectStream" \| "Transcode"` | absent when idle |
| `NowPlayingItem` | BaseItemDto | `Name`, `Id`, `Type` ("Movie"/"Episode"/"Audio"…), `SeriesName`, `SeriesId`, `SeasonId`, `ParentIndexNumber` (season), `IndexNumber` (episode), `RunTimeTicks`, `ProductionYear`, `ImageTags.Primary`, `SeriesPrimaryImageTag`, `ParentBackdropItemId`, `ParentThumbItemId`, `Container`, `MediaStreams[]`, `Width`, `Height`, `IsHD`, … |
| `TranscodingInfo` | object \| null | null for DirectPlay (live). Shape below. |
| `NowPlayingQueue`, `SupportedCommands`, `Capabilities`, `PlayableMediaTypes` | | |

`TranscodingInfo` (OpenAPI 12.4). No session was transcoding during the probe, so this has no live sample:

```
AudioCodec:string VideoCodec:string Container:string IsVideoDirect:bool IsAudioDirect:bool Bitrate:int(bps)
Framerate:number CompletionPercentage:number Width:int Height:int AudioChannels:int
HardwareAccelerationType: "none"|"amf"|"qsv"|"nvenc"|"v4l2m2m"|"vaapi"|"videotoolbox"|"rkmpp"
TranscodeReasons: [ "ContainerNotSupported"|"VideoCodecNotSupported"|"AudioCodecNotSupported"|"SubtitleCodecNotSupported"|
  "AudioIsExternal"|"SecondaryAudioNotSupported"|"VideoProfileNotSupported"|"VideoLevelNotSupported"|
  "VideoResolutionNotSupported"|"VideoBitDepthNotSupported"|"VideoFramerateNotSupported"|"RefFramesNotSupported"|
  "AnamorphicVideoNotSupported"|"InterlacedVideoNotSupported"|"AudioChannelsNotSupported"|"AudioProfileNotSupported"|
  "AudioSampleRateNotSupported"|"AudioBitDepthNotSupported"|"ContainerBitrateExceedsLimit"|"VideoBitrateNotSupported"|
  "AudioBitrateNotSupported"|"UnknownVideoStreamInfo"|"UnknownAudioStreamInfo"|"DirectPlayError"|
  "VideoRangeTypeNotSupported"|"VideoCodecTagNotSupported"|"StreamCountExceedsLimit"|"VideoRotationNotSupported" ]
```

- The parser must accept unknown enum strings, since new reasons get added.
- Show "Transcode (HW: QSV)" when `PlayMethod=="Transcode"` and `HardwareAccelerationType!="none"`. Show "Direct stream"
  when `IsVideoDirect && !IsAudioDirect`.

Progress: `PlayState.PositionTicks / NowPlayingItem.RunTimeTicks`. Live: 1 659 450 000 / 25 835 840 000 = 6.4 %.

Live excerpt (trimmed):

```json
{"Id":"eb96632f72ed3854021c5466f350a158","UserName":"Zenith Greyrat","Client":"Jellyfin Android TV","DeviceName":"Xiaomi TV Box",
 "PlayState":{"PositionTicks":1659450000,"IsPaused":false,"PlayMethod":"DirectPlay","AudioStreamIndex":3,"SubtitleStreamIndex":0},
 "TranscodingInfo":null,
 "NowPlayingItem":{"Name":"A Spark. To Pierce the Dark.","Id":"d078a144bb4719f0e6babd8d90ba0b11","Type":"Episode",
  "SeriesName":"Desperate Housewives","SeriesId":"9efa4240a1af422beff21712c58c218d","ParentIndexNumber":5,"IndexNumber":18,
  "RunTimeTicks":25835840000,"ImageTags":{"Primary":"dbb58187fd3e6443369f536fb7a75908"},"SeriesPrimaryImageTag":"0a65d366…"}}
```

Session write actions (not called; from OpenAPI). All return **204**:

- `POST /Sessions/{sessionId}/Playing/{command}`
  - `command` ∈ `Stop Pause Unpause PlayPause NextTrack PreviousTrack Seek Rewind FastForward`
  - Optional query `seekPositionTicks` (for Seek) and `controllingUserId`.
- `POST /Sessions/{sessionId}/Message` with body `{"Header":"YAMS","Text":"Server restarting in 5 min","TimeoutMs":10000}`.
  Only `Text` is required.
- `POST /Sessions/{sessionId}/System/{command}` (GeneralCommandType: `GoHome`, `DisplayMessage`, `ToggleMute`, …).
  Rarely needed.

### 2.4 Counts and users

- `GET /Items/Counts` (optional `userId`, `isFavorite`). Live, 25 ms:
  `{"MovieCount":179,"SeriesCount":54,"EpisodeCount":1694,"ArtistCount":78,"SongCount":0,"AlbumCount":0,"BookCount":2,"BoxSetCount":0,"MusicVideoCount":0,"ProgramCount":0,"TrailerCount":0,"ItemCount":9408}`.
  Jellystat says 178 movies, because its sync lags.
- `GET /Users` returns `[{Name, Id, ServerId, HasPassword, HasConfiguredPassword, LastLoginDate?, LastActivityDate, PrimaryImageTag?, Configuration{…}, Policy{IsAdministrator, IsDisabled, IsHidden, EnableRemoteAccess, EnableMediaPlayback, …}}]`.
  - Live: 4 users.
  - User avatar: `GET /Users/{userId}/Images/Primary?tag={PrimaryImageTag}`.

### 2.5 Libraries

- `GET /Library/VirtualFolders` (admin) returns `[{Name, ItemId, CollectionType:"movies"|"tvshows"|"music"|"books", Locations:[path], RefreshStatus:"Idle"|"Active", RefreshProgress?, PrimaryImageItemId, LibraryOptions{…}}]`.
  Live: 4 libraries (Movies, Shows, Music, Books).
- `GET /UserViews?userId=…` returns `{Items:[BaseItemDto{Name, Id, CollectionType, ImageTags}], TotalRecordCount}`. This
  is the user's library tiles.
- Library scan (write, not called): `POST /Library/Refresh` with no body returns 204. For one item:
  `POST /Items/{id}/Refresh?metadataRefreshMode=Default&imageRefreshMode=Default&replaceAllMetadata=false&replaceAllImages=false`
  returns 204.

### 2.6 Latest and recently added

- **Per library ("Latest Movies" / "Latest Shows"):**
  `GET /Items/Latest?userId={u}&parentId={libraryId}&limit=16&fields=DateCreated,Overview,ProviderIds&enableImageTypes=Primary,Backdrop,Thumb&imageTypeLimit=1`
  - Returns a **bare JSON array** (no wrapper). 90–110 ms.
  - The default `groupItems=true` collapses new episodes into their **Series** or **Season** item
    (`Type:"Series"`/`"Season"`, with `UserData.UnplayedItemCount`). Live: "Season 2 / The Ramparts of Ice".
  - `groupItems=false` returns individual Episodes (`SeriesName`, `ParentIndexNumber`, `IndexNumber`). That took 330 ms.
  - `userId` is required (400 without).
  - The legacy `GET /Users/{userId}/Items/Latest` still answers 200, but it is **gone from the 12.4 OpenAPI**. Do not
    use it.
- **Global recently added (all libraries, paged):**
  `GET /Items?recursive=true&includeItemTypes=Movie,Episode&sortBy=DateCreated&sortOrder=Descending&startIndex=0&limit=20&fields=DateCreated,ProviderIds&enableTotalRecordCount=true`
  - Returns `{Items:[BaseItemDto], TotalRecordCount:int (1873 live), StartIndex:int}`. 350 ms with `MediaSources` and
    `Path`, which can be dropped.
  - `userId` is optional here.
- **Continue watching:** `GET /UserItems/Resume?userId={u}&limit=12` returns `{Items[…], TotalRecordCount}`. 600 ms live.
  `UserData.PlayedPercentage` and `PlaybackPositionTicks` are set.
- **Next up:** `GET /Shows/NextUp?userId={u}&limit=12`.
- **Search inside Jellyfin:** `GET /Search/Hints?searchTerm=austin&limit=10` returns
  `{SearchHints:[{ItemId, Id, Name, Type, ProductionYear, RunTimeTicks, PrimaryImageTag, Series?, IndexNumber?, ParentIndexNumber?, …}], TotalRecordCount}`.
  This is the "Is it already on Jellyfin?" check.
- **Activity feed:** `GET /System/ActivityLog/Entries?startIndex=0&limit=20` returns
  `{Items:[{Id:int, Name, Overview?, ShortOverview?, Type:"VideoPlayback"|"VideoPlaybackStopped"|"SessionStarted"|"AuthenticationSucceeded"|…, ItemId?, Date, UserId, Severity}], TotalRecordCount}`.
  Live: 5221 entries.

BaseItemDto fields worth parsing:

- `Id`, `Name`, `Type`, `ServerId`, `ParentId`, `SeriesName`, `SeriesId`, `SeasonId`, `IndexNumber`, `ParentIndexNumber`
- `ProductionYear`, `PremiereDate`, `DateCreated`, `RunTimeTicks`, `CommunityRating`, `OfficialRating`, `Overview`
  (only with `fields=Overview`)
- `ProviderIds {Tmdb:"818", Imdb, Tvdb, TmdbCollection}`. The values are **strings**. Join on tmdb to Seerr.
- `ImageTags {Primary, Thumb, Logo, Backdrop?}`, `BackdropImageTags:[]`, `ImageBlurHashes {Primary:{tag:blurhash}}`
- `UserData {Played, PlayCount, IsFavorite, PlaybackPositionTicks, PlayedPercentage?, UnplayedItemCount?, LastPlayedDate?, Key, ItemId}`
- `MediaSources[{Container, Size, Bitrate, Path, MediaStreams[…]}]` (with `fields=MediaSources`)

### 2.7 Item detail: `GET /Items/{itemId}?userId={u}`

- The legacy `/Users/{u}/Items/{id}` path is gone from the OpenAPI.
- About 21 KB and 400 ms (cold). It has everything: `People`, `Studios`, `GenreItems`, `MediaSources`, `MediaStreams`,
  `Chapters`, `RemoteTrailers`, `ExternalUrls`, `CanDelete`, `CanDownload`, `Path`.
- `userId` is required with an API key (400 without).

### 2.8 Images

- Images **need no auth** (live: 200 without a header). Size them on the server:
  - `GET /Items/{id}/Images/Primary?fillHeight=450&quality=90&tag={ImageTags.Primary}` (live: 200 `image/jpeg`, 52 KB)
  - `GET /Items/{id}/Images/Backdrop/0?maxWidth=1280&tag={BackdropImageTags[0]}`
  - `GET /Items/{id}/Images/Thumb`, `/Logo`
  - For episodes without their own image: `GET /Items/{SeriesId}/Images/Primary?tag={SeriesPrimaryImageTag}`, or
    `ParentBackdropItemId`.
- Other params: `maxWidth`, `maxHeight`, `width`, `height`, `fillWidth`, `format` (`Jpg|Png|Webp`), `blur`,
  `percentPlayed`, `unplayedCount`.
- Including `tag` lets the client cache aggressively. Jellyfin sends long cache headers when the tag matches.
- The phone cannot reach `jellyfin:8096`, so the gateway should proxy `/img/jellyfin/{itemId}/{type}?…` and pass the
  query through. Strip any `api_key`.

### 2.9 Deep links into Jellyfin

- Jellyfin web 12.4 route, from its bundle `#/details?id="+o+"&serverId="+l`:
  ```
  {JELLYFIN_PUBLIC_URL}/web/#/details?id={itemId}&serverId=79315eab3c4c401f8391d5c26210b6d7
  ```
  Use the same pattern for Series, Season and Episode ids.
- Seerr builds the legacy form `…/web/index.html#!/details?id=…&context=home&serverId=…`. jellyfin-web still accepts
  the `#!` form. Prefer the `#/` form.
- `JELLYFIN_PUBLIC_URL` must be configurable in the hub: the LAN URL `http://192.168.10.183:8096`, or the NAS Tailscale
  name/IP and port 8096. **Do not use Seerr's `mediaUrl` host.**
- Native apps (Jellyfin Android `org.jellyfin.mobile`, Android TV `org.jellyfin.androidtv`, Jellyfin/Swiftfin on iOS):
  - None of them exposes an item-level deep-link scheme in a form verified here.
  - Recommendation: "Open in Jellyfin" uses the web URL above. Android may hand it to the Jellyfin app if that app
    registers for the server URL; it usually does not, so it opens a browser.
  - "Open the Jellyfin app" launches the app by package name or URL scheme, without an item.
  - See open questions.

---

## 3. Jellystat 1.1.12

### 3.1 Auth and transport

- `x-api-token: <key>` header, or `?apiKey=<key>` (live: both 200). Prefer the header.
- Errors:
  - No auth: **401** `{"message":"Authentication failed. No token or API key provided."}`
  - Wrong key: **403** `{"message":"Invalid API key"}`
  - No keys configured: 404 `{"message":"No API keys configured"}`
- The key is checked against `app_config.api_keys` on every request.
- **Many read-only stats endpoints are POST with a JSON body.** Send `Content-Type: application/json`.
  - The probe called these POSTs after checking in source that they only run `SELECT`s.
  - It also checked that every `fs_*` Postgres function contains no INSERT/UPDATE/DELETE (`pg_proc` query).
- **Query param type coercion** (`typeInferenceMiddleware`): every query value `"true"/"false"` becomes a boolean and
  every numeric string becomes a number.
  - Side effect: a purely numeric `search` (e.g. `search=1923`) turns into a number and is **silently ignored**
    (`search.length` is undefined).
  - A repeated query key (an array) crashes the middleware.
- Errors inside handlers usually come back as **503** with the raw pg error object, or a **plain-text** body:
  - `getMostViewedByType` without `days` gives 503 text `Days needs to be a number.` (live)
  - Invalid type gives 503 text `Invalid Type Value.\nValid Types: ["Audio","Movie","Series"]`
- The parser must handle `text/plain` error bodies.
- Durations (`PlaybackDuration`, `total_playback_duration`, `TotalWatchTime`, `Duration`) are **seconds**.
- `LastPlayed` / `LastSeen` / `LastActivity` are **Postgres interval objects**, e.g.
  `{"minutes":5,"seconds":12,"milliseconds":719.102}`.
  - The keys `years, months, days, hours, minutes, seconds, milliseconds` appear only when non-zero, and the whole value
    may be `null`.
  - Parse into a Duration, treating missing keys as 0. The gateway should convert them to an ISO timestamp or seconds.
- Jellystat currently has **only 1 playback record**; it was installed on 2026-11-08. Most lists are 0–1 items, so test
  with empty arrays.

### 3.2 Endpoint catalogue (from `/app/backend/routes/stats.js` and `api.js`)

Routes the hub may call. All are read-only.

| Method + path | Params | Response (live) |
|---|---|---|
| `GET /stats/getLibraryOverview` | – | `[{Id, Name, CollectionType, Library_Count:int, Season_Count:int, Episode_Count:int}]` |
| `GET /stats/getLibraryCardStats` | – | `[{Id, Name, ServerId, CollectionType, ImageTagsPrimary, ItemId?, ItemName?, ItemType?, PrimaryImageHash?, SeasonNumber?, EpisodeNumber?, EpisodeName?, Plays:int, total_playback_duration?, total_play_time?, Library_Count?, Season_Count?, Episode_Count?, archived, ActivityDateInserted?, LastActivity:interval?}]`. The last-played item per library. |
| `POST /stats/getLibraryCardStats` | `{"libraryid": "<id>"}` (else 503 "Invalid Library Id") | one object as above |
| `GET /stats/getLibraryMetadata` | – | `[{Id, Name, Size:int(bytes), files:int}]` (Shows 2.78 TB / 1695 files, Movies 0.81 TB / 178 files) |
| `GET /stats/getPlaybackActivity` | query `size`(50) `page`(1) `search` `sort` (UserName\|RemoteEndPoint\|NowPlayingItemName\|Client\|DeviceName\|ActivityDateInserted\|PlaybackDuration\|PlayMethod) `desc`(true) `filters` (URL-encoded JSON array, see below) | `{current_page, pages, size, sort, desc, results:[PlaybackActivity], search?, filters?}` |
| `GET /stats/getAllUserActivity` | – | `[{UserId, PrimaryImageTag, UserName, LastWatched:"Series - Episode", NowPlayingItemId, LastActivityDate, LastClient:"Client - Device", TotalPlays:int, TotalWatchTime:int(s), LastSeen:interval}]` (all-time per-user leaderboard) |
| `POST /stats/getMostViewedByType` | `{"days":30,"type":"Movie"\|"Series"\|"Audio"}` (**days required**) | top 5 `[{Plays:int, total_playback_duration:int(s), Name, Id, PrimaryImageHash, archived}]` |
| `POST /stats/getMostPopularByType` | `{"days":30,"type":…}` (days defaults to 30) | top 5 `[{unique_viewers:int, latest_activity_date, Name, Id, PrimaryImageHash, archived}]` |
| `POST /stats/getMostViewedLibraries` | `{"days":30}` | `[{Plays, Id, Name, ServerId, IsFolder, Type, CollectionType, ImageTagsPrimary}]` |
| `POST /stats/getMostUsedClient` | `{"days":30}` | top 5 `[{Plays:int, Client}]` |
| `POST /stats/getMostActiveUsers` | `{"days":30}` | top 5 `[{Plays:int, UserId, Name}]` |
| `POST /stats/getPlaybackMethodStats` | `{"days":30}` | `[{Name:"DirectPlay"\|"DirectStream"\|"Transcode", Count:int}]`. This is the transcode-vs-direct ratio. |
| `POST /stats/getGlobalUserStats` | `{"hours":720,"userid":"<jfUserId>"}` (hours default 24) | `{Plays, total_playback_duration, UserId, Name}` |
| `POST /stats/getGlobalItemStats` | `{"hours":720,"itemid":"<id>"}` | `{Plays, total_playback_duration}` (matches EpisodeId, SeasonId or NowPlayingItemId) |
| `POST /stats/getGlobalLibraryStats` | `{"hours":720,"libraryid":"<id>"}` | `{Plays, total_playback_duration, Id, Name}` |
| `POST /stats/getUserLastPlayed` | `{"userid":"<jfUserId>"}` | up to 15 `[{Id(series/movie), EpisodeId?, Name, EpisodeName?, SeasonNumber?, EpisodeNumber?, PrimaryImageHash, UserId, UserName, archived, LastPlayed:interval}]` |
| `POST /stats/getLibraryLastPlayed` | `{"libraryid":"<id>"}` | up to 15, same shape as above |
| `GET /stats/getViewsOverTime` | `days` (30) | `{libraries:[{Id,Name}], stats:[{Key:"Nov 01, 2026", "<LibraryName>":{count:int,duration:int}, …}]}`. **The keys are library names (dynamic).** About 1 s live. |
| `GET /stats/getViewsByDays` | `days` (30) | same layout, `Key` = weekday name |
| `GET /stats/getViewsByHour` | `days` (30) | same layout, `Key` = hour 0–23 |
| `GET /stats/getViewsByLibraryType` | `days` (30) | `{"Series":1,"Audio":0,"Movie":0,"Other":0}` |
| `GET /stats/getGenreUserStats` | `userid` (required), `size`, `page` | genre breakdown for a user |
| `GET /stats/getGenreLibraryStats` | `libraryid` (required), `size`, `page` | genre breakdown for a library |
| `POST /stats/getLibraryItemsWithStats` | body `{"libraryid"}`, query `size page search sort desc` | per-item play stats |
| `POST /stats/getLibraryItemsPlayMethodStats` | `{"libraryid", "hours":24, "startDate"?, "endDate"?}` | play method per item |
| `GET /api/getLibraries` | – | `[{Id, Name, ServerId, IsFolder, Type:"CollectionFolder", CollectionType, ImageTagsPrimary, total_play_time?, item_count?, season_count?, episode_count?, archived}]` |
| `GET /api/getRecentlyAdded` | `libraryid?`, `limit` (50), `GroupResults` (true) | `[{Name, SeriesName?, Id, SeriesId?, SeasonId?, EpisodeId?, SeasonNumber?, EpisodeNumber?, PrimaryImageHash?, DateCreated, Type, ParentId, NewEpisodeCount?}]`. Jellystat **calls Jellyfin live** and merges with its DB. 73–256 ms. Note that the `Id` of a grouped episode row is a concatenated 64-hex string. Use `EpisodeId`/`SeriesId`. |
| `GET /api/getHistory` | `size page search sort desc filters` | `{current_page, pages, size, sort, desc, results:[{…PlaybackActivity, FullName:"Series : S5E17 - Name", TotalPlays, TotalDuration, results:[PlaybackActivity]}]}` (grouped history) |
| `POST /api/getUserHistory` / `getItemHistory` / `getLibraryHistory` | `{"userid"}` / `{"itemid"}` / `{"libraryid"}` + query `size page search sort desc filters` | same as getHistory, scoped |
| `POST /api/getUserDetails` | `{"userid"}` | Jellystat user row |
| `POST /api/getItemDetails` | `{"Id"}` | item rows (with seasons/episodes) |
| `POST /api/getActivityTimeLine` | `{"userId", "libraries":[ids]}` | user timeline |
| `GET /api/CheckForUpdates` | – | `{"current_version":"1.1.12","latest_version":"1.1.12","message":"Jellystat is up to date","update_available":false}` |
| `GET /auth/isConfigured` (no auth) | – | `{"state":2,"version":"1.1.12"}` (health check) |

The PlaybackActivity row (`jf_playback_activity`):

- `Id` (uuid), `IsPaused`, `UserId`, `UserName`, `Client`, `DeviceName`, `DeviceId`, `ApplicationVersion`
- `NowPlayingItemId`, `NowPlayingItemName`, `SeasonId?`, `SeriesName?`, `EpisodeId?`
- `PlaybackDuration:int(s)`, `ActivityDateInserted` (ISO, ms precision)
- `PlayMethod`, `MediaStreams[]` (Jellyfin MediaStream objects, including `Path` to the file)
- `TranscodingInfo` (Jellyfin shape or null), `PlayState{…}`, `OriginalContainer`, `RemoteEndPoint`, `ServerId`
- `imported:bool`
- **For episodes, `NowPlayingItemId` holds the *series* id** (live: `9efa4240…` = Desperate Housewives) while
  `NowPlayingItemName` is the episode name. Use `EpisodeId` for the episode.

`filters` example, from the API's own 400 hint. URL-encode it:

```json
[{"field":"UserName","value":"User"},{"field":"Client","in":"Android TV,Web"},{"field":"PlaybackDuration","min":1000,"max":5000},
 {"field":"PlayMethod","value":"DirectPlay"},{"field":"ActivityDateInserted","min":"2025-01-01","max":"2025-12-31"},{"field":"IsPaused","value":false}]
```

Live: `filters=[{"field":"PlayMethod","value":"Transcode"}]` returned `results:[]`, `pages:0`, and echoed `filters`.

`PrimaryImageHash` values are **BlurHash strings**, not image tags. For real images use the Jellyfin image endpoint
(2.8) with the `Id`.

### 3.3 Never expose or proxy generically

- **Secret leaks** (any valid API key can read them):
  - `GET /api/keys` returns all Jellystat API keys.
  - `GET /api/getconfig` returns the Jellyfin URL and **Jellyfin API key**.
- **GET routes that change state:**
  - `/sync/beginSync`, `/sync/beginPartialSync`, `/sync/syncPlaybackPluginData`
  - `/backup/beginBackup`, **`/backup/restore/:filename`**
  - `/api/stopTask?task=`
- **Writes:** `/api/setconfig`, `/api/keys` (POST/DELETE), `/api/*purge`, `/api/deletePlaybackActivity`,
  `/api/setTaskSettings`, `/auth/*`.
- **Security observation, outside this project:** Jellystat mounts `/proxy/*` **without auth** (`server.js`:
  `app.use("/proxy", proxyRouter)`). That includes `/proxy/getSessions` and `/proxy/getAdminUsers`, reachable on
  `192.168.10.183:3002` from the LAN. Worth firewalling if 3002 is ever exposed beyond the LAN.

---

## 4. Joining data across services

| From | Field | To | Field |
|---|---|---|---|
| Seerr Media | `jellyfinMediaId` (32 hex, no dashes) | Jellyfin item | `Id` |
| Seerr Media / search result | `tmdbId` / `id` | Jellyfin item | `ProviderIds.Tmdb` (**string**) |
| Seerr Media (tv) | `tvdbId` | Jellyfin series | `ProviderIds.Tvdb` |
| Seerr User | `jellyfinUserId` | Jellyfin user / Jellystat | `Id` / `UserId` |
| Jellyfin session | `NowPlayingItem.SeriesId` | Jellystat | `NowPlayingItemId` (episodes) |
| Jellyfin library | `ItemId` (VirtualFolders) | Jellystat | `Id` / `libraryid`, and Seerr `settings.jellyfin.libraries[].id` |
| Seerr Media | `externalServiceId` + `serviceId` | Radarr `/api/v3/movie/{id}` / Sonarr `/api/v3/series/{id}` | `id` |

Jellyfin GUIDs: Jellyfin and Seerr use undashed lowercase hex. Seerr's `/user/jellyfin/` also accepts dashed. Normalise
by stripping dashes and lowercasing.

---

## 5. Suggested gateway surface for these three services

This only shows how phone features map to upstream calls. The final route names belong to the gateway spec.

| Hub feature | Upstream calls |
|---|---|
| Home "Now playing" card | Jellyfin `GET /Sessions?activeWithinSeconds=960`, filter `NowPlayingItem != null` and exclude `Client in {Homepage, Seerr, YAMS Hub}` |
| Home stat tiles | Jellyfin `/Items/Counts`, Seerr `/request/count`, Seerr `/issue/count`, Jellystat `/stats/getLibraryMetadata` (sizes) |
| Discover tabs | Seerr `/discover/trending`, `/discover/movies`, `/discover/tv`, `/discover/movies/upcoming`, `/discover/tv/upcoming` |
| Search | Seerr `/search?query=<strict-encoded>&page=n`, drop `person` or show it separately |
| Title page | Seerr `/movie/{id}` or `/tv/{id}` (slimmed), lazy `/ratingscombined` and `/ratings`, plus a Jellyfin deep link built from `mediaInfo.jellyfinMediaId` |
| Request button | Seerr `POST /request` with `X-API-User` = the hub user's Seerr id. Handle 201, 202, 403 and 409. |
| Requests inbox (admin) | Seerr `/request?filter=pending&take=20&skip=n` plus title join, then `POST /request/{id}/approve` or `/decline`. Failed requests: `/request?filter=failed`, then `POST /request/{id}/retry` |
| My requests | Seerr `/request?requestedBy={seerrId}` (or `X-API-User`) plus title join |
| Report issue | Seerr `POST /issue` with `mediaId = mediaInfo.id` |
| Recently added | Jellyfin `/Items/Latest?userId&parentId=<lib>` per library, or Jellystat `/api/getRecentlyAdded` (already merged and grouped, includes `NewEpisodeCount`) |
| Watch stats | Jellystat `getViewsOverTime`, `getPlaybackMethodStats`, `getMostViewedByType` (Movie and Series), `getMostActiveUsers`, `getAllUserActivity`, `getPlaybackActivity` |
| Admin session controls | Jellyfin `POST /Sessions/{id}/Playing/Stop|Pause|Unpause`, `POST /Sessions/{id}/Message` |
| Library scan | Jellyfin `POST /Library/Refresh` |

---

## 6. Fixture index (`fixtures/seerr/`)

Every fixture is a live 200 response unless its name contains `error_`.

**Seerr**

- **Status and users:** `seerr_status`, `seerr_settings_public`, `seerr_auth_me`, `seerr_auth_me_x_api_user_2`,
  `seerr_user_list`, `seerr_user_detail`, `seerr_user_by_jellyfin_id`, `seerr_user_quota`, `seerr_user_requests`
- **Search:** `seerr_search_multi` (query "dune": movie, tv and person mix), `seerr_search_multi_encoded_space`
  ("the office"), `seerr_search_tmdb_id` (`tmdb:603`)
- **Discover:** `seerr_discover_trending`, `seerr_discover_trending_tv_week`, `seerr_discover_movies`,
  `seerr_discover_tv`, `seerr_discover_movies_upcoming`, `seerr_discover_tv_upcoming`, `seerr_discover_watchlist`,
  `seerr_genres_movie`
- **Details:**
  - `seerr_movie_details_available` (818, status 5, with `mediaUrl`)
  - `seerr_movie_details_not_in_db` (603, `mediaInfo:null`)
  - `seerr_tv_details_partially_available` (10545, per-season statuses 5/5/3/1…)
  - `seerr_tv_details_processing` (32871, request approved)
  - `seerr_tv_details_failed_request` (1126, request status 4, media status 1)
  - `seerr_tv_season`, `seerr_movie_recommendations`, `seerr_movie_similar`, `seerr_movie_ratingscombined`,
    `seerr_tv_ratings`
- **Requests:**
  - `seerr_request_list` (take 20, mixed statuses, `profileName` and `canRemove` present)
  - `seerr_request_list_tv_modified`, `seerr_request_list_empty` (pending filter), `seerr_request_list_x_api_user_2`
  - `seerr_request_detail_failed` (189), `seerr_request_detail_approved` (187), `seerr_request_count`
- **Issues, media, services:** `seerr_issue_list_empty`, `seerr_issue_count`, `seerr_media_list`,
  `seerr_service_radarr`, `seerr_service_radarr_detail`, `seerr_service_sonarr`, `seerr_service_sonarr_detail`
- **Errors:** `seerr_error_400_reserved_chars`, `seerr_error_400_missing_query`, `seerr_error_401_no_auth`,
  `seerr_error_403_bad_key`, `seerr_error_404_request`, `seerr_error_404_user_by_jellyfin_id`

**Jellyfin**

- **Server:** `jellyfin_system_info_public`, `jellyfin_system_info`, `jellyfin_encoding_config`
- **Sessions and users:** `jellyfin_sessions` (one DirectPlay now-playing session plus 3 idle or API sessions),
  `jellyfin_users`
- **Libraries:** `jellyfin_items_counts`, `jellyfin_library_virtualfolders`, `jellyfin_user_views`
- **Items:**
  - `jellyfin_items_latest_movies`, `jellyfin_items_latest_shows_grouped`, `jellyfin_items_latest_shows_ungrouped`
  - `jellyfin_items_recently_added`, `jellyfin_items_movies_page`, `jellyfin_item_movie`
  - `jellyfin_items_resume`, `jellyfin_search_hints`, `jellyfin_activity_log`

**Jellystat**

- **Stats:**
  - `jellystat_getLibraryOverview`, `jellystat_getLibraryCardStats`, `jellystat_getLibraryMetadata`
  - `jellystat_getPlaybackActivity`, `jellystat_getPlaybackActivity_filtered_empty`, `jellystat_getAllUserActivity`
  - `jellystat_getViewsOverTime`, `jellystat_getViewsByDays`, `jellystat_getViewsByHour`,
    `jellystat_getViewsByLibraryType`
  - `jellystat_getMostViewedByType_series`, `jellystat_getMostViewedByType_movie_empty`,
    `jellystat_getMostPopularByType_series`, `jellystat_getMostViewedLibraries`, `jellystat_getMostUsedClient`,
    `jellystat_getMostActiveUsers`, `jellystat_getPlaybackMethodStats`
  - `jellystat_getGlobalUserStats`, `jellystat_getGlobalLibraryStats`, `jellystat_getUserLastPlayed`,
    `jellystat_getLibraryLastPlayed`
- **API:** `jellystat_api_getLibraries`, `jellystat_api_getRecentlyAdded`, `jellystat_api_getRecentlyAdded_library`,
  `jellystat_api_getHistory`, `jellystat_api_CheckForUpdates`, `jellystat_auth_isConfigured`
- **Errors:** `jellystat_error_401_no_auth`, `jellystat_error_403_bad_key`

**Not captured** (no live data existed; shapes above come from source or OpenAPI):

- A transcoding session (`TranscodingInfo` non-null)
- Seerr `downloadStatus` items
- A Seerr pending request
- Seerr issues

Capture them later. A transcode can be forced by playing an HEVC file in a browser that cannot decode it.

---

## 7. Open questions

1. **User attribution policy.** Should hub users request as themselves (`X-API-User` = their Seerr id, so non-admins
   create PENDING requests) or always as the admin with `userId` (auto-approved)?
   - This needs a hub-user to Jellyfin-user mapping: the hub login could be Jellyfin auth.
   - Jellyfin users "Rudeus Greyrat" and "Zonika" have no Seerr account yet. Seerr can import them (admin:
     `POST /user/import-from-jellyfin`, not probed).
2. **Native Jellyfin app deep links.** Verify on a real device whether Jellyfin Android or Swiftfin handles an
   item-level URL. Until then, use the web URL in 2.9.
3. **Public URLs.** Confirm the NAS Tailscale hostname/IP that will be configured as `JELLYFIN_PUBLIC_URL` for deep
   links. It could also be set as Seerr's `jellyfinExternalHost`, so Seerr's own `mediaUrl` becomes usable.
4. **`tags` in `POST /request`.** It is in the TypeScript body type but not in the OpenAPI request schema. Check whether
   the validator rejects it, with a dry-run in a test instance, before the UI offers tag selection.
5. **Seerr webhooks vs polling.** Should the gateway register a Seerr webhook for live request updates? That is a
   settings write, so it needs the user's go-ahead.
