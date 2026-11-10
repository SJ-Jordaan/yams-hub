# Sonarr + Radarr integration spec (YAMS Hub gateway)

Status: probed live on Zenith on 2026-11-08 (GET only). Write endpoints were **not called**; their shapes come
from the upstream OpenAPI documents (`src/Sonarr.Api.V3/openapi.json` on Sonarr `main`, `src/Radarr.Api.V3/openapi.json`
on Radarr `master`) and the C# controllers/commands they're built from (cited per endpoint).
Fixtures: `fixtures/arr/*.json` (real responses, trimmed to 3-5 items, secrets redacted). See the index at the end.

---

## 0. Instances, versions, auth

| | Sonarr | Radarr |
|---|---|---|
| Version | 4.0.20.3014 (linuxserver `-ls2`), API **v3**, .NET 6, SQLite | 6.4.4.10685 (`-ls325`), API **v3**, .NET 8, SQLite |
| Internal base URL (gateway, on `yams_network`) | `http://sonarr:8989` | `http://radarr:7878` |
| Host-published (debug only) | `http://192.168.10.183:8989` | `http://192.168.10.183:7878` |
| UrlBase | empty | empty |
| API key source | `/volume1/mediashare/config/sonarr/config.xml` `<ApiKey>`, or `HOMEPAGE_VAR_SONARR_KEY` in `/opt/yams/monitoring/secrets/homepage.env` | `.../radarr/config.xml`, or `HOMEPAGE_VAR_RADARR_KEY` |
| Auth config | `AuthenticationMethod=Forms`, `AuthenticationRequired=DisabledForLocalAddresses` | same |

**Auth header: `X-Api-Key: <key>`** on every `/api/v3/*` call. Also verified working, but don't use them:
`?apikey=<key>` in the query string (ends up in logs) and `Authorization: Bearer <key>`.
Without a key, `/api/v3/*` returns **401** even from a private address. "DisabledForLocalAddresses" only covers the UI and static routes.

**Unauthenticated routes that work from yams_network** (verified from inside the `prowlarr` container, 172.28.0.17):
- `GET /ping` → `200 {"status":"OK"}`. Cheap liveness probe, no key needed.
- `GET /MediaCover/...` and `GET /MediaCoverProxy/...` → 200 without a key, because the caller is a "local address".
  The gateway should still send `X-Api-Key`, so it keeps working if someone sets `AuthenticationRequired=Enabled`.

**Health warnings to surface:** both apps currently report `AllowedHostsCheck` (Allowed Hosts not configured). If the
user ever sets Allowed Hosts, the gateway's requests use the `Host: sonarr` / `Host: radarr` names, so those names must be in the list.
Verified behaviour (issue #2, `tool/sandbox/smoke.py`): `allowedHosts` in `config/host` (comma or semicolon separated;
names or IPs, no port or scheme; `*.domain` accepted, a bare `*` refused by validation) is applied only at restart; then
an unlisted `Host` gets `400 Bad Request - Invalid Hostname` (HTML, `fixtures/arr/servarr_error_400_invalid_hostname.html`)
on every path including `/ping`; `localhost`, `127.0.0.1` and `[::1]` always pass. The gateway maps it to
`upstream_host_rejected` and warns while a saved list is not active yet (API.md §2.5).

**Response encoding:** JSON, camelCase, `Content-Type: application/json; charset=utf-8`. gzip is supported (`Vary: Accept-Encoding`),
so **always send `Accept-Encoding: gzip`**. With it, Radarr `/movie` drops from 1.47 MB to 418 KB and Sonarr `/series` from 304 KB to 75 KB.
Dart `HttpClient` decompresses automatically when `autoUncompress` is true (the default).

### 0.1 Common conventions

**Dates**
- Instants are ISO-8601 UTC with a `Z` and no fractional seconds: `"2026-11-08T07:41:48Z"`.
- Sonarr `airDate` is a **date-only local (network) date string** `"2026-11-05"`. `airDateUtc` is the instant. Show `airDateUtc` converted to the device TZ (Africa/Johannesburg); use `airDate` only as a fallback.
- Radarr release dates (`inCinemas`, `digitalRelease`, `physicalRelease`, `releaseDate`) are midnight UTC instants that really mean a date (`"2026-11-17T00:00:00Z"`). Display them as dates, without TZ conversion.
- Sentinel `"0001-01-01T00:00:00Z"`: `added` on lookup results that are not in the library.
- Durations are .NET TimeSpan strings: `"00:00:00.0008733"` (command `duration`, task `lastDuration`), `"[d.]hh:mm:ss"` for queue `timeleft`. Parse with the regex `^(?:(\d+)\.)?(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?$`.
- `?lastWrite=` on Sonarr cover URLs is a .NET **ticks** value (100 ns since 0001-01-01). It's opaque to the gateway and only used as a cache buster.
- Query-string dates are accepted as `2026-11-01` or `2026-11-01T00:00:00Z`. A garbage value returns 400 (see errors).

**Numbers**
- Sizes (`size`, `sizeOnDisk`, `freeSpace`, `totalSpace`, queue `size`/`sizeleft`) are bytes as JSON numbers. The library total is about 2.78e12 (TV) and 8.1e11 (movies), well under 2^53, so they're safe in Dart web/JS ints. Queue `size`/`sizeleft` are typed `double`.
- `percentOfEpisodes` comes back as a 29-digit decimal (`66.666666666666666666666666670`). `jsonDecode` reads it as a double, which is fine.
- In history records, every value inside **`data` is a string**, even numbers and booleans: `"size": "1496206957"`, `"customFormatScore": "202"`, `"protocol": "2"`. Parse them defensively.

**Paging** (`queue`, `wanted/missing`, `wanted/cutoff`, `history`, `blocklist`)
- Request: `page` (1-based, default 1), `pageSize` (default 10), `sortKey`, `sortDirection` = `ascending|descending|default`.
- Response envelope (verbatim):
  ```json
  {"page":1,"pageSize":10,"sortKey":"episodes.airDateUtc","sortDirection":"descending","totalRecords":892,"records":[...]}
  ```
- `pageSize=0` returns `records: []` with the correct `totalRecords` in about 5 ms. **Use it for dashboard counters** (missing, cutoff unmet, failed downloads).
- `pageSize=-1` (or any large number) returns **all** records in one page. That's 754 KB for 892 missing episodes, so never forward it to the phone.
- A page past the end returns 200 with `records: []`, not an error. `page=0` behaves like page 1.
- An **unknown `sortKey` is silently ignored**: the response falls back to the default key and echoes that key back. Parsers should read the echoed `sortKey` and not assume the requested one.
- Known-good sort keys:
  - Sonarr wanted: `episodes.airDateUtc` (default, desc), `episodes.lastSearchTime`, `series.sortTitle`.
  - Radarr wanted: `movieMetadata.sortTitle` (default, desc), `movieMetadata.year`. Not accepted (fall back to default): `movieMetadata.releaseDate`, `movies.added`.
  - History: `date` (default desc). Queue: default `timeleft`.

**Errors** (all observed live unless marked source):

| Status | When | Body |
|---|---|---|
| 401 | missing/wrong key | empty |
| 404 | unknown id, e.g. `GET /series/999999` | RFC 7807 problem: `{"type":"https://tools.ietf.org/html/rfc7231#section-6.5.4","title":"Not Found","status":404,"traceId":"00-..."}` (Radarr uses the rfc9110 type URL) |
| 400 | bad query param type | `{"type":"…","title":"One or more validation errors occurred.","status":400,"errors":{"start":["The value 'garbage' is not valid."]},"traceId":"…"}` |
| 400 | controller BadRequest, e.g. `GET /episode` without `seriesId` | `{"message":"BadRequest: seriesId or episodeIds must be provided","content":"seriesId or episodeIds must be provided"}` |
| 400 | **FluentValidation on POST/PUT** (source: `SonarrErrorPipeline.cs`) | JSON **array** of `{"propertyName":"TvdbId","errorMessage":"This series has already been added","attemptedValue":371980,"severity":"error","errorCode":"…","isWarning":false,...}`. Radarr's message is `"This movie has already been added"` |
| 409 | conflicts (source) | `{"message": "...", "description": "..."}` |
| 500 | unhandled, e.g. `GET /episode?episodeIds=1&episodeIds=2` with ids that don't exist | `{"message":"Expected query to return 2 rows but returned 0","description":"System.ApplicationException: … stack trace …"}` |
| 503 | metadata source failure, e.g. `series/lookup?term=` (empty) | `{"message":"Search for '' failed. Invalid response received from SkyHook. …","description":"…stack…"}` |

The gateway should map the upstream body into its own error envelope, keep `message`/`errorMessage` (and `propertyName` for
validation), and **never forward `description`**. It holds stack traces and internal paths.

**Latency observed** (from the NAS host; the gateway on yams_network will be similar):

| Call | Time | Size (uncompressed) |
|---|---|---|
| system/status, health, rootfolder, queue, queue/status, tag | 2-40 ms | < 1 KB |
| diskspace | **~320 ms** (statfs on each mount) | 333 B |
| Sonarr series (71) | 40 ms | 304 KB |
| Radarr movie (256) | 160 ms | **1.47 MB** |
| Sonarr episode?seriesId (110 eps) | 6-30 ms | 87 KB |
| wanted/missing p1 (10) | 40 ms (Sonarr) / 10-420 ms (Radarr) | 30-37 KB |
| history p1 (10) | 0.15-1.0 s (first call slow) | 50 KB |
| Sonarr `history/series?seriesId=54` (unpaged) | 0.86 s | **508 KB** |
| series/lookup (SkyHook, remote) | 0.4-0.8 s | 24-44 KB |
| movie/lookup (TMDB via Radarr) | 0.3 s; `lookup/tmdb` 35 ms | 61 KB |
| update | 0.7-0.85 s (contacts GitHub/services) | 4-5 KB |

There's no rate limiting on the *arr APIs themselves. The real limits are the **indexers**: every search command makes
Prowlarr hit external indexers, and the README policy is "upgrades happen gradually via RSS (no bulk searches)".

---

## 1. Dashboard / monitoring

### 1.1 System status
`GET /api/v3/system/status` returns an object. Fields worth showing: `appName`, `version`, `startTime` (uptime = now - startTime),
`branch`, `packageVersion`, `osName`, `isDocker`, `databaseType`. Fixtures: `sonarr_system_status.json`, `radarr_system_status.json`.
Radarr has an extra `isContainerized`, and its `runtimeName` is `"netcore"` where Sonarr's is `".NET"`.

### 1.2 Health
`GET /api/v3/health` returns `[{source, type: "ok"|"notice"|"warning"|"error", message, wikiUrl}]`. Live right now:
```json
[{"source":"IndexerLongTermStatusCheck","type":"warning","message":"Indexers unavailable due to failures for more than 6 hours: Uindex (Prowlarr)","wikiUrl":"https://wiki.servarr.com/sonarr/system#indexers-are-unavailable-due-to-failures"},
 {"source":"AllowedHostsCheck","type":"warning","message":"Allowed Hosts is not configured, …","wikiUrl":"…"}]
```
The `id` field is in the schema but missing from live output. Use `source` as the key. An empty array means healthy.

### 1.3 Disk space
`GET /api/v3/diskspace` returns `[{path, label, freeSpace, totalSpace}]`. Inside the container `/`, `/config` and `/data` are **the same
volume** (7.9 TB total, 4.05 TB free), so **dedupe by `totalSpace`+`freeSpace`, or just show `/data`**. The call is slow (~0.3 s), so cache it for 5 min.
`GET /api/v3/rootfolder` returns `[{id, path, accessible, freeSpace, unmappedFolders[]}]`. That's cheaper and gives free space for the media root.
- Sonarr: `id 1 /data/tvshows`. Radarr: `id 1 /data/movies`.

### 1.4 Queue summary (badge)
`GET /api/v3/queue/status` returns `{totalCount, count, unknownCount, errors, warnings, unknownErrors, unknownWarnings}` (both apps). Use it for a tab badge. Poll every 15-30 s.

### 1.5 Counters
- Missing: `GET /api/v3/wanted/missing?pageSize=0&monitored=true` → `totalRecords`. **Sonarr is at 892** right now, which equals
  Σ(series.statistics.episodeCount - episodeFileCount). Radarr is at 78.
- Cutoff unmet: `GET /api/v3/wanted/cutoff?pageSize=0&monitored=true`. Sonarr 994, Radarr 139. That's mostly existing files below the new TRaSH profiles; it shrinks gradually through RSS.
- Failed downloads: `GET /api/v3/history?pageSize=0&eventType=4` (0 right now).
- Library: Sonarr has 71 series (36 standard / 35 anime), 2.78 TB. Radarr has 256 movies (78 without a file), 0.81 TB.

### 1.6 Other read-only system views (optional "System" screen)
- `GET /api/v3/system/task` returns `[{name, taskName, interval (minutes), lastExecution, lastStartTime, nextExecution, lastDuration}]`.
- `GET /api/v3/command` returns recent and active commands. Mostly `ProcessMonitoredDownloads` / `RefreshMonitoredDownloads` noise every minute, so filter out `trigger == "unspecified"`/`"scheduled"` unless the user is debugging.
- `GET /api/v3/update` returns `[{version, branch, releaseDate, installed, installable, latest, changes:{new[],fixed[]}}]`. In Docker `installable` is
  always false (`packageUpdateMechanism: "docker"`). Updates go through the hub's container-update feature (Watchtower / `yams update-containers`), not through the *arr. It's slow (0.8 s), so cache it for 6 h.
- `GET /api/v3/log?page=1&pageSize=50` is a paged log. `LogLevel` is set to `debug` on both apps, so it's noisy.

---

## 2. Library lists

### 2.1 Sonarr series list
`GET /api/v3/series` returns **an array, unpaged** (71 items, 304 KB, 40 ms). Optional `?tvdbId=371980` returns an array of 0 or 1 items, and `?includeSeasonImages=true` adds season images.
The gateway should **fetch the whole list, cache it about 60 s, and project a slim model** for the phone:

| Field | Type | Notes |
|---|---|---|
| `id` | int | Sonarr series id (the path param everywhere) |
| `title`, `sortTitle` | string | sort by `sortTitle` |
| `year` | int | |
| `status` | `continuing\|ended\|upcoming\|deleted` | |
| `ended` | bool | |
| `network`, `airTime` (`"22:00"`, network local), `runtime` (min), `certification` | | |
| `seriesType` | `standard\|daily\|anime` | **35 series are `anime`. 16 more are `standard` but use anime profile 7: 15 Japanese/Chinese anime (e.g. Frieren, id 25) plus Avatar: The Last Airbender** |
| `qualityProfileId` | int | 9 = WEB-1080p (TRaSH), 7 = [Anime] Remux-1080p, 6 = HD-720p/1080p (legacy, 7 anime series) |
| `monitored` | bool | |
| `monitorNewItems` | `all\|none` | all 71 = `all` |
| `nextAiring` / `previousAiring` | instant, **absent when none** | only 3 series have `nextAiring` today |
| `firstAired`, `lastAired`, `added` | instant | |
| `genres` | string[] | contains `"Anime"` for anime (TVDB genre) |
| `ratings` | `{votes:int, value:double}` | TVDB rating |
| `images` | `[{coverType, url, remoteUrl}]` | see §3 |
| `statistics` | object | `seasonCount`, `episodeFileCount`, `episodeCount`, `totalEpisodeCount`, `sizeOnDisk`, `percentOfEpisodes`, `releaseGroups[]` |
| `seasons` | `[{seasonNumber, monitored, statistics{…, nextAiring?, previousAiring?}}]` | season 0 = specials |
| `path`, `rootFolderPath`, `tvdbId`, `tmdbId`, `imdbId`, `tvMazeId`, `titleSlug`, `tags[]`, `overview`, `alternateTitles[]`, `originalLanguage{id,name}` | | |

What the statistics mean (verified on series 2 / 61):
- `episodeCount`: monitored episodes that have aired or have a file. It's the denominator of progress. Knight of the Seven Kingdoms: 6.
- `totalEpisodeCount`: all episodes including specials and unaired ones. Knight: 15 (9 specials).
- `percentOfEpisodes` = `episodeFileCount / episodeCount * 100`.
- **Missing per series** = `episodeCount - episodeFileCount`. Top today: 7th Heaven 243, The O.C. 92, Avatar 61, Slime 48, Apothecary Diaries 48.

`languageProfileId` is always 1 and deprecated in v4 (`GET /languageprofile` returns a single `"Deprecated"` profile). Ignore it.

### 2.2 Radarr movie list
`GET /api/v3/movie` returns **an array, unpaged** (256 items, **1.47 MB**, 160 ms). Each item carries `alternateTitles` (up to ~40),
`keywords`, the full `movieFile` (with `mediaInfo`) and `ratings` from 5 sources. **The gateway must slim this list.** Use gzip upstream and cache 60 s.
Query params: `tmdbId` (array of 0/1), `excludeLocalCovers` (bool, had no visible effect), `languageId`.

| Field | Type | Notes |
|---|---|---|
| `id`, `title`, `originalTitle`, `sortTitle`, `year`, `runtime`, `certification`, `studio`, `overview`, `genres[]` | | |
| `status` | `tba\|announced\|inCinemas\|released\|deleted` | |
| `isAvailable` | bool | true once `minimumAvailability` is reached |
| `minimumAvailability` | same enum | all 256 = `released` |
| `monitored`, `hasFile` | bool | |
| `qualityProfileId` | int | all 256 = 7 (HD Bluray + WEB) |
| `sizeOnDisk` | int64 | |
| `inCinemas`, `digitalRelease`, `physicalRelease`, `releaseDate` | date-ish instant, may be absent | `releaseDate` = Radarr's "available" date |
| `added`, `lastSearchTime` | instant | |
| `movieFileId` | int | 0 if no file |
| `movieFile` | object or absent | `quality.quality.name`, `size`, `mediaInfo.{videoCodec,resolution,audioCodec,audioChannels,videoDynamicRangeType,subtitles}`, `customFormatScore`, `qualityCutoffNotMet`, `languages[]`, `releaseGroup`, `edition` |
| `statistics` | `{movieFileCount, sizeOnDisk, releaseGroups[], movieFileQualities[]}` | |
| `ratings` | `{imdb:{votes,value,type}, tmdb, metacritic, rottenTomatoes, trakt}` | each optional |
| `collection` | `{title, tmdbId}` or absent | |
| `images` | `[{coverType: poster\|fanart, url, remoteUrl}]` | **`url` uses `?h=<20 hex>`, not `?lastWrite`** |
| `youTubeTrailerId`, `website`, `imdbId`, `tmdbId`, `popularity`, `path`, `rootFolderPath`, `folderName`, `tags[]` | | |

---

## 3. Images (posters, fanart, banners)

### 3.1 URL forms seen in responses
| Form | Where | Example |
|---|---|---|
| `/MediaCover/{id}/{type}.jpg?lastWrite=<ticks>` | Sonarr library series | `/MediaCover/2/poster.jpg?lastWrite=639058149420070772` |
| `/MediaCover/{id}/{type}.jpg?h=<sha256(remoteUrl)[0:20]>` | Radarr library movies | `/MediaCover/1/poster.jpg?h=ee00d06d64cb9c44727a` |
| `/MediaCoverProxy/{sha256 hex}/{filename}` | **lookup results not in the library** (both apps) | `/MediaCoverProxy/ca2d…4b66/619a408fb5e29.jpg` |
| `remoteUrl` only, no `url` | Sonarr season images (`includeSeasonImages`), episode images (`includeImages`, coverType `screenshot`) | `https://artworks.thetvdb.com/banners/v4/episode/9725383/screencap/696f64930ae98.jpg` |
| `remoteUrl` | every image | `https://artworks.thetvdb.com/...` (Sonarr), `https://image.tmdb.org/t/p/original/...` (Radarr) |
| `remotePoster` (top-level string) | lookup results only | |

Cover types: Sonarr `poster`, `fanart`, `banner`, `clearlogo` (`.png`). Radarr `poster`, `fanart`. `clearlogo` can be missing.
Some lookup results have **no images at all** (`images: []`, `remotePoster: null`), so the app needs a placeholder.

### 3.2 Resized variants (exist on disk, verified)
The *arr pre-renders smaller copies with a `-{height}` suffix (source: `MediaCoverService.EnsureResizedCovers`):
- poster: `poster-500.jpg`, `poster-250.jpg`
- fanart: `fanart-360.jpg`, `fanart-180.jpg`
- banner: `banner-70.jpg`, `banner-35.jpg`
- clearlogo: no resized variants

Sizes for Radarr id 1: `poster.jpg` is **1.17 MB**, `poster-500.jpg` 75 KB, `poster-250.jpg` 23 KB. Sonarr id 2: 161 KB / 50 KB / 15 KB.
**The gateway should serve grid views from `poster-250`/`-500` and only use full-size for detail backdrops.**

### 3.3 Upstream response headers
`200 Content-Type: image/jpeg|image/png`, `Cache-Control: max-age=31536000, public`, `Last-Modified: <app build time>`.
`Last-Modified` is the build time, **not** the file time, so it's useless for revalidation.
A missing cover returns **`404` with `Content-Type: application/problem+json` and the same `max-age=31536000`**. **Don't cache upstream 404s**, or the image stays broken for a year.

### 3.4 Recommended gateway image route
```
GET /img/{svc}/{id}/{type}?size=250|500|full&v={lastWrite|h}
```
- Upstream: `http://{svc}:{port}/MediaCover/{id}/{type}{-size}.{jpg|png}` with `X-Api-Key`. Pass `v` through only as part of the cache key.
  The upstream ignores the query; the version token comes from the `url` field the gateway already parsed.
- When rewriting a list item for the app, parse `url`, keep the `lastWrite`/`h` value, and emit the gateway URL. The app's image cache then invalidates automatically when the *arr refreshes art.
- Send `Cache-Control: public, max-age=31536000, immutable` (the version token is in the URL), plus an ETag from the `v` value.
- If `/MediaCover` returns 404, **fall back to fetching `remoteUrl`**. That happens for freshly added items before the cover download runs.

**`/MediaCoverProxy/{hash}/…` is fragile.** The hash → remote URL mapping lives in an **in-memory cache for 24 h** that's only populated when a
lookup is made (source: `MediaCoverProxy.RegisterUrl`). An unknown hash returns **500** (verified). It also doesn't survive container restarts.
**For search/lookup results, the gateway should proxy `remoteUrl` directly** through a host allowlist
(`artworks.thetvdb.com`, `image.tmdb.org`, `assets.fanart.tv`, `*.tvmaze.com`). TMDB supports smaller sizes by swapping
`/t/p/original/` for `/t/p/w342/` or `/t/p/w500/`. TVDB has no size variants.
Season and episode images (remote only) take the same remote-proxy path.

---

## 4. Series detail (Sonarr)

### 4.1 Series
`GET /api/v3/series/{id}` (optional `includeSeasonImages=true`) returns the same resource as the list, including `seasons[].statistics`. 404 if missing. Fixture: `sonarr_series_id.json` (anime, id 54).

### 4.2 Episodes
`GET /api/v3/episode?seriesId={id}` returns all episodes as an array (110 for Slime, 87 KB, 6 ms).
Params: `seasonNumber` (filter), `episodeIds` (repeatable; **500 if any id doesn't exist**), `episodeFileId`,
`includeSeries` (false), `includeEpisodeFile` (false; embeds `episodeFile` without `mediaInfo`), `includeImages` (false; adds the screenshot `remoteUrl`).
Without `seriesId`/`episodeIds` it returns **400**.
- Recommended: one call per series detail, `episode?seriesId=X&includeEpisodeFile=true`. Group by `seasonNumber` client-side, specials (0) last.

`EpisodeResource` fields:

| Field | Type | Notes |
|---|---|---|
| `id` | int | episode id (used by EpisodeSearch / monitor) |
| `seriesId`, `seasonNumber`, `episodeNumber` | int | |
| `absoluteEpisodeNumber` | int, optional | **anime**: e.g. Slime S03E01 = abs 49 |
| `sceneAbsoluteEpisodeNumber`, `sceneSeasonNumber`, `sceneEpisodeNumber` | int, optional | XEM scene mapping (anime). Slime S03E01 → scene abs 1 |
| `unverifiedSceneNumbering` | bool | |
| `title`, `overview` | string, optional | `overview` can be missing for future episodes |
| `airDate` | `"YYYY-MM-DD"` (network-local), optional | |
| `airDateUtc` | instant, optional | absent for TBA episodes |
| `runtime` | int min | |
| `hasFile`, `monitored` | bool | |
| `episodeFileId` | int | 0 = none |
| `finaleType` | `"series"\|"season"\|"midseason"`, optional | |
| `lastSearchTime` | instant, optional | |
| `tvdbId` | int | |
| `episodeFile` | object, only with `includeEpisodeFile` | |
| `images` | `[{coverType:"screenshot", remoteUrl}]`, only with `includeImages` | |

Display rule for anime: when `series.seriesType == "anime"` and `absoluteEpisodeNumber` is present, show
`S03E01 (049)`. That matches Sonarr's own file naming, e.g. `S03E17 - 065 - The Lightspeed Hero`.

### 4.3 Episode files
`GET /api/v3/episodefile?seriesId={id}` returns an array (also `episodeFileIds=`). `GET /api/v3/episodefile/{id}` returns one.
Fields: `id`, `seriesId`, `seasonNumber`, `relativePath`, `path`, `size`, `dateAdded`, `sceneName`, `releaseGroup`, `languages[]`,
`quality{quality{id,name,source,resolution},revision{version,real,isRepack}}`, `customFormats[{id,name}]`, `customFormatScore`,
`qualityCutoffNotMet` (bool), `indexerFlags` (int), `releaseType` (`unknown|singleEpisode|multiEpisode|seasonPack`),
`mediaInfo{audioBitrate, audioChannels (double, 5.1), audioCodec, audioLanguages ("eng/jpn"), audioStreamCount, videoBitDepth, videoBitrate,
videoCodec, videoFps, videoDynamicRange, videoDynamicRangeType ("HDR10"), resolution ("1920x1080"), runTime ("41:55"), scanType, subtitles ("eng/eng")}`.
`episodefile?seriesId=54` takes 0.23 s and 80 KB. Load it lazily when the user opens a file sheet, or use `includeEpisodeFile` on the episode call.

### 4.4 Per-series history
`GET /api/v3/history/series?seriesId=54[&seasonNumber=3][&eventType=1][&includeEpisode=true]` is **unpaged**. It returned 508 KB / 0.86 s.
Prefer the paged form: **`GET /api/v3/history?seriesIds=54&page=1&pageSize=20&includeEpisode=true`**
(returned `totalRecords: 708` in 40 ms).

---

## 5. Movie detail (Radarr)

- `GET /api/v3/movie/{id}` returns `MovieResource` (same fields as the list, including `movieFile`). 404 if missing.
- `GET /api/v3/moviefile?movieId={id}` returns an array of `MovieFileResource`. `GET /api/v3/moviefile/{id}` returns one. Same shape as Sonarr's episode file plus `movieId`, `edition`, and `quality.quality.modifier` (`"none"|"remux"|…`).
- `GET /api/v3/history/movie?movieId={id}[&eventType=][&includeMovie=false]` is unpaged but small per movie. Or use `history?movieIds={id}`.
- `GET /api/v3/credit?movieId={id}` returns cast/crew with images (30 KB). Optional.
- `GET /api/v3/movie/{id}/folder` returns `{"folder":"Zootopia 2 (2025) [tmdbid-1084242]"}`.
- `GET /api/v3/collection` is 400 KB. Skip it for v1.

---

## 6. Search for new items (lookup) and add

### 6.1 Sonarr lookup
`GET /api/v3/series/lookup?term={urlencoded}`. Remote call (SkyHook/TVDB), 0.4-0.8 s.
- `term=tvdb:371980` does an exact TVDB lookup (4 ms when the series is already in the library). `term=imdb:tt11280740` also works.
  `term=` (empty) returns **503**. No match returns `[]`.
- The response is an array of `SeriesResource` with `folder` and `remotePoster` added.
- **In-library detection:** an in-library result has **`id` (int)**, `path` and a real `added`. A new result has **no `id` key**, no `path`,
  `added: "0001-01-01T00:00:00Z"` and `qualityProfileId: 0`. Lookup `statistics` are zero/unreliable even for library items, so use the cached library list.
- New-result images point at `/MediaCoverProxy/...` (see §3.4). Use `remotePoster`/`remoteUrl`.
- **Anime detection for defaults:** `genres` contains `"Anime"` (all 35 anime-type series and all 15 Japanese/Chinese anime on `standard` have it, and no other series does;
  `originalLanguage.name == "Japanese"` is a secondary signal). For anime, suggest `seriesType: "anime"` + `qualityProfileId: 7`.
  Otherwise suggest `standard` + `9`. These match Seerr's configured defaults: `activeProfileId 9 "WEB-1080p"`, `activeAnimeProfileId 7 "[Anime] Remux-1080p"`, `activeDirectory /data/tvshows`, `enableSeasonFolders true`.

### 6.2 Sonarr add — `POST /api/v3/series` (not called; verified from source)
Source: `SeriesController.AddSeries` → `AddSeriesService.AddSeries`. The server re-fetches metadata by `tvdbId`, so only these matter:
**`tvdbId` (>0, required), `title` (required, non-empty), `qualityProfileId` (must exist), `rootFolderPath` (must exist; or give an explicit `path`)**,
plus `seriesType`, `seasonFolder`, `monitored`, `monitorNewItems`, `tags`, `seasons`, `addOptions`. The path is built as `rootFolderPath/{folder}` when `path` is empty.
The simplest correct approach is **take the lookup object, override these fields, and POST it**. That's what Sonarr's UI does:
```json
{
  "tvdbId": 371980,
  "title": "Severance",
  "qualityProfileId": 9,
  "rootFolderPath": "/data/tvshows",
  "seriesType": "standard",
  "seasonFolder": true,
  "monitored": true,
  "monitorNewItems": "all",
  "tags": [],
  "seasons": [ {"seasonNumber": 0, "monitored": false}, {"seasonNumber": 1, "monitored": true}, {"seasonNumber": 2, "monitored": true} ],
  "addOptions": {
    "monitor": "all",
    "searchForMissingEpisodes": true,
    "searchForCutoffUnmetEpisodes": false,
    "ignoreEpisodesWithFiles": false,
    "ignoreEpisodesWithoutFiles": false
  }
}
```
- `addOptions.monitor` (`MonitorTypes`): `unknown, all, future, missing, existing, firstSeason, lastSeason, latestSeason, pilot, recent,
  monitorSpecials, unmonitorSpecials, none, skip`. With `"none"`, the server forces `monitored=false`. It's applied to seasons/episodes after the
  first refresh, overriding `seasons[].monitored`. Offer these in the app: all / future / missing / existing / firstSeason / latestSeason / pilot / none.
- `searchForMissingEpisodes: true` queues a `SeriesSearch` once the add completes. That's what "Add + search" means.
- `languageProfileId` is ignored in v4. Don't send it, or send 1.
- Response: **201 Created**, body = the full new `SeriesResource` (with `id`). Duplicate returns **400** `[{"propertyName":"TvdbId","errorMessage":"This series has already been added",…}]`.
  A bad root folder or profile also returns 400 with a validation array.

### 6.3 Radarr lookup
- `GET /api/v3/movie/lookup?term=dune` (0.3 s). `term=tmdb:438631` or `imdb:tt…` give exact matches.
- `GET /api/v3/movie/lookup/tmdb?tmdbId=693134` returns **one object** (not an array), 35 ms. `GET /api/v3/movie/lookup/imdb?imdbId=tt15239678` also returns an object.
- In-library: has `id`, `path`, a real `added`, `movieFile`. New: **no `id`/`path`/`hasFile` keys**, `added` sentinel, `qualityProfileId 0`,
  `minimumAvailability: "tba"`, `monitored: false`. **Gotcha:** `hasFile` is **absent even for in-library lookup results**
  (Dune id 8 in the library: `hasFile` null), so use `movieFileId > 0` or the cached library.
- Images: `/MediaCover/{id}/…?h=` for library items, `/MediaCoverProxy/…` for new ones. Use `remotePoster`.

### 6.4 Radarr add — `POST /api/v3/movie` (not called; verified from source)
Source: `MovieController.AddMovie` → `AddMovieService.AddMovie`. Validators: **`tmdbId` required (not empty, must not already exist)**,
`title` required only when `tmdbId <= 0`, **`qualityProfileId` must exist**, **`rootFolderPath` required unless `path` is given**.
```json
{
  "tmdbId": 693134,
  "title": "Dune: Part Two",
  "year": 2024,
  "qualityProfileId": 7,
  "rootFolderPath": "/data/movies",
  "minimumAvailability": "released",
  "monitored": true,
  "tags": [],
  "addOptions": {
    "monitor": "movieOnly",
    "searchForMovie": true,
    "addMethod": "manual"
  }
}
```
- **Always send `minimumAvailability`.** If it's omitted it defaults to the enum's zero value (`tba`), while the library and Seerr all use `"released"`.
- `addOptions.monitor`: `movieOnly | movieAndCollection | none`. `addMethod`: `manual | list | collection`. `addOptions.ignoreEpisodesWith*` exist in the schema but are unused.
- Response: **201** with the new `MovieResource`. Duplicate returns 400 `"This movie has already been added"`.

### 6.5 Quality profiles and root folders (for the add sheet)
`GET /api/v3/qualityprofile` returns `[{id, name, upgradeAllowed, cutoff, items[], minFormatScore, cutoffFormatScore, minUpgradeFormatScore, formatItems[], language (Radarr)}]`.
The full payload is big (108 KB Sonarr / 81 KB Radarr, because `formatItems` lists every custom format). The app only needs `{id, name}`, so cache it for 10 min.

| Sonarr id | name | notes |
|---|---|---|
| 9 | **WEB-1080p** (TRaSH) | `upgradeAllowed`, cutoff 1002 = group "WEB 1080p", cutoffFormatScore 10000, minUpgradeFormatScore 1. **Default for non-anime** |
| 7 | **[Anime] Remux-1080p** (TRaSH anime) | cutoff 1004, minFormatScore 100. **Default for anime** |
| 6 | HD - 720p/1080p | legacy; 7 anime series still use it |
| 1-5, 8 | Any, SD, HD-720p, HD-1080p, Ultra-HD, Observe 480p | stock |

| Radarr id | name | notes |
|---|---|---|
| 7 | **HD Bluray + WEB** (TRaSH) | allowed: Bluray-720p, WEB 1080p group, Bluray-1080p; cutoff 7 (Bluray-1080p); cutoffFormatScore 10000. **Default; all 256 movies use it** |
| 1-6 | Any, SD, HD-720p, HD-1080p, Ultra-HD, HD - 720p/1080p | stock; `language: Original` |

`items[]` is either a single quality `{quality:{id,name,source,resolution}, items:[], allowed}` or a group
`{id: 1000+, name, items:[{quality…}], allowed}`. `cutoff` refers to a quality id **or** a group id.
These profiles are managed by **recyclarr** (weekly sync). The hub must **not** edit profiles. It's read-only.

`GET /api/v3/rootfolder`: Sonarr `[{id:1,path:"/data/tvshows",accessible:true,freeSpace,unmappedFolders:[]}]`, Radarr `/data/movies`.
`GET /api/v3/tag` returns `[]` on both (no tags in use).

---

## 7. Monitoring toggles (not called; from source)

All PUT responses below are **202 Accepted** with the updated resource as the body (`RestController.Accepted`).

### 7.1 Series monitored / profile / type — `PUT /api/v3/series/{id}[?moveFiles=false]`
Body = **the complete SeriesResource from `GET /series/{id}`, modified**. `ToModel` + `Series.ApplyChanges` copy
`tvdbId, seasons, path, qualityProfileId, seasonFolder, monitored, monitorNewItems, seriesType, rootFolderPath, tags` from the body.
**If `seasons` is missing it's replaced with an empty list, and `path` must be non-empty (PutValidator).** Never send a partial body.
The route id overrides a body `id` of 0.
- Season monitor toggle: flip `seasons[n].monitored` in the full body and PUT. `SeriesService.UpdateSeries(updateEpisodesToMatchSeason=true)` then
  **sets every episode in that season to the same monitored state** (`SetEpisodeMonitoredBySeason`). That's the same behaviour as the UI's season bookmark.
- Changing `seriesType` (e.g. standard → anime) is allowed here and affects future searches/naming. Changing `path` with `moveFiles=true` queues a MoveSeries. **The hub shouldn't expose path moves.**
- Lighter alternative for bulk/series-level monitor only: **`PUT /api/v3/series/editor`** with
  `{"seriesIds":[2,25],"monitored":false}` (optional `qualityProfileId`, `seriesType`, `monitorNewItems`, `tags`+`applyTags: add|remove|replace`).
  That needs no full body. Prefer it for the series-level toggle.
- Season pass alternative: `POST /api/v3/seasonpass` `{"series":[{"id":2,"monitored":true,"seasons":[{"seasonNumber":1,"monitored":false}]}],"monitoringOptions":{"monitor":"none"}}`.
  It's in the schema but not needed.

### 7.2 Episode monitor
- **`PUT /api/v3/episode/monitor`** body `{"episodeIds":[76,77],"monitored":true}` (optional `?includeImages=false`) returns 202 with an array of EpisodeResource.
  This is the preferred route (bulk-capable).
- `PUT /api/v3/episode/{id}` body `{"monitored":false}` (only `monitored` is read; the route id is used) returns 202 with an EpisodeResource.

### 7.3 Movie monitored / profile — `PUT /api/v3/movie/{id}[?moveFiles=false]`
Body = full MovieResource. `Movie.ApplyChanges` copies `path, qualityProfileId, monitored, minimumAvailability, rootFolderPath, tags, addOptions`.
`path` must be non-empty. Simpler: **`PUT /api/v3/movie/editor`** `{"movieIds":[1],"monitored":false}` (optional `qualityProfileId`, `minimumAvailability`, `tags`/`applyTags`)
returns 202.

---

## 8. Commands (search, refresh) — `POST /api/v3/command` (not called; from source)

Body is `{"name": "<CommandName>", ...command properties in camelCase}`. The name is matched **case-insensitively** against the command class
name minus `Command` (`CommandController.StartCommand`). **An unknown name throws, which comes back as 500**, so validate names in the gateway.
Response: **201 Created** with a CommandResource: `{id, name, commandName, message?, body{…}, priority, status, result, queued, started?, ended?, duration?, trigger:"manual", stateChangeTime}`.
Poll **`GET /api/v3/command/{id}`** (verified to work) until `status` is `completed|failed|aborted|cancelled|orphaned`. Statuses:
`queued, started, completed, failed, aborted, cancelled, orphaned`. Results: `unknown, successful, unsuccessful`.
**Dedupe:** if an identical command (same name and body) is already queued or started, the server returns the *existing* command instead of a new one (`CommandQueueManager.Push`).

### Sonarr
| Purpose | Body |
|---|---|
| Search whole series | `{"name":"SeriesSearch","seriesId":2}` |
| Search one season | `{"name":"SeasonSearch","seriesId":2,"seasonNumber":1}` |
| Search episode(s) | `{"name":"EpisodeSearch","episodeIds":[76,77]}` |
| Search missing for one series | `{"name":"MissingEpisodeSearch","seriesId":2,"monitored":true}` |
| Search missing — **all 892** | `{"name":"MissingEpisodeSearch","monitored":true}` (seriesId omitted = global) |
| Search cutoff unmet | `{"name":"CutoffUnmetEpisodeSearch","seriesId":2,"monitored":true}`; omit seriesId for global |
| Refresh metadata (+rescan) | `{"name":"RefreshSeries","seriesIds":[2]}` (legacy `"seriesId":2` also accepted; empty = all series) |
| Rescan disk only | `{"name":"RescanSeries","seriesId":2}` |
| RSS sync now | `{"name":"RssSync"}` |
| Refresh queue from client | `{"name":"RefreshMonitoredDownloads"}` |

### Radarr
| Purpose | Body |
|---|---|
| Search movie(s) | `{"name":"MoviesSearch","movieIds":[1]}` |
| Search all missing (78) | `{"name":"MissingMoviesSearch"}` (optional `filterKey`/`filterValue`) |
| Search all cutoff unmet (139) | `{"name":"CutoffUnmetMoviesSearch"}` |
| Refresh metadata | `{"name":"RefreshMovie","movieIds":[1]}` (empty = all) |
| RSS sync / refresh queue | `{"name":"RssSync"}` / `{"name":"RefreshMonitoredDownloads"}` |

**Safety policy for the gateway.** The README says "Upgrades happen gradually via RSS (no bulk searches)".
- Allow per-item searches (Series/Season/Episode/Movies) freely, with a client-side debounce.
- **Gate the global searches** (`MissingEpisodeSearch`/`CutoffUnmetEpisodeSearch` without `seriesId`, `MissingMoviesSearch`, `CutoffUnmetMoviesSearch`)
  behind an explicit "are you sure, this hits indexers for 892 episodes" confirmation, or don't expose them at all in v1.
- The indexer `Uindex` is currently failing (health warning), so searches can be slow or return nothing. Surface `health` next to search buttons.

Interactive/manual search (`GET /api/v3/release?episodeId=` / `?movieId=`) **is a GET but queries every indexer live** (10-60 s)
and is not read-only in effect. It was not probed. Don't put it in v1; if it's added later, grabbing is `POST /api/v3/release` `{"guid","indexerId"}`.

---

## 9. Queue (downloads tracked by the *arr)

`GET /api/v3/queue?page=1&pageSize=50&includeSeries=true&includeEpisode=true` (Sonarr) /
`GET /api/v3/queue?page=1&pageSize=50&includeMovie=true` (Radarr) returns the paged envelope. Default `sortKey: "timeleft"`, desc.
Other params: `includeUnknownSeriesItems` / `includeUnknownMovieItems` (false), `seriesIds`/`movieIds`, `protocol`, `quality`, `status` (array).
**The queue was empty on both apps during probing** (`totalRecords: 0`), so the record fields below come from the OpenAPI `QueueResource`. Make the parsers tolerant.

Queue record (Sonarr; Radarr has the same fields minus series/episode/seasonNumber/episodeHasFile, plus `movieId`/`movie`):

| Field | Type | Notes |
|---|---|---|
| `id` | int | **queue id**. Used for delete/grab. Not stable across restarts |
| `seriesId`, `episodeId`, `seasonNumber` | int? | season packs create **one queue record per episode**, all with the same `downloadId`. Group by `downloadId` in the app |
| `series`, `episode` | object, only with include flags | |
| `title` | string | release name |
| `size`, `sizeleft` | double bytes | progress = `1 - sizeleft/size` (guard size 0) |
| `timeleft` | `"hh:mm:ss"` / `"d.hh:mm:ss"`, optional | |
| `estimatedCompletionTime`, `added` | instant? | |
| `status` | `unknown, queued, paused, downloading, completed, failed, warning, delay, downloadClientUnavailable, fallback` | download-client state |
| `trackedDownloadStatus` | `ok, warning, error` | colour of the row |
| `trackedDownloadState` | `downloading, importBlocked, importPending, importing, imported, failedPending, failed, ignored` | `importBlocked`/`importPending` = **manual import needed** (README routes these to Discord #alerts) |
| `statusMessages` | `[{title: string, messages: string[]}]` | show them under the row when present |
| `errorMessage` | string? | |
| `downloadId` | string | qBittorrent **info-hash upper-case** (`B3CF3BAAFF…`). Joins to the qBittorrent API (lower-case hash) |
| `protocol` | `unknown, usenet, torrent` | always torrent here (SABnzbd disabled) |
| `downloadClient` | `"qBittorrent"` | |
| `indexer` | e.g. `"Nyaa.si (Prowlarr)"` | |
| `quality`, `languages[]`, `customFormats[]`, `customFormatScore` | | |
| `outputPath` | string? | |
| `episodeHasFile` (Sonarr) | bool | true = this is an upgrade |
| `downloadClientHasPostImportCategory` | bool | |

Illustrative record (**synthetic**, built from the schema, not captured):
```json
{"seriesId":54,"episodeId":5580,"seasonNumber":4,"title":"[SubsPlease] Tensei Shitara Slime Datta Ken S4 (01-24) (1080p) [Batch]",
 "size":35111357644,"sizeleft":12000000000,"timeleft":"00:41:10","status":"downloading","trackedDownloadStatus":"warning",
 "trackedDownloadState":"importPending","statusMessages":[{"title":"…","messages":["No files found are eligible for import in …"]}],
 "downloadId":"E66AAC4C7D8A4F813A4E5B3A63C1BB52BEEE342E","protocol":"torrent","downloadClient":"qBittorrent","indexer":"Nyaa.si (Prowlarr)",
 "episodeHasFile":false,"id":123456}
```
Other queue reads: `GET /api/v3/queue/details?seriesId=|episodeIds=|movieId=` (unpaged array, used on detail screens), `GET /api/v3/queue/status` (§1.4).

### Queue actions (not called; from `QueueController` / `QueueActionController`)
- **Remove:** `DELETE /api/v3/queue/{id}?removeFromClient=true&blocklist=false&skipRedownload=false&changeCategory=false` returns 200 with an empty body; 404 if the id is gone.
  - "Remove & blocklist (search again)": `removeFromClient=true&blocklist=true&skipRedownload=false`.
  - "Blocklist only, don't search": `blocklist=true&skipRedownload=true`.
  - `changeCategory=true` only applies when the client has a post-import category (`downloadClientHasPostImportCategory`).
- **Bulk remove:** `DELETE /api/v3/queue/bulk?removeFromClient=true&blocklist=true` body `{"ids":[1,2,3]}`. **DELETE with a JSON body**: Dart's
  `http.delete(body:)` / `Request('DELETE')` supports it; set `Content-Type: application/json`.
- **Grab a delayed/pending item:** `POST /api/v3/queue/grab/{id}` (no body), or `POST /api/v3/queue/grab/bulk` `{"ids":[…]}`.
- decluttarr already auto-removes stalled/failed/fake downloads with blocklisting, so items can disappear between polls. Treat 404 on delete as success.
- Blocklist view: `GET /api/v3/blocklist?page=1&pageSize=20` (paged; empty now). `DELETE /api/v3/blocklist/{id}` (not called).

### 9.1 Manual import (added in the design review; not called, from Sonarr v4 / Radarr v5 source)

Used to resolve `importBlocked`/`importPending` queue items (the README's "manual import needed" Discord alert).

- **Candidates (read):** `GET /api/v3/manualimport?downloadId=<downloadId as in the queue>&seriesId=<id>&filterExistingFiles=true`
  (Sonarr; optional `seasonNumber`), `GET /api/v3/manualimport?downloadId=&movieId=&filterExistingFiles=true` (Radarr).
  `folder=<path>` is the alternative to `downloadId` (not used by the hub). Returns an **array** of
  `ManualImportResource`:
  `{id, path, relativePath, folderName, name, size, series?, seasonNumber?, episodes:[EpisodeResource], episodeFileId?, movie?, movieFileId?, releaseGroup, quality:{quality:{id,name,source,resolution}, revision:{version,real,isRepack}}, languages:[{id,name}], releaseType ("singleEpisode"|"multiEpisode"|"seasonPack"|"unknown", Sonarr), qualityWeight, downloadId, customFormats, customFormatScore, indexerFlags, rejections:[{reason, type: "permanent"|"temporary"}]}`.
  The read runs the *arr's parser over the files on disk; it is slow on big season packs (seconds), hence the hub's
  60 s timeout. It changes nothing.
- **Execute (write):** `POST /api/v3/command` with
  `{"name": "ManualImport", "importMode": "auto"|"move"|"copy", "files": [{"path": "...", "seriesId": 54, "episodeIds": [5580], "quality": <as returned>, "languages": <as returned>, "releaseGroup": "...", "downloadId": "...", "indexerFlags": 0, "releaseType": "singleEpisode"}]}`
  (Sonarr) / `{"name": "ManualImport", "importMode": "auto", "files": [{"path", "movieId", "quality", "languages", "releaseGroup", "downloadId", "indexerFlags": 0}]}`
  (Radarr). Returns 201 with the command resource; poll `GET /api/v3/command/{id}`. `auto` = move for completed
  torrent downloads that are not seeding, copy (hardlink) otherwise; the hub defaults to `auto`.
- `POST /api/v3/manualimport` (without `/command`) only **re-evaluates** edited candidates (returns updated
  rejections); the hub does not need it.

### 9.2 Interactive release search (added in the design review; not called, from source)

- **Search (read, but it queries every indexer live):** `GET /api/v3/release?episodeId=<id>` or
  `?seriesId=<id>&seasonNumber=<n>` (Sonarr), `GET /api/v3/release?movieId=<id>` (Radarr). Takes 5–120 s (FlareSolverr
  indexers are slow). Returns an array of `ReleaseResource`:
  `{guid, quality, qualityWeight, age, ageHours, ageMinutes, size, indexerId, indexer, releaseGroup, subGroup, releaseHash, title, fullSeason, sceneSource, seasonNumber, languages, languageWeight, airDate, seriesTitle, episodeNumbers, absoluteEpisodeNumbers, mappedSeasonNumber, mappedEpisodeNumbers, approved, temporarilyRejected, rejected, tvdbId, tvRageId, imdbId, rejections: string[], publishDate, commentUrl, downloadUrl, infoUrl, episodeRequested, downloadAllowed, releaseWeight, customFormats, customFormatScore, magnetUrl, infoHash, seeders, leechers, protocol, indexerFlags, isDaily, isAbsoluteNumbering, isPossibleSpecialEpisode, special, seriesId, episodeId, episodeIds, downloadClientId, downloadClient, shouldOverride}`
  (Radarr: `movieTitles`, `movieId`, `edition`, no series/episode fields). The *arr caches each result for 30 min
  keyed by `indexerId` + `guid`.
- **Grab (write):** `POST /api/v3/release` with `{"guid": "...", "indexerId": 12}` (optional overrides
  `seriesId`/`episodeIds`/`movieId`, `downloadClientId`, `shouldOverride`). 200 with the release; 404 when the cached
  release expired ("Couldn't find requested release in cache, cache timeout probably expired."). The grab goes to the
  *arr's download client with its category (`tv-sonarr`/`radarr`), so it is tracked and imported normally.

---

## 10. Calendar

- Sonarr: `GET /api/v3/calendar?start=2026-11-01T00:00:00Z&end=2026-11-22T00:00:00Z&unmonitored=false&includeSeries=true[&includeEpisodeFile=false][&includeEpisodeImages=false][&tags=]`
  returns an **array of EpisodeResource** sorted by air date, each with an embedded `series` when `includeSeries=true`.
  - The embedded `series` has **no `statistics`** but does have `images`, `title`, `seriesType`, etc.
  - With no `start`/`end`, the range is today → today+2 days (it returned `[]` today).
  - `unmonitored=true` also includes unmonitored episodes (e.g. specials S00E56).
  - Right now only 2 series air in the next 6 weeks (Apothecary Diaries id 159, Ramparts of Ice id 140): 6 eps in 3 weeks.
- Radarr: `GET /api/v3/calendar?start=&end=&unmonitored=true[&tags=]` returns an **array of MovieResource** whose `inCinemas`, `digitalRelease` or `physicalRelease`
  falls in the window. The client must work out *which* date matched to label the event ("In cinemas" / "Digital" / "Physical"). 7 movies Oct-Jan.
  No include flags.
- A 3-week window is ~18 KB with series included. For the app, request ±2 weeks, cache 5 min, and merge both apps into one timeline keyed by instant.

---

## 11. Wanted

### 11.1 Missing
- Sonarr: `GET /api/v3/wanted/missing?page=1&pageSize=20&includeSeries=true&monitored=true&sortKey=episodes.airDateUtc&sortDirection=descending`
  (+ `includeImages`). Records = EpisodeResource (+`series`). `totalRecords` 892.
  The embedded `series` is the full resource (~3 KB per record), so the gateway should slim it to `{id,title,seriesType,images}`.
- Radarr: `GET /api/v3/wanted/missing?page=1&pageSize=20&monitored=true&sortKey=movieMetadata.sortTitle&sortDirection=ascending`.
  Records = MovieResource. `totalRecords` 78. **Gotcha:** this includes movies that are **not yet available** (`isAvailable:false`, e.g. "The Odyssey"
  `status: inCinemas`), so filter or label them ("not released yet") using `isAvailable`. No `includeMovie` param exists (the records are movies).

### 11.2 Cutoff unmet
- Sonarr: `GET /api/v3/wanted/cutoff?page=1&pageSize=20&includeSeries=true&monitored=true` (+ `includeEpisodeFile`, `includeImages`). 994 records,
  EpisodeResource. To show "current quality → target", add `includeEpisodeFile=true` (episodeFile.quality + customFormatScore) and resolve the profile cutoff name from §6.5.
- Radarr: `GET /api/v3/wanted/cutoff?page=1&pageSize=20&monitored=true`. 139 records. **Records have NO `movieFile` object** (only `movieFileId`),
  so fetch `moviefile/{movieFileId}` for the current quality when it's needed.
- Actions per record: EpisodeSearch / MoviesSearch (§8). "Search all" → see the safety policy.

---

## 12. History (activity feed)

- Sonarr: `GET /api/v3/history?page=1&pageSize=20&sortKey=date&sortDirection=descending&includeSeries=true&includeEpisode=true`
  [`&eventType=1&eventType=3` (repeatable **integers only**; names return 400)] [`&seriesIds=54`] [`&episodeId=`] [`&downloadId=`]. `totalRecords` 6832.
- Radarr: `GET /api/v3/history?page=1&pageSize=20&sortKey=date&sortDirection=descending&includeMovie=true[&eventType=][&movieIds=]`. 940.
- Incremental: `GET /api/v3/history/since?date=2026-11-07T00:00:00Z[&eventType=3]` returns an **unpaged array** (49 records / 75 KB for one day on Sonarr).
  Useful for "what's new since last open", but cap the window at 24-48 h.

Event type integers:

| int | Sonarr `eventType` | Radarr `eventType` |
|---|---|---|
| 1 | `grabbed` | `grabbed` |
| 2 | `seriesFolderImported` | (unused) |
| 3 | `downloadFolderImported` | `downloadFolderImported` |
| 4 | `downloadFailed` | `downloadFailed` |
| 5 | `episodeFileDeleted` | (unused) |
| 6 | `episodeFileRenamed` | **`movieFileDeleted`** |
| 7 | `downloadIgnored` | `movieFolderImported` |
| 8 | – | `movieFileRenamed` |
| 9 | – | `downloadIgnored` |

The JSON field is the **camelCase name**. Filters take the **integer**. The numbering differs between apps from 5 upward.

Record: `{id, episodeId|movieId, seriesId, sourceTitle, languages[], quality, customFormats[], customFormatScore, qualityCutoffNotMet, date, downloadId?, eventType, data{…strings…}, series?, episode?, movie?}`.
`data` keys depend on the event:
- grabbed: `indexer`, `releaseGroup`, `size`, `publishedDate`, `downloadClient`, `downloadClientName`, `nzbInfoUrl`, `releaseSource` (`Rss|Search|InteractiveSearch`), `indexerFlags`, `releaseType`, `torrentInfoHash`, `customFormatScore`, `age*`, `protocol`, `guid`, **`downloadUrl`**
- downloadFolderImported: `fileId`, `droppedPath`, `importedPath`, `downloadClient`, `releaseGroup`, `size`, `customFormatScore`, `indexerFlags`, `releaseType`
- episode/movieFileDeleted: `reason` (observed `ManualOverride`; other values from the DeleteMediaFileReason enum, e.g. `Upgrade`, `MissingFromDisk`, `Manual`), `releaseGroup`, `size`
- renamed: `sourcePath`, `path`, …

**SECURITY GOTCHA:** `grabbed` records contain `data.downloadUrl = "http://prowlarr:9696/5/download?apikey=<PROWLARR KEY>&link=…"`, and `data.guid` is a full magnet.
**The gateway must strip `downloadUrl` and `guid` (or at least the `apikey` query param) before anything reaches the phone.**
Fixtures have it redacted as `apikey=REDACTED`.

---

## 13. Delete (not called; from source)

- Sonarr: `DELETE /api/v3/series/{id}?deleteFiles=false&addImportListExclusion=false` returns 200 with an empty body.
- Radarr: `DELETE /api/v3/movie/{id}?deleteFiles=false&addImportExclusion=false` returns 200. **The param name differs: `addImportExclusion` (Radarr) vs `addImportListExclusion` (Sonarr).**
- Bulk: `DELETE /api/v3/series/editor` `{"seriesIds":[..],"deleteFiles":true,"addImportListExclusion":false}` / `DELETE /api/v3/movie/editor` `{"movieIds":[..],"deleteFiles":true,"addImportExclusion":false}`.
- Delete a single file: `DELETE /api/v3/episodefile/{id}`, `DELETE /api/v3/moviefile/{id}`.
- `deleteFiles=true` is irreversible. `config/mediamanagement` shows `recycleBin: ""` on both apps, so there's no recycle bin. The app needs a typed confirmation, and the gateway should log who did it.
  Seerr keeps its own request record. After deleting, Seerr may still show the item as "available" until its next sync.

---

## 14. Suggested gateway endpoints (mapping summary)

| Gateway (proposal) | Upstream |
|---|---|
| `GET /arr/summary` | both: `system/status`, `health`, `queue/status`, `wanted/missing?pageSize=0`, `wanted/cutoff?pageSize=0`, `rootfolder` (parallel, cache 30 s) |
| `GET /tv` | Sonarr `series` → slim list + gateway image URLs |
| `GET /tv/{id}` | `series/{id}` + `episode?seriesId={id}&includeEpisodeFile=true` + `queue/details?seriesId={id}` |
| `GET /tv/{id}/history?page=` | `history?seriesIds={id}&includeEpisode=true` |
| `GET /tv/lookup?q=` | `series/lookup?term=` (+ `inLibrary` flag, anime suggestion, remote poster) |
| `POST /tv` | `POST series` |
| `PATCH /tv/{id}` `{monitored, qualityProfileId, seriesType}` | `GET series/{id}` → mutate → `PUT series/{id}` (or `PUT series/editor`) |
| `PATCH /tv/{id}/season/{n}` `{monitored}` | `GET series/{id}` → mutate seasons → `PUT series/{id}` |
| `PATCH /tv/episodes` `{ids, monitored}` | `PUT episode/monitor` |
| `POST /tv/{id}/search`, `/season/{n}/search`, `/episodes/search`, `/refresh` | `POST command` (SeriesSearch / SeasonSearch / EpisodeSearch / RefreshSeries) |
| `DELETE /tv/{id}?deleteFiles=` | `DELETE series/{id}` |
| `/movies…` | the same set against Radarr (`movie`, `movie/lookup`, `movie/editor`, `MoviesSearch`, `RefreshMovie`) |
| `GET /downloads/arr` | both `queue?includeSeries&includeEpisode` / `includeMovie`, merged, grouped by `downloadId` (join with the qBittorrent integration on hash) |
| `DELETE /downloads/arr/{svc}/{id}?blocklist=&search=` | `DELETE queue/{id}?removeFromClient=true&blocklist=&skipRedownload=!search` |
| `GET /calendar?from=&to=` | Sonarr `calendar?includeSeries=true` + Radarr `calendar`, merged |
| `GET /wanted/{missing,cutoff}?svc=&page=` | `wanted/*` |
| `GET /activity?page=` | both `history`, merged by `date`, `downloadUrl`/`guid` stripped |
| `GET /commands/{svc}/{id}` | `command/{id}` |
| `GET /img/{svc}/{id}/{type}?size=&v=` / `GET /img/remote?u=` | `/MediaCover/…` / allowlisted `remoteUrl` |
| `GET /arr/profiles` | `qualityprofile` (id+name only), `rootfolder` |

Live updates (optional, later; **not probed**): both apps' web UI uses SignalR at `/signalr/messages` (the UI passes `access_token=<apikey>`).
It pushes `queue`, `command`, `series`/`movie`, `episode` and `health` change events. Polling (queue/status every 15-30 s) is enough for v1.

---

## 15. Fixture index (`fixtures/arr/`)

All are real GET responses captured 2026-11-08, with original field names and nesting kept. Arrays are trimmed to ≤5 items, except
quality-profile `items` (kept whole so cutoff ids resolve; `formatItems` trimmed to 5 non-zero scores and the profile list trimmed to ids 1/7/9 Sonarr, 1/7 Radarr).
Redaction: `apikey=` in URLs → `REDACTED`. A key-by-key scan against every API key/env secret on the NAS found 0 matches.

| File | Request |
|---|---|
| `sonarr_system_status.json` / `radarr_…` | `GET system/status` |
| `sonarr_health.json` / `radarr_…` | `GET health` |
| `sonarr_diskspace.json` / `radarr_…` | `GET diskspace` |
| `sonarr_rootfolder.json` / `radarr_…` | `GET rootfolder` |
| `sonarr_tag.json` / `radarr_…` | `GET tag` (empty) |
| `sonarr_qualityprofile.json` / `radarr_…` | `GET qualityprofile` (trimmed) |
| `sonarr_languageprofile.json` | `GET languageprofile` (deprecated) |
| `sonarr_series.json` | `GET series`: ids 2 (WEB-1080p), 25 (anime on standard), 54 (seriesType anime), 61 (0 files), 140 (airing) |
| `sonarr_series_id.json` | `GET series/54?includeSeasonImages=true` |
| `sonarr_series_lookup.json` | `GET series/lookup?term=frieren` (1st in library, others not; one has no images) |
| `sonarr_series_lookup_tvdb.json` | `GET series/lookup?term=tvdb:371980` |
| `sonarr_episode.json` | `GET episode?seriesId=2` (specials first) |
| `sonarr_episode_anime.json` | `GET episode?seriesId=54`, season 3 (absolute + scene numbering) |
| `sonarr_episode_include_file.json` | `GET episode?seriesId=2&seasonNumber=1&includeEpisodeFile=true&includeImages=true` |
| `sonarr_episode_id.json` | `GET episode/76` |
| `sonarr_episodefile.json` | `GET episodefile?seriesId=2` |
| `sonarr_queue.json` / `radarr_queue.json` | `GET queue?…include…` (empty envelope) |
| `sonarr_queue_status.json` / `radarr_…` | `GET queue/status` |
| `sonarr_queue_details.json` / `radarr_…` | `GET queue/details` (empty) |
| `sonarr_wanted_missing.json` | `GET wanted/missing?includeSeries=true&sortKey=airDateUtc&sortDirection=descending` |
| `sonarr_wanted_missing_page_out_of_range.json` | `GET wanted/missing?page=1000&pageSize=50` |
| `sonarr_wanted_cutoff.json` | `GET wanted/cutoff?includeSeries=true` |
| `sonarr_history.json` | `GET history?includeSeries&includeEpisode&sortKey=date` (imports/deletes) |
| `sonarr_history_grabbed.json` | `GET history?eventType=1` (grabbed, redacted `downloadUrl`) |
| `sonarr_history_since.json` | `GET history/since?date=…&eventType=downloadFolderImported` |
| `sonarr_calendar.json` | `GET calendar?start&end&includeSeries=true` |
| `sonarr_calendar_no_series.json` | `GET calendar?…&unmonitored=true&includeSeries=false` |
| `sonarr_command.json` / `radarr_…` | `GET command` |
| `sonarr_system_task.json` / `radarr_…` | `GET system/task` |
| `sonarr_update.json` / `radarr_…` | `GET update` |
| `sonarr_parse.json` | `GET parse?title=Severance.S02E01.1080p.WEB.h264-ETHEL` |
| `sonarr_error_404.json` / `radarr_…` | `GET series/999999` / `movie/999999` |
| `sonarr_error_400_validation.json` | `GET calendar?start=garbage` |
| `radarr_error_400_validation.json` | `GET release?movieId=1x` |
| `sonarr_error_400_badrequest.json` | `GET episode` (no params) |
| `sonarr_error_503_lookup.json` | `GET series/lookup?term=` |
| `radarr_movie.json` | `GET movie`: ids 1, 8 (have files), 204, 246 (inCinemas, not available), 227 (missing) |
| `radarr_movie_id.json` | `GET movie/1` |
| `radarr_movie_lookup.json` | `GET movie/lookup?term=dune` (ids 8, 9 in library; 3 new) |
| `radarr_movie_lookup_tmdb.json` | `GET movie/lookup/tmdb?tmdbId=693134` (single object) |
| `radarr_moviefile.json` | `GET moviefile?movieId=1` |
| `radarr_movie_folder.json` | `GET movie/1/folder` |
| `radarr_wanted_missing.json` | `GET wanted/missing?monitored=true` |
| `radarr_wanted_cutoff.json` | `GET wanted/cutoff?monitored=true` (no `movieFile` in records) |
| `radarr_history.json` | `GET history?includeMovie=true&sortKey=date` |
| `radarr_history_movie.json` | `GET history/movie?movieId=1` |
| `radarr_calendar.json` | `GET calendar?start=2026-10-01…&end=2027-01-31…&unmonitored=true` |

Not captured as fixtures (they contain credentials or aren't needed): `notification`, `downloadclient`, `indexer`, `customformat`, `config/*`, `system/backup`.
