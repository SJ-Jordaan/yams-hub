# YAMS Hub gateway REST API (v1)

The complete contract between the app and the gateway. Payloads are designed for the app's screens ([APP.md](APP.md)),
not as 1:1 upstream proxies. Upstream facts come from [integrations/](integrations/); each endpoint names the upstream
calls it makes so implementers can find the details there. Architecture: [ARCHITECTURE.md](ARCHITECTURE.md).

DTO names in **bold** are the class names in `yams_models` (file in brackets). Core files: `common`, `auth`, `server`,
`dashboard`, `arr_common`. Feature files: `requests`, `library`, `activity`, `calendar`, `indexers`, `subtitles`,
`containers`, `system`, `media`.

---

## 1. Conventions

### 1.1 Base, versioning, content

- Base path `/api/v1`. All paths below are relative to it. Breaking changes go to `/api/v2`; additive changes (new
  optional fields, new endpoints, new enum values) stay in v1, so clients must ignore unknown fields and map unknown enum
  strings to `unknown`.
- Requests and responses are JSON (`application/json; charset=utf-8`) unless noted (images, 204s).
- Request bodies are limited to 1 MiB.
- `GET /ping` reports `apiVersion` and `minAppVersion`; the app refuses to run against an incompatible gateway.

### 1.2 Type notation used in this document

| Notation | Meaning |
|---|---|
| `string`, `int`, `double`, `bool` | JSON primitives (`int` is always a whole number; sizes fit in 2^53) |
| `Instant` | ISO-8601 UTC string with `Z`, e.g. `"2026-11-08T07:41:48Z"` |
| `Date` | `"YYYY-MM-DD"`, a calendar date, never time-zone converted |
| `ImagePath` | gateway-relative image path, e.g. `"/api/v1/img/tmdb/w342/abc.jpg"` (section 3) |
| `T?` | optional: omitted when null |
| `T[]` | array, never null (may be empty) |
| `"a"\|"b"` | string enum; clients map unknown values to `unknown` |
| `PagedList<T>` etc. | envelopes from section 1.5 |

### 1.3 Authentication

- `Authorization: Bearer <accessToken>` (mobile, dev web) on `/api/v1`, **or** cookie `yh_at` (web served by the
  gateway) on the identical mount **`/yh/api/v1`** (ARCHITECTURE §5.3). Cookies are ignored on `/api/v1`. All paths in
  this document are relative to either base.
- With cookie auth, **every** request must carry `X-YAMS-Client: <anything>` (CSRF guard), except `GET /img/**`; this
  includes `POST /auth/login` with `transport: "cookie"`. Otherwise `403 csrf_rejected`.
- The app always sends `X-YAMS-Client: yams-hub/<version> (<platform>)`.
- Every API response carries `Cross-Origin-Resource-Policy: same-origin` and `Cache-Control: no-store` (unless stated).
- A request whose `Host` header is not an allowed hub host gets `421` (ARCHITECTURE §5.3).
- Role tags: **[public]** no auth, **[member]** any logged-in user, **[admin]** admin only. Untagged = [member].
- **[confirm]** = the request must include `confirm=true` (query parameter, or a `"confirm": true` field in the JSON
  body). Without it: `428 confirmation_required`, nothing is changed.
- **[long]** = may take up to 150 s; the app uses a 160 s receive timeout.

### 1.4 Errors

Every error response has this body:

```json
{"error": {"code": "upstream_unavailable", "message": "Sonarr is not reachable.", "status": 503,
           "service": "sonarr", "requestId": "a1b2c3d4e5f60718",
           "fields": [{"field": "qualityProfileId", "message": "Quality profile does not exist"}],
           "details": {"upstreamStatus": 500}}}
```

**ApiError** [common]: `code: string`, `message: string` (human readable, safe to show), `status: int`,
`service: ServiceId?`, `requestId: string`, `fields: {field: string, message: string}[]` (only for validation),
`details: object?` (code-specific, documented per endpoint), `retryAfterSeconds: int?` (with 429).

| HTTP | `code` | When |
|---|---|---|
| 400 | `bad_request` | malformed JSON, missing/invalid query parameter, unknown enum value, unknown `sort` |
| 401 | `unauthorized` | no or invalid credentials |
| 401 | `token_expired` | access token expired or unknown (refresh, then retry) |
| 401 | `invalid_credentials` | login: wrong username or password |
| 401 | `refresh_invalid` | refresh token unknown, expired or reused (log in again; reuse also revokes the session) |
| 403 | `forbidden` | role too low |
| 403 | `csrf_rejected` | cookie auth without `X-YAMS-Client` (any method except image GETs) |
| 403 | `policy_denied` | blocked by gateway policy (global search, locked container, ...) |
| 403 | `seerr_user_not_linked` | member has no Seerr account mapping |
| 403 | `quota_exceeded`, `blocklisted` | Seerr refused the request |
| 404 | `not_found` | resource does not exist (also used when an upstream 500 really means "not found", e.g. Seerr TMDB lookups) |
| 409 | `conflict` | generic conflict |
| 409 | `already_exists` | add series/movie that is already in the library |
| 409 | `already_requested` | Seerr duplicate request |
| 409 | `invalid_state` | action not allowed in the current state (approve a non-pending request, ...) |
| 409 | `managed_by_arr` | raw torrent delete of a torrent that Sonarr/Radarr still tracks; `details: {service, queueIds: int[]}` |
| 409 | `job_running` | same action already running; `details.jobId` (or a concurrent search by the same user) |
| 422 | `validation_failed` | body failed validation (gateway or upstream); see `fields` |
| 428 | `confirmation_required` | [confirm] route without `confirm=true`; `details.impact: string` |
| 429 | `rate_limited` | login lockout or rate limit; `retryAfterSeconds` and `Retry-After` header |
| 500 | `internal` | gateway bug |
| 501 | `not_implemented` | stub route |
| 421 | `bad_request` | `Host` header not allowed (DNS-rebinding guard) |
| 502 | `upstream_error` | upstream returned an unexpected error; `details.upstreamStatus` |
| 502 | `upstream_auth_failed` | upstream rejected the gateway's key/credentials |
| 502 | `upstream_bad_response` | upstream body could not be parsed |
| 503 | `upstream_unavailable` | upstream not reachable |
| 503 | `service_not_configured` | the service has no URL/key in the gateway config |
| 504 | `upstream_timeout` | upstream did not answer in time |

### 1.5 Pagination, filtering, sorting

| Envelope | JSON | Used for |
|---|---|---|
| **ItemList&lt;T&gt;** [common] | `{"items": T[]}` | small unpaged lists (series, movies, indexers, containers) |
| **PagedList&lt;T&gt;** [common] | `{"items": T[], "page": int, "pageSize": int, "total": int, "hasMore": bool}` | single-source paged lists |
| **CursorPage&lt;T&gt;** [common] | `{"items": T[], "nextCursor": string?}` | merged feeds from several upstreams (activity history) |

The Dart class is `PagedList<T>` (not `Page<T>`, which clashes with Flutter's navigator `Page`); the JSON is unchanged.

- Page-based: `page` (1-based, default 1), `pageSize` (default 25, max 100 unless stated). `page` beyond the end returns
  `items: []` with the correct `total`. `hasMore = page * pageSize < total`.
- Cursor-based: `limit` (default 25, max 100), `cursor` (opaque string from `nextCursor`; absent for the first page).
  `nextCursor` is absent when there is no more data. Cursors are valid for 10 min; an expired/invalid cursor gives
  `400 bad_request` with `details.reason: "cursor"` and the client restarts.
- Sorting: `sort=<field>` and `order=asc|desc`; allowed fields are listed per endpoint. Unknown values give
  `400 bad_request` (the gateway never silently falls back like Sonarr does).
- Filtering: named query parameters per endpoint. Multi-value parameters are comma-separated (`types=episode,movie`).
- Free-text search: `q` (trimmed; empty = no filter).

### 1.6 Caching

- GET JSON responses carry a weak `ETag`; send `If-None-Match` to get `304`. Images: section 3.
- Server-side TTLs are listed per endpoint ("cache 60 s"). Every write invalidates the caches it affects, so the next GET
  after a successful write is fresh.
- Aggregates may return cached data when an upstream fails: **Section** envelopes then say `stale: true`.

**Section&lt;T&gt;** [common], used for dashboard cards and for multi-source screens:

```json
{"status": "ok", "data": { ... }, "fetchedAt": "2026-11-08T09:00:00Z", "stale": false}
{"status": "error", "error": {ApiError}, "fetchedAt": "..."}
{"status": "disabled", "error": {"code": "service_not_configured", ...}}
```

`status: "ok"|"error"|"disabled"`, `data: object?` (the feature's DTO as JSON; the Dart class `Section` keeps it as a map and `decode()`s it),
`error: ApiError?`, `fetchedAt: Instant`, `stale: bool` (true when served from cache after a failed refresh; `data`
present and `error` describes the failure).

### 1.7 Jobs and commands

**Job** [common]:

```json
{"id": "j_7f3a9c21b0d4", "kind": "containers.restart", "target": "sonarr",
 "status": "running", "progress": 0.5, "message": "Restarting sonarr",
 "steps": [{"label": "Restart sonarr", "status": "running", "startedAt": "...", "finishedAt": null}],
 "log": ["..."], "result": {}, "error": null,
 "createdAt": "...", "startedAt": "...", "finishedAt": null, "userId": "u_1a2b3c4d5e6f"}
```

`status: "queued"|"running"|"succeeded"|"failed"`, `progress: double?` (0..1), `steps: JobStep[]`
(`{label, status, startedAt?, finishedAt?}`), `log: string[]` (last 200 lines), `result: object?` (kind-specific,
documented per endpoint), `error: ApiError?`.

**CommandRef** [common] (Sonarr/Radarr commands):
`{"service": "sonarr", "id": 12345, "name": "SeriesSearch", "status": "queued"|"started"|"completed"|"failed"|"aborted"|"cancelled"|"orphaned"|"unknown", "result": "unknown"|"successful"|"unsuccessful", "message": string?, "queuedAt": Instant?, "startedAt": Instant?, "endedAt": Instant?}`.

### 1.8 Shared enums [common]

- **ServiceId**: `sonarr, radarr, prowlarr, bazarr, seerr, jellyfin, jellystat, qbittorrent, gluetun, docker, watchtower, updater, uptimeKuma, audiobookshelf, kavita, shelfmark, host, unknown`.
- **ExternalApp**: `jellyfin, audiobookshelf, kavita, seerr, shelfmark, sonarr, radarr, prowlarr, bazarr, qbittorrent, uptimeKuma, jellystat, portainer, unknown`.
  Every ExternalApp except `portainer` maps 1:1 to the ServiceId of the same name (the launcher's status source).
- **ExternalLink** [common]: `{"app": ExternalApp, "path": string}`. The app resolves the base URL (ARCHITECTURE §7.10).
  Example: `{"app": "jellyfin", "path": "/web/#/details?id=4f5731b2c357273bf4002dd8d042a856&serverId=79315eab3c4c401f8391d5c26210b6d7"}`.
- **Alert** [common]: `{"id": string (stable, e.g. "sonarr.health.IndexerLongTermStatusCheck"), "severity": "info"|"warning"|"error"|"critical", "source": ServiceId, "feature": string, "title": string, "message": string?, "route": string? (app route to open, e.g. "/indexers"), "since": Instant?, "dismissible": bool}`.
  `route` must be a route registered in APP.md §1 (built like `AppPaths`), so it also works as a web deep link
  `http://<hub>:8090<route>` (e.g. from a Discord message). Alerts are computed only when `GET /dashboard` runs; the
  hub sends no push notifications in v1 (ARCHITECTURE §1).

---

## 2. Core endpoints

### 2.1 `GET /ping` [public]

```json
{"name": "yams-hub", "version": "1.0.0", "apiVersion": 1, "minAppVersion": "1.0.0",
 "instanceId": "3f9c2a71d0e84b5c", "time": "2026-11-08T09:00:00Z"}
```
**ServerPing** [server]. `instanceId` is random, generated once and stored in `$DATA/instance.json`.
Optional query `nonce` (16..64 base64url chars) and `sid` (session id): when both are present and `sid` names a live
session, the response adds `"proof": base64url(HMAC-SHA256(serverProofKey, nonce))` (ARCHITECTURE §5.4). Otherwise
`proof` is absent and the response is otherwise identical. Invalid `nonce` → `400 bad_request`.

### 2.2 Auth

#### `POST /auth/login` [public]
Body **LoginRequest** [auth]: `{"username": string, "password": string, "deviceName": string (1..64), "platform": "android"|"ios"|"web"|"other", "transport": "token"|"cookie"}`.

200 **LoginResponse** [auth]:
```json
{"user": {User}, "session": {SessionInfo},
 "tokens": {"accessToken": "yha_...", "accessTokenExpiresAt": "...", "refreshToken": "yhr_...", "refreshTokenExpiresAt": "..."}}
```
`tokens` is omitted for `transport: "cookie"` (the cookies `yh_at`/`yh_rt` are set instead, on `/yh/api/v1` only;
`X-YAMS-Client` required). Bearer transport also returns `"serverProofKey": string` (32 random bytes base64url) at
the top level; the app stores it with the tokens.
Errors: `401 invalid_credentials` (same message for unknown user and wrong password), `403 forbidden` (user disabled,
message "Account disabled"), `429 rate_limited` (lockout, or the verification queue is full: `Retry-After: 2`).

#### `POST /auth/refresh` [public]
Body `{"refreshToken": string}` (bearer transport) or empty with the `yh_rt` cookie. 200 `{"tokens": TokenPair}` (or
cookies). Errors: `401 refresh_invalid` (unknown, expired, malformed, or **reused**: presenting a non-current refresh
token outside the 30 s grace window revokes the whole session), `429 rate_limited`.
**TokenPair** [auth]: `{accessToken, accessTokenExpiresAt: Instant, refreshToken, refreshTokenExpiresAt: Instant}`.
Refresh tokens have the form `yhr_<sessionId>.<random>`; clients treat them as opaque.

#### `POST /auth/logout`
Revokes the current session. 204. Clears cookies.

#### `GET /auth/me`
200 **MeResponse** [auth]: `{"user": User, "session": SessionInfo, "seerr": {"linked": bool, "seerrUserId": int?, "displayName": string?, "canAutoApprove": bool, "quota": SeerrQuota?}}`.
`seerr` comes from `ctx.seerrIdentity` (cache 1 h; invalidated when an admin edits the user's `jellyfinUserId`).
Admins without a link are reported as linked to Seerr user 1.
**SeerrQuota** [auth]: `{"movie": QuotaInfo, "tv": QuotaInfo}`, **QuotaInfo** `{"limit": int?, "days": int?, "used": int, "remaining": int?, "restricted": bool}`
from Seerr `GET /user/{seerrUserId}/quota` (as admin; cache 60 s, invalidated by `POST /requests`). A missing `limit`
or `limit: 0` means unlimited: `limit`/`remaining` are then omitted. Absent when unlinked or when the quota call fails.

**User** [auth]: `{"id": string, "username": string, "displayName": string, "role": "admin"|"member", "jellyfinUserId": string?, "disabled": bool, "createdAt": Instant, "updatedAt": Instant}`.
**SessionInfo** [auth]: `{"id": string, "userId": string, "deviceName": string, "platform": string, "createdAt": Instant, "lastSeenAt": Instant, "lastIp": string?, "expiresAt": Instant, "current": bool}`.

#### `POST /auth/password`
Body `{"currentPassword": string, "newPassword": string (min 10 chars)}`. 204. Revokes all other sessions of the user.
Errors: `401 invalid_credentials`, `422 validation_failed`.

#### `GET /auth/sessions`
`ItemList<SessionInfo>` of the caller's sessions. Admin: `?all=true` returns every session with `username` added
(**SessionInfo** has `username: string?`).

#### `DELETE /auth/sessions/{id}`
Revokes a session (own sessions; admins any). 204. 404 if unknown.

### 2.3 Admin

| Method + path | Role | Body / query | Response |
|---|---|---|---|
| `GET /admin/users` | admin | – | `ItemList<User>` |
| `POST /admin/users` | admin | **CreateUserRequest** `{username, displayName, password (min 10), role, jellyfinUserId?}` | 201 `User`; 409 `already_exists`; 422 |
| `PATCH /admin/users/{id}` | admin | **UpdateUserRequest** `{displayName?, role?, jellyfinUserId? (empty string clears), disabled?, password?}` | 200 `User`. An admin cannot demote or disable themselves if they are the last active admin (`409 invalid_state`). `password` revokes **all** of the target's sessions; `disabled: true` revokes all; `jellyfinUserId` invalidates the target's Seerr link. Role changes apply on the next request (role is read per request). |
| `DELETE /admin/users/{id}` | admin [confirm] | – | 204; revokes all sessions and drops their access tokens; cannot delete self (`409 invalid_state`) |
| `GET /admin/jellyfin-users` | admin | – | `ItemList<JellyfinUserOption>` |
| `POST /admin/jellyfin-users/{jellyfinUserId}/import-to-seerr` | admin | – | Upstream Seerr `POST /api/v1/user/import-from-jellyfin` `{"jellyfinUserIds": ["<id>"]}` (Seerr source `routes/user/index.js`: needs MANAGE_USERS, which the API key has; creates the user with Seerr's default permissions and avatar `/avatarproxy/<id>`; 201 with the **created** users array, empty when the user already existed). 200 `JellyfinUserOption` (re-read, `seerrUserId` now set); invalidates `ctx.seerrIdentity` users and links. `404 not_found` for an unknown Jellyfin id (`jellyfinUserId` validated `^[0-9a-f]{32}$`, dashes stripped). Audit `admin.seerr_import`. |
| `GET /admin/audit` | admin | `page`, `pageSize` (max 200), `userId`, `action` (prefix match, e.g. `library.`), `outcome=ok\|error` | `PagedList<AuditEntry>`, newest first |

**JellyfinUserOption** [auth]: `{"jellyfinUserId": string, "name": string, "isAdministrator": bool, "seerrUserId": int?, "seerrDisplayName": string?, "linkedHubUserId": string?, "avatarPath": ImagePath?}`.
Upstream: Jellyfin `GET /Users`, Seerr `GET /user?take=100` (match `jellyfinUserId`, normalised lowercase without dashes).

**AuditEntry** [auth]: `{"id": string, "at": Instant, "userId": string?, "username": string?, "sessionId": string?, "ip": string?, "action": string, "target": string?, "params": object?, "outcome": "ok"|"error", "errorCode": string?, "durationMs": int}`.

### 2.4 `GET /server`

App-wide configuration. Cache: none (built from config).
200 **ServerConfig** [server]:

```json
{"version": "1.0.0", "instanceId": "3f9c2a71d0e84b5c",
 "publicUrls": ["http://192.168.10.183:8090", "http://zenith.example.ts.net:8090"],
 "services": [{"id": "sonarr", "configured": true}, {"id": "kavita", "configured": false}],
 "externalApps": {"jellyfin": {"port": 8096, "baseUrl": null}, "audiobookshelf": {"port": 13378}, "kavita": {"port": 5000},
                  "seerr": {"port": 5055}, "shelfmark": {"port": 8084}, "sonarr": {"port": 8989}, "radarr": {"port": 7878}, "prowlarr": {"port": 9696},
                  "bazarr": {"port": 6767}, "qbittorrent": {"port": 8081}, "uptimeKuma": {"port": 3001},
                  "jellystat": {"port": 3002}, "portainer": {"port": 9000}},
 "jellyfinServerId": "79315eab3c4c401f8391d5c26210b6d7",
 "policy": {"allowGlobalSearch": false, "allowArrDeleteFiles": true,
            "lockedContainers": ["yams-hub", "socket-proxy-hub", "yams-hub-updater"],
            "confirmContainers": ["gluetun", "jellyfin", "portainer", "socket-proxy", "jellystat-db", "qbittorrent"]},
 "features": {"updater": true, "watchtowerCheck": false, "containerLogs": true, "containerActions": true},
 "seerr": {"fourKEnabled": false, "partialRequestsEnabled": true, "specialEpisodesEnabled": false}}
```

`externalApps.<app>`: `{port: int, baseUrl: string?}`. `features.watchtowerCheck` is false until Watchtower exposes
its `check`/`containers` endpoints: probed with `GET /v1/containers/details` (200 → true, 404 → false) at start-up and
every 6 h; core **never** calls `/v1/check` (only the containers feature does). `features.updater`:
`UPDATER_URL`/`UPDATER_TOKEN` set and `/healthz` answers. `features.containerLogs`: probed at start-up with
`GET /v1.54/containers/yams-hub/logs?stdout=1&tail=1` (403 → false). `features.containerActions`: false while the
docker proxy self-test fails (ARCHITECTURE §5.16). `seerr` comes from `ctx.seerrSettings` (Seerr `GET /settings/public`,
cache 1 h). `jellyfinServerId` from `ctx.jellyfin.serverId()` (Jellyfin `GET /System/Info/Public` `Id`, cache 1 h),
the same value the requests and media features use in their Jellyfin links.

### 2.5 `GET /health`

Cache 30 s. 200 **HealthReport** [server]:

```json
{"overall": "degraded", "checkedAt": "2026-11-08T09:00:00Z",
 "services": [{"id": "sonarr", "name": "Sonarr", "status": "up", "latencyMs": 4, "version": "4.0.20.3014",
               "message": null, "checkedAt": "..."},
              {"id": "kavita", "name": "Kavita", "status": "degraded", "latencyMs": 12, "version": null,
               "message": "Auth key rejected", "checkedAt": "..."}]}
```

**ServiceHealth** [server]: `id: ServiceId`, `name`, `status: "up"|"degraded"|"down"|"disabled"`, `latencyMs: int?`,
`version: string?`, `message: string?` (redacted), `checkedAt`. Includes `shelfmark` (`GET /api/health`). `overall`: `up` if all configured services are up, `down` if more
than half are down, else `degraded`. Probes: ARCHITECTURE §5.10.

### 2.6 Jobs

- `GET /jobs/{id}` → `{"job": Job}`; 404 unknown/expired. Members only see their own jobs (`403 forbidden` otherwise).
- `GET /jobs?active=true&kind=<prefix>` → `ItemList<Job>` (active = queued or running). Members only get their own
  jobs (filtered by `userId`); admins get all.

---

## 3. Images

All image routes are [member], return the image bytes with the **sniffed** content type (only `image/jpeg`,
`image/png`, `image/webp`, `image/gif`, `image/avif`; SVG and anything else → `502 upstream_bad_response`, not cached),
and are cached on disk (ARCHITECTURE §5.8). Every image response carries `Content-Security-Policy: default-src 'none';
sandbox`, `X-Content-Type-Options: nosniff` and `Cross-Origin-Resource-Policy: same-origin`. Versioned requests get
`Cache-Control: private, max-age=31536000, immutable`, others `private, max-age=86400`. Errors are JSON (`404
not_found`, `400 bad_request` for any parameter that fails validation, `502/503/504`). DTOs contain these paths
**already built** by `ImageUrls` (ARCHITECTURE §5.8); the app never assembles image paths itself.

Validation (before any upstream call): Jellyfin `itemId`/`userId` `^[0-9a-f]{32}$` (dashed GUIDs normalised), ABS
`itemId` `^[A-Za-z0-9_-]{1,64}$`, arr `id`/Kavita `seriesId`/`seerrUserId` positive ints, TMDB `file`
`^[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp)$`, enums exact. Size parameters (`fillHeight`, `fillWidth`, `maxWidth`, `w`) are
snapped up to `96|160|250|342|500|780|1280`; `quality` clamped to 60..90; `index` 0..20. Upstream URIs are built from
validated path segments, never by concatenation.

| Route | Query | Upstream |
|---|---|---|
| `GET /img/arr/{svc}/{id}/{coverType}` | `size=250\|500\|full` (default 500), `v` (lastWrite ticks or `h` hash, cache key only), `fallback` (URL-encoded remote URL used when the cover 404s; must pass the remote allow-list) | `svc` = `sonarr`\|`radarr`; `coverType` = `poster\|fanart\|banner\|clearlogo`. `http://{svc}/MediaCover/{id}/{coverType}{-size}.{jpg\|png}` with key. Sizes: poster 250/500, fanart 180/360 (`size=250`→180, `500`→360), banner 35/70 (→35/70), clearlogo full only (png). |
| `GET /img/remote` | `u` (URL-encoded https URL on the allow-list), `w` (optional width hint: for `image.tmdb.org` rewrites `/t/p/original/` to `/t/p/w{w}/` with w ∈ 185,342,500,780,1280) | internet (TVDB, TMDB, fanart.tv, TVmaze) |
| `GET /img/tmdb/{size}/{file}` | – | `https://image.tmdb.org/t/p/{size}/{file}`; `size` ∈ `w92 w154 w185 w342 w500 w780 w1280 original h632 w45`; `file` = TMDB path without the leading slash (`n8V61f1v7idya4WJzGEJNoIp9iL.jpg`) |
| `GET /img/jellyfin/{itemId}/{imageType}` | `tag` (version), `fillHeight`, `fillWidth`, `maxWidth`, `index` (backdrop index), `quality` (default 90, clamped 60..90) | `http://jellyfin:8096/Items/{itemId}/Images/{imageType}[/{index}]?...`; `imageType` ∈ `Primary Backdrop Thumb Logo` |
| `GET /img/jellyfin-user/{userId}` | `tag` | `/Users/{userId}/Images/Primary?tag=` |
| `GET /img/abs/{itemId}` | `w` (default 400), `v` (item `updatedAt`) | `http://audiobookshelf/api/items/{itemId}/cover?width={w}&format=webp` |
| `GET /img/kavita/series/{seriesId}` | `v` | `http://kavita:5000/api/Image/series-cover?seriesId={id}` with `x-api-key` header |
| `GET /img/seerr-avatar/{seerrUserId}` | `v` | Seerr user `avatar` from `ctx.seerrIdentity.users()`: a path starting with `/` (not `//`) is resolved against `SEERR_URL` and must keep its host/port (e.g. `/avatarproxy/<jellyfinId>`); an absolute `https://` URL goes through the remote allow-list (`www.gravatar.com`); anything else → 404 |

Arr `v` values come from the `url` field of the *arr image (`lastWrite=` for Sonarr, `h=` for Radarr). Search/lookup
results use `/img/remote` (never `/MediaCoverProxy`).

---

## 4. Dashboard

### `GET /dashboard`

Query: `cards` (optional comma list of card keys; default all). Card budget 4 s each (ARCHITECTURE §5.11).
200 **DashboardResponse** [dashboard]:

```json
{"generatedAt": "2026-11-08T09:00:00Z",
 "alerts": [Alert],
 "cards": {"system": Section, "activity": Section, "media": Section, "calendar": Section, "requests": Section,
           "library": Section, "containers": Section, "indexers": Section, "subtitles": Section}}
```

Card keys and their `data` DTOs (defined in the feature files): `system` → **SystemCard** (§13.4), `activity` →
**ActivityCard** (§8.9), `media` → **MediaCard** (§14.8), `calendar` → **CalendarCard** (§9.2), `requests` →
**RequestsCard** (§6.9), `library` → **LibraryCard** (§7.11), `containers` → **ContainersCard** (§11.8), `indexers` →
**IndexersCard** (§10.6), `subtitles` → **SubtitlesCard** (§12.6). A card that is not implemented yet (its stub's
`dashboard()` throws `ApiException.notImplemented()`) returns `status: "error"` with `code: "not_implemented"`. Each
card's server cache is listed in its section.

**Raw-key contract for core.** The app's shell badges and the More screen read these keys straight from
`cards.<key>.data` without the feature DTO classes (ARCHITECTURE §7.2). Features must keep them (types as shown;
absent → no badge):

| Key path | Type | Used for |
|---|---|---|
| `cards.requests.data.counts.pending` | int | Requests badge (admins) |
| `cards.activity.data.counts.attention` | int | Activity badge |
| `cards.calendar.data.countNext7Days` | int | More: "6 episodes this week" |
| `cards.containers.data.running` / `.total` | int | More: "21 running" |
| `cards.indexers.data.failing` | array (length used) | More: "1 failing" |
| `cards.subtitles.data.missingEpisodes` | int | More: "111 missing" |

---

## 5. Shared *arr DTOs [arr_common]

- **ArrService**: `sonarr`, `radarr`, `unknown`.
- **QualityInfo**: `{"name": string ("WEBDL-1080p"), "source": string?, "resolution": int?, "modifier": string?, "revision": int? (only when > 1), "isRepack": bool}`.
- **MediaFileInfo**: `{"id": int, "relativePath": string, "sizeBytes": int, "dateAdded": Instant?, "quality": QualityInfo, "customFormats": string[], "customFormatScore": int, "cutoffNotMet": bool, "releaseGroup": string?, "edition": string?, "languages": string[], "videoCodec": string?, "videoDynamicRange": string? ("HDR10"), "resolution": string? ("1920x1080"), "audioCodec": string?, "audioChannels": double?, "audioLanguages": string[], "subtitleLanguages": string[], "runTime": string? ("41:55")}`.
  `path` (absolute container path) is **not** included.
- **HealthMessage**: `{"service": ServiceId, "source": string, "type": "ok"|"notice"|"warning"|"error", "message": string, "wikiUrl": string?}`.
- **ArrHistoryType**: `grabbed, imported, failed, deleted, renamed, ignored, unknown`. Upstream integer mapping (filters):

| ArrHistoryType | Sonarr eventType ints | Radarr eventType ints |
|---|---|---|
| grabbed | 1 | 1 |
| imported | 2, 3 | 3, 7 |
| failed | 4 | 4 |
| deleted | 5 | 6 |
| renamed | 6 | 8 |
| ignored | 7 | 9 |

- **ArrHistoryItem**:
```json
{"id": "sonarr:98123", "service": "sonarr", "type": "imported", "date": "2026-11-08T06:12:00Z",
 "sourceTitle": "Show.S01E02.1080p.WEB.h264-GRP", "mediaTitle": "Show", "seriesId": 2, "movieId": null,
 "episode": {"id": 76, "seasonNumber": 1, "episodeNumber": 2, "absoluteEpisodeNumber": null, "title": "Pilot", "label": "S01E02"},
 "quality": QualityInfo, "customFormatScore": 202, "indexer": "Nyaa.si (Prowlarr)", "releaseGroup": "GRP",
 "sizeBytes": 1496206957, "downloadClient": "qBittorrent", "releaseSource": "rss", "reason": null,
 "downloadId": "e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e", "posterPath": ImagePath?}
```
`episode: {id, seasonNumber, episodeNumber, absoluteEpisodeNumber?, title?, label}` (Sonarr only; `label` follows the
anime rule `S03E01 (049)`), `releaseSource: "rss"|"search"|"interactiveSearch"|"unknown"?` (grabbed only),
`reason: string?` (deleted: `ManualOverride`, `Upgrade`, ...), `downloadId` lower-cased. Built from `data` strings
(parse numbers defensively). `downloadUrl`, `guid`, `nzbInfoUrl`, paths are **never** included.

---

## 6. Requests (Seerr) — feature `requests`

Routes: `/discover/**`, `/search`, `/titles/**`, `/requests/**`, `/issues/**`.

**Seerr identity rule.** Calls made "as the user" send `X-API-User: <seerrUserId>` for members. The link comes from
`ctx.seerrIdentity.forUser(user)` (core; `jellyfinUserId` → `GET /user/jellyfin/{id}`, cache 1 h, invalidated when an
admin edits the user), the same resolver `/auth/me` uses, so the two never disagree. Admins send no `X-API-User`
(Seerr admin, auto-approve). Members without a link get `403 seerr_user_not_linked` on create/list-mine.
Discover (except the watchlist), search and details are **not** per-user and are fetched as admin (no header) for
everyone; their caches are shared. The **watchlist is per user** and follows the identity rule (§6.2). Never forward Seerr `email`, `mediaUrl`, `serviceUrl`. Seerr query strings are encoded by
hand (integrations/seerr.md §1.2): `Uri.encodeComponent` then `! ' ( ) *` → `%21 %27 %28 %29 %2A`, passed as `rawQuery`.

### 6.1 Shared DTOs [requests]

- **MediaType**: `movie`, `tv`, `unknown`.
- **Availability** (Seerr MediaStatus): `none` (1 or no mediaInfo), `pending` (2), `processing` (3), `partial` (4),
  `available` (5), `blocklisted` (6), `deleted` (7), `unknown`.
- **RequestStatus** (MediaRequestStatus): `pending` (1), `approved` (2), `declined` (3), `failed` (4), `completed` (5), `unknown`.
- **TitleCard**:
```json
{"mediaType": "movie", "tmdbId": 438631, "title": "Dune", "year": 2021, "releaseDate": "2021-09-15",
 "overview": "...", "posterPath": "/api/v1/img/tmdb/w342/v1tRXZ4JtD2Iv6fjkPvT4GiwslV.jpg",
 "backdropPath": "/api/v1/img/tmdb/w780/....jpg", "voteAverage": 7.8, "availability": "available", "requested": false}
```
`year` from `releaseDate`/`firstAirDate` (empty string → null), `title` from `title` or `name`, `availability` from
`mediaInfo?.status ?? 1`, `requested`: true when `mediaInfo.status` is 2 or 3.
- **RequestSummary**:
```json
{"id": 196, "status": "completed", "mediaType": "tv", "tmdbId": 33880, "title": "The Legend of Korra", "year": 2012,
 "posterPath": ImagePath?, "seasons": [{"seasonNumber": 1, "status": "completed"}],
 "availability": "available", "requestedBy": {"id": 1, "displayName": "Paul Greyrat", "avatarPath": ImagePath?},
 "modifiedBy": {...}?, "createdAt": Instant, "updatedAt": Instant, "profileName": string?,
 "downloads": [{"title": string, "progress": double, "etaSeconds": int?, "status": string}],
 "jellyfin": ExternalLink?, "seerrMediaId": int?, "libraryId": int?,
 "canApprove": bool, "canDecline": bool, "canRetry": bool, "canDelete": bool}
```
`seerrMediaId` = `media.id`; `libraryId` = `media.externalServiceId` (Sonarr series id for tv, Radarr movie id for
movies; absent until the *arr has the item). The app opens `AppPaths.seriesDetail(libraryId)` or
`AppPaths.movieDetail(libraryId)` from `mediaType` + `libraryId`. `downloads` entries are **RequestDownloadProgress**
(the name `DownloadProgress` is reserved).
Title/year/poster come from the gateway's joined detail cache (key `type:tmdbId`, TTL 24 h, LRU 500). `canApprove`
/`canDecline`: caller is admin and status pending. `canRetry`: admin and status failed. `canDelete`: admin, or owner
and pending. `downloads` from `media.downloadStatus` (`progress = 1 - sizeLeft/size`). `jellyfin`: built from
`media.jellyfinMediaId` with `ctx.jellyfin.itemLink(id, serverId)`.

### 6.2 Discover and search

| Method + path | Query | Upstream | Cache |
|---|---|---|---|
| `GET /discover/{slider}` | `page` (1..500), `mediaType` (trending only: `all\|movie\|tv`), `timeWindow` (trending only: `day\|week`), `genre` (popular-* only, TMDB genre id) | `slider` → `trending`: `/discover/trending`; `popular-movies`: `/discover/movies`; `popular-tv`: `/discover/tv`; `upcoming-movies`: `/discover/movies/upcoming`; `upcoming-tv`: `/discover/tv/upcoming` | 10 min (shared) |
| `GET /discover/watchlist` | `page` | **per user**: as admin `GET /user/{seerrUserId}/watchlist?page=` where `seerrUserId` is the caller's link (admins: their link, else Seerr user 1). Unlinked members get **200 with an empty TitlePage** (`page: 1, totalPages: 0, totalResults: 0, items: []`), not 403, so the carousel just hides. | 10 min, **keyed by `seerrUserId`** |
| `GET /search` | `q` (required, 1..100 chars), `page` (1..500) | `/search?query=&page=`; `person` results dropped | 5 min |
| `GET /discover/genres` | `mediaType=movie\|tv` | `/genres/movie\|tv` | 24 h |

Discover/search response **TitlePage** [requests]: `{"page": int, "totalPages": int (clamped to 500), "totalResults": int, "items": TitleCard[]}`.
Unknown slider → `400 bad_request`. Genres: `ItemList<{id: int, name: string}>` (**Genre**). Watchlist items are mapped
to TitleCard (fields not available are omitted).

### 6.3 Title details

#### `GET /titles/movie/{tmdbId}` (cache 6 h for TMDB fields; `media` part 30 s)
200 **MovieTitle**:
```json
{"tmdbId": 818, "imdbId": "tt0295178", "title": "Austin Powers in Goldmember", "originalTitle": "...", "tagline": "...",
 "overview": "...", "releaseDate": "2002-07-26", "year": 2002, "runtimeMinutes": 94, "genres": ["Comedy"],
 "certification": "PG-13", "voteAverage": 6.2, "voteCount": 4321, "posterPath": ImagePath, "backdropPath": ImagePath?,
 "trailer": {"youtubeKey": "abc123", "name": "Official Trailer"},
 "cast": [{"name": "Mike Myers", "character": "Austin Powers", "profilePath": ImagePath?}],
 "directors": ["Jay Roach"], "collection": {"tmdbId": 1006, "name": "Austin Powers Collection"},
 "watchProviders": [{"name": "Netflix", "logoPath": ImagePath?, "type": "flatrate"|"rent"|"buy"}],
 "media": MediaState?, "request": RequestEligibility}
```
`cast`: top 12 by `order`. `certification`: first non-empty from `releases` for `ZA`, else `US`. `watchProviders`:
region `ZA`. `trailer`: first YouTube `Trailer` from `relatedVideos`.

**MediaState** (null when `mediaInfo` is null):
`{"seerrMediaId": int, "availability": Availability, "requests": RequestSummary[], "downloads": {title, progress, etaSeconds?, status}[], "jellyfin": ExternalLink?, "libraryId": int? (Radarr movie id or Sonarr series id = externalServiceId), "openIssues": int}`.

**RequestEligibility**: `{"canRequest": bool, "reason": "available"|"alreadyRequested"|"blocklisted"|"notLinked"|null, "requestableSeasons": int[]}` (`requestableSeasons` tv only).

#### `GET /titles/tv/{tmdbId}` (same caching)
200 **TvTitle**: the MovieTitle fields that apply (`tmdbId, imdbId?, title, originalTitle, tagline?, overview, year, genres, certification?, voteAverage, voteCount, posterPath, backdropPath?, trailer?, cast, watchProviders, media, request`) plus:
`firstAirDate: Date?`, `lastAirDate: Date?`, `status: string` ("Returning Series"), `networks: string[]`, `creators: string[]`,
`episodeRuntimeMinutes: int?`, `numberOfSeasons: int`, `numberOfEpisodes: int`, `tvdbId: int?`,
`nextEpisode: {seasonNumber, episodeNumber, name?, airDate?}?`, `seasons: TvSeason[]`.

**TvSeason**: `{"seasonNumber": int, "name": string, "episodeCount": int, "airDate": Date?, "posterPath": ImagePath?, "availability": Availability, "requestStatus": RequestStatus?, "requestable": bool}`.
Season list = TMDB seasons with `seasonNumber > 0 && episodeCount > 0` (specials disabled). `availability` from
`mediaInfo.seasons` (missing → `none`). `requestable` follows the server rule (integrations/seerr.md §1.7): not
requestable if availability ∉ {none, deleted} or the season is in a request whose status ∉ {declined, completed}.

#### Other title routes
| Method + path | Response | Upstream / cache |
|---|---|---|
| `GET /titles/{mediaType}/{tmdbId}/ratings` | **Ratings** `{rottenTomatoes: {criticsScore: int?, audienceScore: int?, criticsRating: string?, url: string?}?, imdb: {score: double?, url: string?}?}` | movie: `/movie/{id}/ratingscombined`; tv: `/tv/{id}/ratings` (RT only). Cache 24 h. [long-ish: 1–2 s] |
| `GET /titles/{mediaType}/{tmdbId}/recommendations` | `TitlePage` (`page`) | `/movie\|tv/{id}/recommendations`, 6 h |
| `GET /titles/{mediaType}/{tmdbId}/similar` | `TitlePage` | `/similar`, 6 h |
| `GET /titles/tv/{tmdbId}/seasons/{n}` | **SeasonEpisodes** `{seasonNumber, name, overview?, episodes: [{episodeNumber, name, airDate: Date?, overview?, stillPath: ImagePath?}]}` | `/tv/{id}/season/{n}`, 6 h |

Unknown TMDB id: Seerr answers 500 "Unable to retrieve ..." → gateway returns `404 not_found`.

### 6.4 Create a request — `POST /requests`
Body **CreateRequest**:
```json
{"mediaType": "tv", "tmdbId": 10545, "seasons": [4, 5], "advanced": {"serverId": 0, "profileId": 9, "rootFolder": "/data/tvshows"}}
```
`seasons`: `int[]` or the string `"all"` (tv only, required for tv). `advanced` admin only (`403 forbidden` otherwise);
omitted fields keep Seerr defaults. Never send `is4k: true` or `tags`.
Upstream: Seerr `POST /request` `{mediaType, mediaId: tmdbId, seasons, serverId?, profileId?, rootFolder?}` with the identity rule. Timeout 30 s.

| Upstream result | Gateway response |
|---|---|
| 201 | 201 **CreateRequestResult** `{"outcome": "created"\|"autoApproved", "request": RequestSummary}` (`autoApproved` when the returned status is approved) |
| 202 "No seasons available to request" | 200 `{"outcome": "nothingToRequest"}` |
| 409 | `409 already_requested` |
| 403 quota / blocklist / permission | `403 quota_exceeded` / `403 blocklisted` / `403 forbidden` (message from Seerr) |

Invalidates title and request caches for that title and the caller's quota cache. Audit `requests.create`.
On `403 quota_exceeded` the `details` include `{"quota": SeerrQuota}` when it could be read, so the sheet can say
"You have used 5 of 5 movie requests this week".

### 6.5 List and manage requests

#### `GET /requests`
Query: `filter=all|pending|approved|processing|available|failed|declined|completed` (default `all`), `mine=true|false`
(default false; members are always `mine=true`, forced),
`mediaType=all|movie|tv`, `sort=added|modified` (default `added`), `order=desc|asc`, `page`, `pageSize` (max 50).
Upstream `/request?take&skip&filter&sort&sortDirection&mediaType[&requestedBy]` (as the user for members). Cache 15 s.
200 `PagedList<RequestSummary>`.
**`declined`** has no Seerr filter: the gateway fetches `/request?filter=all&take=500&skip=0` with the same
sort/mediaType/requestedBy (one call, live-tested size in seerr.md §1.9), caches that list 15 s per (caller identity,
sort, mediaType), keeps status 3, and pages it itself, so `total`/`hasMore` are exact.

#### `GET /requests/counts` (cache 15 s)
**RequestCounts**: `{"total": int, "movie": int, "tv": int, "pending": int, "approved": int, "processing": int, "available": int, "declined": int, "completed": int, "failed": int}` (`failed = total - pending - approved - declined - completed`, floored at 0).

#### `GET /requests/{id}` → `RequestSummary`. 404 / 403 as Seerr.

| Method + path | Role | Upstream | Response / errors |
|---|---|---|---|
| `POST /requests/{id}/approve` | admin | `POST /request/{id}/approve` | 200 `RequestSummary`; 409 `invalid_state` when not pending |
| `POST /requests/{id}/decline` | admin | `POST /request/{id}/decline` | same |
| `POST /requests/{id}/retry` | admin | `POST /request/{id}/retry` | 200; 409 `invalid_state` when not failed |
| `PUT /requests/{id}` | owner (pending) or admin | body `{seasons?: int[], advanced?}` → `PUT /request/{id}` `{mediaType, seasons, ...}` | 200 `RequestSummary`; 200 `{"outcome":"nothingToRequest"}` on upstream 202; 409 `invalid_state` |
| `DELETE /requests/{id}` | owner (pending) or admin [confirm] | `DELETE /request/{id}` | 204 (only removes the request record; files untouched). Upstream 401 → `403 forbidden` |

#### `GET /requests/options` [admin] (cache 10 min)
**RequestOptions**: `{"radarr": ServiceOptions[], "sonarr": ServiceOptions[]}` where **ServiceOptions** =
`{"serverId": int, "name": string, "isDefault": bool, "defaultProfileId": int, "defaultAnimeProfileId": int?, "defaultRootFolder": string, "profiles": [{id, name}], "rootFolders": [{path, freeBytes}]}`.
Upstream `/service/radarr`, `/service/sonarr`, `/service/{type}/{id}`. Remember `serverId` 0 is valid.

### 6.6 Issues

- **IssueType**: `video` (1), `audio` (2), `subtitles` (3), `other` (4), `unknown`. **IssueStatus**: `open` (1), `resolved` (2), `unknown`.
- **Issue**: `{"id": int, "type": IssueType, "status": IssueStatus, "mediaType": MediaType, "tmdbId": int, "title": string, "posterPath": ImagePath?, "season": int? (0 → null), "episode": int?, "createdBy": IssueUser, "createdAt": Instant, "updatedAt": Instant, "commentCount": int, "comments": IssueComment[]}`
  with **IssueUser** `{id, displayName, avatarPath?}` and **IssueComment** `{"id": int, "message": string, "author": IssueUser, "createdAt": Instant}`.
  `commentCount` = `comments.length` upstream (Seerr includes comments in list rows); it is present in lists too, where
  `comments` is `[]`.

| Method + path | Body / query | Upstream | Response |
|---|---|---|---|
| `GET /issues` | `filter=open\|resolved\|all` (default open; always sent explicitly upstream), `page`, `pageSize` (max 50) | `/issue?take&skip&filter&sort=added` (as user) | `PagedList<Issue>` (comments omitted in lists) |
| `GET /issues/counts` | – | `/issue/count` | **IssueCounts** `{total, video, audio, subtitles, other, open, resolved}`. Mapping from Seerr: `others → other`, `closed → resolved`, the rest by name. |
| `GET /issues/{id}` | – | `/issue/{id}` (as user) | `Issue` |
| `POST /issues` | **CreateIssue** `{mediaType, tmdbId, type: IssueType, message (1..2000), season?, episode?}` | resolve `mediaInfo.id` via `/movie\|tv/{tmdbId}`; `POST /issue {issueType, message, mediaId, problemSeason, problemEpisode}` (as user) | 201 `Issue`; 404 `not_found` with message "Seerr does not track this title yet" when `mediaInfo` is null |
| `POST /issues/{id}/comments` | `{message}` (1..2000) | `POST /issue/{id}/comment` **as user** (identity rule) | 200 `Issue` |
| `POST /issues/{id}/resolve` / `/reopen` | – | `POST /issue/{id}/resolved` / `/open` **as user** (identity rule). Seerr enforces "creator or MANAGE_ISSUES"; upstream 403 → `403 forbidden`. | 200 `Issue` |

All issue routes are [member]; unlinked members get `403 seerr_user_not_linked` on create/comment/resolve/reopen.

### 6.7 Errors specific to Seerr
Seerr 400 "must be url encoded" should never happen (gateway encodes); if it does → `502 upstream_error`. Seerr 403 with
`{error}` body on a bad key → `502 upstream_auth_failed`.

### 6.8 Role summary
Members: discover, search, titles, create (as themselves), list mine, delete own pending, issues (create/comment, see
own). Admin: everything.

### 6.9 Dashboard card `requests` — **RequestsCard** (cache 30 s)
`{"counts": RequestCounts, "pending": RequestSummary[] (max 5, admin only, else empty), "recent": RequestSummary[] (latest 5; members: their own), "openIssues": int}`.
Alerts: `seerr.pending` (info, admin, "N requests waiting for approval", route `/requests/list?tab=pending`) when
pending > 0; `seerr.failed` (warning, admin, route `/requests/list?tab=failed`) when failed > 0.

---

## 7. Library (Sonarr + Radarr) — feature `library`

Routes: `/library/**`. Reads [member]; all writes [admin]. Commands return 202 with a **CommandRef**; the app polls
`GET /library/commands/{service}/{id}` every 2 s until a terminal status (max 2 min).

### 7.1 DTOs [library]

**SeriesSummary**:
```json
{"id": 54, "title": "That Time I Got Reincarnated as a Slime", "sortTitle": "...", "year": 2018,
 "status": "continuing", "seriesType": "anime", "isAnime": true, "monitored": true, "monitorNewItems": "all",
 "network": "Tokyo MX", "qualityProfileId": 7, "qualityProfileName": "[Anime] Remux-1080p",
 "posterPath": "/api/v1/img/arr/sonarr/54/poster?size=250&v=639058149420070772",
 "fanartPath": "/api/v1/img/arr/sonarr/54/fanart?size=500&v=...", "nextAiring": Instant?, "previousAiring": Instant?,
 "seasonCount": 3, "episodeCount": 110, "episodeFileCount": 62, "missingCount": 48, "totalEpisodeCount": 120,
 "sizeOnDiskBytes": 123456789012, "percentComplete": 56.4, "added": Instant, "genres": ["Anime", "Animation"],
 "tvdbId": 336297, "tmdbId": 82684, "imdbId": "tt9054364", "ratingValue": 8.1, "ratingVotes": 1234,
 "tags": ["anime"]}
```
`status: "continuing"|"ended"|"upcoming"|"deleted"|"unknown"`, `seriesType: "standard"|"daily"|"anime"`,
`isAnime`: `seriesType == anime || genres contains "Anime"`, `missingCount = episodeCount - episodeFileCount` (≥ 0).
Fields absent upstream (e.g. `nextAiring`) are omitted. `tags`: labels of the series' tag ids, resolved through Sonarr
`GET /api/v3/tag` (cached 10 min, fixture `sonarr_tag.json`); unknown ids are dropped. Same for MovieSummary with Radarr
`GET /api/v3/tag` (`radarr_tag.json`). Tags are read-only in the hub.

**MovieSummary**:
```json
{"id": 1, "title": "Zootopia 2", "sortTitle": "...", "year": 2025, "status": "released", "monitored": true,
 "hasFile": true, "isAvailable": true, "minimumAvailability": "released", "qualityProfileId": 7,
 "qualityProfileName": "HD Bluray + WEB", "posterPath": ImagePath?, "fanartPath": ImagePath?,
 "inCinemasDate": "2025-11-26", "digitalReleaseDate": "2026-01-20", "physicalReleaseDate": null, "releaseDate": "2026-01-20",
 "runtimeMinutes": 108, "sizeOnDiskBytes": 4567890123, "quality": "Bluray-1080p", "cutoffNotMet": false,
 "added": Instant, "genres": [], "tmdbId": 1084242, "imdbId": "tt...", "studio": string?, "certification": string?,
 "ratingImdb": 7.9, "ratingTmdb": 7.6, "collection": "Zootopia Collection", "tags": []}
```
`status: "tba"|"announced"|"inCinemas"|"released"|"deleted"|"unknown"`. Radarr release instants become `Date`s
(take the date part, no TZ conversion). `quality`/`cutoffNotMet` from `movieFile` when present. `hasFile` = `movieFileId > 0`.

**Episode**:
```json
{"id": 5580, "seasonNumber": 3, "episodeNumber": 1, "absoluteEpisodeNumber": 49, "label": "S03E01 (049)",
 "title": "...", "overview": string?, "airDate": "2024-04-05", "airDateUtc": Instant?, "runtimeMinutes": 24,
 "monitored": true, "hasFile": true, "finaleType": "season"?, "lastSearchTime": Instant?,
 "file": MediaFileInfo?, "queue": EpisodeQueueState?}
```
`label`: `S{ss}E{ee}`, plus ` ({abs, 3 digits})` when the series is anime and `absoluteEpisodeNumber` is present.
**EpisodeQueueState**: `{"status": string, "trackedState": string, "progress": double, "etaSeconds": int?}`.

**SeasonInfo**: `{"seasonNumber": int, "monitored": bool, "episodeCount": int, "episodeFileCount": int, "totalEpisodeCount": int, "sizeOnDiskBytes": int, "nextAiring": Instant?, "previousAiring": Instant?, "posterPath": ImagePath?}`.

### 7.2 TV

#### `GET /library/tv` (cache 60 s; upstream `GET /api/v3/series` with gzip + `qualityprofile` cache)
Query: `q` (title contains, case/diacritics-insensitive), `filter=all|monitored|unmonitored|missing|continuing|ended|anime|upcoming`
(default all), `sort=title|added|nextAiring|sizeOnDisk|missing|year` (default title), `order`.
200 `ItemList<SeriesSummary>` (unpaged, 71 items). Filtering/sorting happens in the gateway.

#### `GET /library/tv/{id}` (cache 30 s)
Upstream: `series/{id}?includeSeasonImages=true`, `episode?seriesId={id}&includeEpisodeFile=true`, `queue/details?seriesId={id}` (parallel).
200 **SeriesDetail**:
```json
{"series": SeriesSummary, "overview": "...", "airTime": "22:00", "runtimeMinutes": 24, "certification": "TV-14",
 "rootFolderPath": "/data/tvshows", "seasonFolder": true, "originalLanguage": "Japanese",
 "alternateTitles": ["..."], "bannerPath": ImagePath?, "seasons": SeasonInfo[], "episodes": Episode[],
 "links": {"tvdb": "https://thetvdb.com/?tab=series&id=336297", "imdb": "https://www.imdb.com/title/tt9054364/"}}
```
`seasons` sorted ascending with season 0 last; `episodes` sorted by season then episode. `path` is not exposed.
404 when Sonarr 404s.

#### `GET /library/tv/{id}/history`
Query `page`, `pageSize` (max 50). Upstream `history?seriesIds={id}&includeEpisode=true&sortKey=date&sortDirection=descending`.
200 `PagedList<ArrHistoryItem>`.

#### `GET /library/tv/lookup` (cache 10 min per term)
Query `term` (required; `tvdb:123` / `imdb:tt...` pass through). Empty term → `400 bad_request` (do not call upstream: it 503s).
Upstream `series/lookup?term=`. Timeout 20 s.
200 `ItemList<SeriesLookup>`, **SeriesLookup**:
`{"tvdbId": int, "title": string, "year": int?, "overview": string?, "network": string?, "status": string, "genres": string[], "runtimeMinutes": int?, "seasonNumbers": int[], "posterPath": ImagePath? (via /img/remote from remotePoster or poster remoteUrl), "ratingValue": double?, "originalLanguage": string?, "isAnime": bool, "inLibrary": bool, "libraryId": int?, "suggested": {"seriesType": "anime"|"standard", "qualityProfileId": int, "rootFolderPath": string}}`.
`inLibrary` = upstream object has `id`. Suggestion: anime → (`anime`, profile 7), else (`standard`, profile 9), root
folder from the default root folder (§7.6).

#### `POST /library/tv` [admin]
Body **AddSeriesRequest**:
`{"tvdbId": int, "qualityProfileId": int, "rootFolderPath": string, "seriesType": "standard"|"anime"|"daily", "seasonFolder": bool (default true), "monitor": "all"|"future"|"missing"|"existing"|"firstSeason"|"latestSeason"|"pilot"|"none", "monitorNewItems": "all"|"none" (default all), "searchForMissing": bool, "searchForCutoffUnmet": bool (default false)}`.
Gateway: `series/lookup?term=tvdb:{tvdbId}` → take the first result → override the fields → `POST series` with
`addOptions {monitor, searchForMissingEpisodes, searchForCutoffUnmetEpisodes, ignoreEpisodesWithFiles: false, ignoreEpisodesWithoutFiles: false}`.
201 `SeriesSummary`. Errors: upstream 400 "already been added" → `409 already_exists` with `details.libraryId`;
other validation → `422`. Invalidates the series list. Audit `library.tv.add`.

#### `PATCH /library/tv/{id}` [admin]
Body `{"monitored": bool?, "qualityProfileId": int?, "seriesType": string?, "monitorNewItems": string?}` (at least one).
Upstream `PUT series/editor {seriesIds: [id], ...}`. 200 `SeriesSummary` (re-read). Audit `library.tv.edit`.

#### `PATCH /library/tv/{id}/seasons/{seasonNumber}` [admin]
Body `{"monitored": bool}`. Upstream: `GET series/{id}` → set `seasons[n].monitored` → `PUT series/{id}` with the full
object (episodes follow the season). 200 `SeasonInfo`. 404 unknown season.

#### `PATCH /library/tv/episodes` [admin]
Body `{"episodeIds": int[] (1..500), "monitored": bool}`. Upstream `PUT episode/monitor`. 200 `{"items": [{"id": int, "monitored": bool}]}`.

#### `POST /library/tv/{id}/search` [admin]
Body `{"scope": "series"|"season"|"episodes"|"missing", "seasonNumber": int? (season), "episodeIds": int[]? (episodes)}`.
Upstream `POST command`: `SeriesSearch{seriesId}`, `SeasonSearch{seriesId, seasonNumber}`, `EpisodeSearch{episodeIds}`,
`MissingEpisodeSearch{seriesId, monitored: true}`. 202 `{"command": CommandRef}`. A debounce in the gateway returns the
same command for an identical body within 30 s (Sonarr also dedupes). Audit `library.tv.search`.

#### `POST /library/tv/{id}/refresh` [admin]
`RefreshSeries{seriesIds: [id]}`. 202 `{"command": CommandRef}`.

#### `DELETE /library/tv/{id}` [admin] [confirm]
Query `deleteFiles=true|false` (default false), `addExclusion=true|false` (default false). With `deleteFiles=true` and
`policy.allowArrDeleteFiles=false` → `403 policy_denied`. Upstream `DELETE series/{id}?deleteFiles&addImportListExclusion`.
204. `details.impact` on 428: `"Removes 'Slime' from Sonarr and permanently deletes 62 files (123.4 GB)"`.

### 7.3 Movies

| Method + path | Role | Query / body | Upstream | Response |
|---|---|---|---|---|
| `GET /library/movies` | member | `q`, `filter=all\|monitored\|unmonitored\|missing\|available\|unreleased\|cutoffUnmet`, `sort=title\|added\|releaseDate\|sizeOnDisk\|year`, `order` | `movie` (1.47 MB → gzip, slimmed), cache 60 s | `ItemList<MovieSummary>` |
| `GET /library/movies/{id}` | member | – | `movie/{id}`, `moviefile?movieId=`, `queue/details?movieId=` | **MovieDetail** `{movie: MovieSummary, overview, files: MediaFileInfo[], queue: EpisodeQueueState?, alternateTitles: string[], youTubeTrailerId: string?, links: {tmdb, imdb?}}` |
| `GET /library/movies/{id}/history` | member | `page`, `pageSize` | `history?movieIds={id}&includeMovie=false` | `PagedList<ArrHistoryItem>` |
| `GET /library/movies/lookup` | member | `term` | `movie/lookup?term=` (`tmdb:`/`imdb:` pass through), cache 10 min | `ItemList<MovieLookup>` |
| `POST /library/movies` | admin | **AddMovieRequest** `{tmdbId, qualityProfileId, rootFolderPath, minimumAvailability: "announced"\|"inCinemas"\|"released" (default released), monitor: "movieOnly"\|"movieAndCollection"\|"none", searchForMovie: bool}` | `movie/lookup/tmdb?tmdbId=` → override → `POST movie` with `addOptions {monitor, searchForMovie, addMethod: "manual"}`; always send `minimumAvailability` and `monitored = monitor != none` | 201 `MovieSummary`; 409 `already_exists` |
| `PATCH /library/movies/{id}` | admin | `{monitored?, qualityProfileId?, minimumAvailability?}` | `PUT movie/editor {movieIds: [id], ...}` | 200 `MovieSummary` |
| `POST /library/movies/{id}/search` | admin | – | `MoviesSearch{movieIds:[id]}` | 202 `{command}` |
| `POST /library/movies/{id}/refresh` | admin | – | `RefreshMovie{movieIds:[id]}` | 202 `{command}` |
| `DELETE /library/movies/{id}` | admin [confirm] | `deleteFiles`, `addExclusion` | `DELETE movie/{id}?deleteFiles&addImportExclusion` (note the Radarr name) | 204 |

**MovieLookup**: `{"tmdbId": int, "imdbId": string?, "title": string, "year": int?, "overview": string?, "status": string, "runtimeMinutes": int?, "genres": string[], "posterPath": ImagePath?, "ratingTmdb": double?, "inLibrary": bool, "libraryId": int?, "hasFile": bool (movieFileId > 0), "suggested": {"qualityProfileId": int, "rootFolderPath": string, "minimumAvailability": "released"}}`.

Filters: `missing` = monitored && !hasFile && isAvailable; `unreleased` = !isAvailable; `available` = hasFile;
`cutoffUnmet` = hasFile && cutoffNotMet.

### 7.4 Wanted

#### `GET /library/wanted/{kind}` with `kind = missing|cutoff`
Query: `service=sonarr|radarr` (required), `page`, `pageSize` (max 50), `sort` (sonarr: `airDate|title|lastSearched`,
default airDate desc; radarr: `title|year`, default title asc).
Upstream `wanted/{kind}?page&pageSize&monitored=true&includeSeries=true&sortKey&sortDirection` (sort keys:
sonarr `episodes.airDateUtc`, `series.sortTitle`, `episodes.lastSearchTime`; radarr `movieMetadata.sortTitle`,
`movieMetadata.year`). For radarr cutoff, current quality is fetched with `moviefile/{movieFileId}` (parallel, cached 10 min).
Cache 30 s.
200 `PagedList<WantedItem>`, **WantedItem**:
`{"service": ArrService, "id": int (episodeId or movieId), "seriesId": int?, "title": string (series or movie title), "episodeLabel": string?, "episodeTitle": string?, "airDateUtc": Instant?, "releaseDate": Date?, "posterPath": ImagePath?, "monitored": bool, "lastSearchTime": Instant?, "isAvailable": bool (radarr; sonarr true), "currentQuality": string?, "cutoffQuality": string? (resolved from the profile cutoff id, group names included)}`.

#### `POST /library/wanted/search` [admin]
Body `{"service": ArrService, "ids": int[] (1..50)}`: per-item search of selected rows (`EpisodeSearch{episodeIds}` /
`MoviesSearch{movieIds}`). 202 `{"command": CommandRef}`.

#### `POST /library/wanted/search-all` [admin] [confirm]
Body `{"service": ArrService, "kind": "missing"|"cutoff"}`. `403 policy_denied` unless `policy.allowGlobalSearch`.
Otherwise `MissingEpisodeSearch{monitored:true}` / `CutoffUnmetEpisodeSearch{monitored:true}` / `MissingMoviesSearch` /
`CutoffUnmetMoviesSearch`. 202 `{command}`. `details.impact`: "Searches indexers for 892 episodes".

### 7.5 Commands
`GET /library/commands/{service}/{id}` → `{"command": CommandRef}` (upstream `command/{id}`, no cache). 404 unknown.

### 7.6 Profiles
`GET /library/profiles` (cache 10 min) → **LibraryProfiles**:
```json
{"sonarr": {"qualityProfiles": [{"id": 9, "name": "WEB-1080p"}], "rootFolders": [{"id": 1, "path": "/data/tvshows", "freeBytes": 4050000000000, "accessible": true}],
            "defaults": {"standardProfileId": 9, "animeProfileId": 7, "rootFolderPath": "/data/tvshows"}},
 "radarr": {"qualityProfiles": [{"id": 7, "name": "HD Bluray + WEB"}], "rootFolders": [...],
            "defaults": {"profileId": 7, "rootFolderPath": "/data/movies", "minimumAvailability": "released"}}}
```
Defaults come from Seerr's service settings when available (`/service/sonarr` `activeProfileId`, `activeAnimeProfileId`,
`activeDirectory`), else profile 9/7 and the first root folder. Profiles are read-only in the hub.

### 7.7 Summary for the Library screen header
`GET /library/summary` (cache 30 s) → **LibrarySummary**: `{"sonarr": ArrSummary, "radarr": ArrSummary}` with
**ArrSummary** `{"configured": bool, "version": string?, "itemCount": int, "missing": int, "cutoffUnmet": int, "sizeOnDiskBytes": int, "freeBytes": int?, "queue": {"total": int, "errors": bool, "warnings": bool}, "health": HealthMessage[]}`.
Upstream (parallel): `system/status`, `health`, `queue/status`, `wanted/missing?pageSize=0&monitored=true`,
`wanted/cutoff?pageSize=0&monitored=true`, `rootfolder`, and the cached list for counts/size.
Radarr `missing` counts only available movies: `wanted/missing` total minus unavailable entries is not cheap, so use the
cached movie list (`monitored && !hasFile && isAvailable`).

### 7.8 Interactive release search ("Choose release") [admin] [long]

Lets the admin pick a specific release for an episode, a season or a movie, grabbed **through Sonarr/Radarr** so the
download is tracked and imported (unlike Prowlarr manual search, §10.4). Shapes from Sonarr/Radarr v3 source
(`ReleaseController`, `ReleaseResource`; integrations/arr.md §9.2); never called during probing.

| Method + path | Upstream | Notes |
|---|---|---|
| `GET /library/tv/episodes/{episodeId}/releases` | Sonarr `GET /api/v3/release?episodeId=` | searches every indexer for that episode |
| `GET /library/tv/{id}/seasons/{n}/releases` | Sonarr `GET /api/v3/release?seriesId=&seasonNumber=` | season packs and episodes |
| `GET /library/movies/{id}/releases` | Radarr `GET /api/v3/release?movieId=` | |

Upstream timeout 150 s; one concurrent release search per user (`409 job_running`). Not cached (each call is a live
indexer search; Sonarr/Radarr cache the results themselves for 30 min, keyed by guid).
200 **ReleaseChoiceList** `{"items": ReleaseChoice[], "tookMs": int}` sorted like the *arr UI (approved first, then by
the upstream order, which is quality/custom-format weight). **ReleaseChoice**:
`{"releaseId": string (gateway token), "service": ArrService, "title": string, "indexer": string, "indexerId": int, "quality": QualityInfo, "customFormats": string[], "customFormatScore": int, "sizeBytes": int, "ageHours": int?, "publishDate": Instant?, "seeders": int?, "leechers": int?, "protocol": "torrent"|"usenet"|"unknown", "languages": string[], "releaseGroup": string?, "fullSeason": bool, "episodeLabels": string[] (Sonarr: from seasonNumber + episodeNumbers, anime rule), "approved": bool, "temporarilyRejected": bool, "rejected": bool, "rejections": string[], "infoUrl": string?}`.
`downloadUrl`, `guid`, `magnetUrl`, `infoHash`, `commentUrl` are **never** returned: the gateway stores
`releaseId → {service, guid, indexerId, seriesId?, episodeIds?, movieId?}` for 30 min (in memory, per user).

`POST /library/releases/grab` body `{"releaseId": string}` → Sonarr/Radarr `POST /api/v3/release {"guid": ..., "indexerId": ...}`
(the *arr resolves the cached release by guid; timeout 30 s). 201 `{"ok": true, "title": string}`. Errors:
`404 not_found` "Release expired, search again" (unknown token, or the *arr's own 30-min cache expired: upstream 404),
`422 validation_failed` when the *arr refuses (e.g. rejected release, message from upstream). Grabbing a `rejected`
release is allowed (the *arr permits manual override) but the app asks for confirmation. Invalidates the queue caches.
Audit `library.release.grab` (title only).

### 7.9 Upstream gotchas the feature must handle
Sonarr health `id` missing (key by `source`); unknown sort keys silently ignored upstream (gateway validates its own);
`description` never forwarded; diskspace not used (rootfolder gives free space); history `data` strings; lookup with
empty term 503s.

### 7.10 Role summary
Reads: member. Everything else (including release search, which runs indexer queries): admin.

### 7.11 Dashboard card `library` — **LibraryCard** (cache 30 s)
`{"sonarr": ArrSummary, "radarr": ArrSummary}` (same DTO as §7.7, `health` included).
Alerts: one per health message with `type` warning/error, id `{service}.health.{source}`, severity = type, route
`/library`; except `IndexerLongTermStatusCheck`/`IndexerStatusCheck` (covered by the indexers card) and
`AllowedHostsCheck` (severity downgraded to info, dismissible). Queue errors → warning `{service}.queue.errors`
route `/activity`.

---

## 8. Activity (qBittorrent, VPN, *arr queues, history) — feature `activity`

Routes: `/activity/**`, `/torrents/**`, `/transfer/**`, `/vpn`. Reads [member]; writes [admin].

The gateway keeps one qBittorrent maindata poller (1.5 s, lease 20 s; ARCHITECTURE §5.7) and merges deltas into an
in-memory snapshot. Every read of torrents/transfer/queue touches the lease. When the poller is idle, the first read
waits for one fresh tick (max 3 s, else returns the last snapshot with `stale: true` where the DTO has the field).

### 8.1 DTOs [activity]

**TorrentState**: `downloading, seeding, stalled, stopped, queued, checking, moving, error, metadata, unknown`
(mapping: integrations/downloads.md §1.6; `metaDL`/`forcedMetaDL` → `metadata`; `forcedDL` → downloading, `forcedUP` → seeding).
Each torrent also carries `direction: "download"|"upload"` (state ends in DL/`downloading`/`metaDL` vs UP/`uploading`).

**TorrentSummary**:
```json
{"hash": "e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e", "name": "[SubsPlease] ... [Batch]", "state": "seeding",
 "stateRaw": "uploading", "direction": "upload", "progress": 1.0, "sizeBytes": 35111357644, "downloadedBytes": 35111357644,
 "uploadedBytes": 15413602877, "amountLeftBytes": 0, "dlBps": 0, "upBps": 686561, "etaSeconds": 32732,
 "ratio": 0.438, "seeds": 3, "peers": 39, "category": "tv-sonarr", "tags": ["Keep"], "addedAt": Instant,
 "completedAt": Instant?, "lastActivityAt": Instant?, "forceStart": false, "queuePosition": null,
 "hasTrackerError": false, "hasTrackerWarning": false, "protected": true, "managedBy": "sonarr"?}
```
`etaSeconds` null when upstream is 8640000. `tags` split from the comma string. `queuePosition` null when priority 0.
`protected` = tags contain `Keep`. `managedBy`: `sonarr` for category `tv-sonarr`, `radarr` for `radarr`, else null.
Times from unix seconds (`-1` → null).

**TransferState**:
```json
{"dlBps": 1234, "upBps": 906283, "dlLimitBps": 0, "upLimitBps": 0, "altSpeedEnabled": true,
 "limits": {"dlBps": 0, "upBps": 0, "altDlBps": 10240000, "altUpBps": 10240000},
 "schedule": {"enabled": true, "from": "08:00", "to": "17:00", "days": "everyDay"},
 "connectionStatus": "connected", "dhtNodes": 312, "freeSpaceBytes": 4050000000000, "sessionPaused": false,
 "globalRatio": 0.92, "allTimeDownloadedBytes": 8030115506827, "allTimeUploadedBytes": 7409991435409,
 "sessionDownloadedBytes": 123, "sessionUploadedBytes": 456, "updatedAt": Instant, "stale": false}
```
`dlLimitBps/upLimitBps` = currently effective (0 = unlimited). `limits` from `transfer/getSpeedLimits` (cache 60 s,
invalidated by writes). `schedule` from whitelisted `app/preferences` keys (cache 10 min); `days`:
`everyDay|weekdays|weekends|monday..sunday` from `scheduler_days` 0..9. `connectionStatus: "connected"|"firewalled"|"disconnected"|"unknown"`.

**QueueItem** (unified):
```json
{"key": "e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e", "title": "Slime S4 (01-24)", "subtitle": "Sonarr · 24 episodes",
 "state": "downloading", "needsAttention": true, "attention": "importPending",
 "progress": 0.66, "sizeBytes": 35111357644, "sizeLeftBytes": 12000000000, "etaSeconds": 2470, "dlBps": 4800000, "upBps": 120000,
 "torrent": TorrentSummary?,
 "arr": [{"service": "sonarr", "queueIds": [123456, 123457], "mediaTitle": "That Time I Got Reincarnated as a Slime",
          "seriesId": 54, "movieId": null, "episodeIds": [5580, 5581], "episodesLabel": "S04E01–E24",
          "status": "downloading", "trackedStatus": "warning", "trackedState": "importPending",
          "messages": ["No files found are eligible for import in ..."], "isUpgrade": false, "posterPath": ImagePath?,
          "downloadId": "e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e", "canManualImport": true,
          "links": [{"app": "sonarr", "path": "/activity/queue"}]}]}
```
The `arr` entries are **QueueArrEntry**. `links`: `{app: sonarr|radarr, path: "/activity/queue"}` (the *arr's own queue
page, where its manual-import dialog lives; admins only, empty for members). `canManualImport`: admin, tracked state
`importBlocked` or `importPending`, and `downloadId` present.
- Grouping key = lower-case info hash (arr `downloadId` lower-cased; qBittorrent `hash`). Records with no torrent use
  `key = "{service}:{downloadId}"`.
- `state`: torrent state, except `importPending`/`importBlocked`/`failedPending`/`failed` tracked states which win
  (values: TorrentState plus `importPending`, `importBlocked`, `importing`, `failed`, `delayed`, `completed`).
- `needsAttention`: tracked status warning/error, tracked state importBlocked/importPending/failedPending/failed, torrent
  state error, or tracker error. `attention`: the first reason (`importBlocked`, `importPending`, `failed`, `trackerError`, `error`, `warning`).
- `messages` = flattened `statusMessages[].messages` (plus `errorMessage`), max 5.

### 8.2 Unified queue
`GET /activity/queue`
Query: `filter=active|all|downloading|seeding|attention` (default `active`: everything with an arr record, downloading or
stalled/queued/checking/metadata/error, or speed > 0), `category`, `sort=progress|eta|added|name|speed` (default: attention
first, then downloading by eta, then the rest by added desc).
Upstream: torrent snapshot + Sonarr `queue?page=1&pageSize=200&includeSeries=true&includeEpisode=true` + Radarr
`queue?page=1&pageSize=200&includeMovie=true` (cache 5 s each).
200 **QueueResponse** `{"items": QueueItem[], "summary": {"downloading": int, "seeding": int, "stalled": int, "attention": int, "dlBps": int, "upBps": int}, "arr": {"sonarr": SectionStatus, "radarr": SectionStatus}, "qbittorrent": SectionStatus, "stale": bool}`
with **SectionStatus** [common] = `{"status": "ok"|"error"|"disabled", "error": ApiError?}`: one failing source does not
fail the whole response.

### 8.3 *arr queue actions [admin]

| Method + path | Body / query | Upstream | Response |
|---|---|---|---|
| `POST /activity/queue/remove` [confirm] | `{"items": [{"service": ArrService, "queueIds": int[]}], "removeFromClient": bool (default true), "blocklist": bool (default false), "searchAgain": bool (default false, only with blocklist)}` | `DELETE queue/bulk?removeFromClient&blocklist&skipRedownload=!searchAgain` body `{ids}` per service | 200 `{"removed": int, "alreadyGone": int}` (404 counted as already gone) |
| `POST /activity/queue/grab` | `{"service": ArrService, "queueIds": int[]}` | `POST queue/grab/bulk {ids}` | 200 `{"ok": true}` |
| `POST /activity/queue/refresh` | `{"service": ArrService?}` | `POST command RefreshMonitoredDownloads` | 202 `{"commands": CommandRef[]}` |

`details.impact` example: "Removes 24 queue items and deletes the torrent; the release is blocklisted and Sonarr searches again".

#### 8.3.1 Manual import [admin]

Resolves the `importBlocked`/`importPending` items that the README sends to Discord `#alerts` and that the activity card
raises as `queue.import.<key>`. Shapes from Sonarr/Radarr v3 source (`ManualImportController`, `ManualImportResource`,
`ManualImportCommand`); documented in integrations/arr.md §9.1. Never called during probing.

`GET /activity/queue/{service}/{queueId}/import` (`service` = `sonarr|radarr`, `queueId` int; no cache; timeout 60 s)
- The gateway looks up the queue record (cached queue, else `GET /api/v3/queue/{id}`) to get `downloadId` and
  `seriesId`/`movieId`, then calls `GET /api/v3/manualimport?downloadId=<hash as in the queue>&seriesId=<id>&filterExistingFiles=true`
  (Radarr: `&movieId=`). 404 when the queue record is gone (decluttarr may have removed it).
- 200 **ManualImportCandidates** `{"service": ArrService, "queueId": int, "downloadId": string, "title": string, "items": ManualImportFile[]}`.
  **ManualImportFile**: `{"fileId": string (gateway token for the upstream path), "relativePath": string, "sizeBytes": int, "quality": QualityInfo, "languages": string[], "releaseGroup": string?, "seriesId": int?, "seasonNumber": int?, "episodes": [{"id": int, "label": string, "title": string?}], "movieId": int?, "movieTitle": string?, "customFormatScore": int?, "rejections": [{"reason": string, "type": "permanent"|"temporary"|"unknown"}], "importable": bool}`.
  `importable` = series/movie and (Sonarr) at least one episode are resolved. The absolute `path`/`folderName` and the
  raw `quality`/`languages` objects are kept server-side behind `fileId` (30 min, per user).

`POST /activity/queue/import` body
`{"service": ArrService, "queueId": int, "importMode": "auto"|"move"|"copy" (default "auto"), "files": [{"fileId": string, "seriesId": int?, "episodeIds": int[]?, "movieId": int?}]}`
(1..200 files; `episodeIds`/`seriesId`/`movieId` default to the candidate's values, so the app can import unchanged
candidates by `fileId` alone and override the mapping when the *arr guessed wrong).
- Upstream `POST /api/v3/command` with
  `{"name": "ManualImport", "importMode": "auto", "files": [{"path", "seriesId", "episodeIds", "quality", "languages", "releaseGroup", "downloadId", "indexerFlags": 0, "releaseType": "singleEpisode"|"multiEpisode"|"seasonPack"}]}`
  (Sonarr; `releaseType` from the candidate) or `{"name": "ManualImport", "importMode": "auto", "files": [{"path", "movieId", "quality", "languages", "releaseGroup", "downloadId", "indexerFlags": 0}]}`
  (Radarr). `quality`/`languages` are passed back exactly as the candidate returned them.
- 202 `{"command": CommandRef}`; the app polls `GET /library/commands/{service}/{id}`. Invalidates the queue caches.
  `404 not_found` "Import candidates expired, reload" for an unknown `fileId`. Audit `activity.queue.import`.

### 8.4 Torrents

#### `GET /torrents`
Query: `filter=all|downloading|seeding|completed|stopped|running|active|inactive|stalled|checking|errored` (validated;
gateway filters the snapshot itself), `category`, `tag`, `q`, `sort=added|name|progress|dlSpeed|upSpeed|eta|ratio|size`
(default added), `order` (default desc).
200 **TorrentList** `{"items": TorrentSummary[], "transfer": TransferState, "categories": string[], "tags": string[], "stale": bool}`.
App polls every 2 s while visible; ETag/304 supported.

#### `GET /torrents/{hash}`
Upstream (parallel): `torrents/properties`, `torrents/files`, `torrents/trackers`. 404 when qBittorrent 404s.
200 **TorrentDetail**:
`{"summary": TorrentSummary, "savePath": string, "pieceSizeBytes": int, "piecesHave": int, "piecesTotal": int, "timeActiveSeconds": int, "seedingTimeSeconds": int, "wastedBytes": int, "avgDlBps": int, "avgUpBps": int, "connections": int, "seedsTotal": int, "peersTotal": int, "comment": string?, "isPrivate": bool, "shareLimits": ShareLimits, "files": TorrentFile[], "trackers": TrackerInfo[], "arr": QueueArrEntry[]}`.
`savePath` is shown (it is a container path, useful for support). **ShareLimits**:
`{"mode": "global"|"unlimited"|"custom", "ratio": double?, "seedingMinutes": int?, "inactiveMinutes": int?, "action": "default"|"stop"|"remove"|"removeWithContent"|"enableSuperSeeding", "effectiveRatio": double, "effectiveSeedingMinutes": int}`.
**TorrentFile**: `{"index": int, "name": string, "sizeBytes": int, "progress": double, "priority": "skip"|"normal"|"high"|"max", "availability": double?}`.
**TrackerInfo**: `{"url": string (always reduced to `scheme://host[:port]`, path and query dropped, for every role: private-tracker announce URLs embed passkeys), "tier": int, "status": "disabled"|"notContacted"|"working"|"updating"|"notWorking"|"trackerError"|"unreachable"|"unknown", "message": string?, "seeds": int?, "peers": int?, "downloaded": int?}` (DHT/PeX/LSD rows and `endpoints[]` omitted).

#### `POST /torrents/actions` [admin]
Body **TorrentActionRequest**:
`{"hashes": string[] (1..200), "action": "stop"|"start"|"forceStart"|"recheck"|"reannounce"|"delete"|"setCategory"|"addTags"|"removeTags"|"topPriority"|"bottomPriority"|"increasePriority"|"decreasePriority", "deleteFiles": bool? (delete), "category": string? (setCategory; "" clears), "tags": string[]? (add/removeTags), "force": bool? (delete of *arr-managed), "confirm": bool?}`.
Upstream (form posts, `hashes` pipe-joined): `torrents/stop|start|setForceStart(value=true)|recheck|reannounce|delete|setCategory|addTags|removeTags|topPrio|bottomPrio|increasePrio|decreasePrio`.
- `delete` is [confirm]. If any hash has an *arr queue record and `force` is not true → `409 managed_by_arr` with
  `details: {items: [{hash, service, queueIds}]}` (the app then offers the *arr removal).
- `setCategory` to a category that does not exist → `422 validation_failed`.
200 `{"ok": true}` and an immediate poller tick. Audit `activity.torrent.<action>`.

| Method + path | Role | Body | Upstream | Response |
|---|---|---|---|---|
| `PUT /torrents/{hash}/share-limits` | admin; **[confirm] when `action` is `remove` or `removeWithContent`** | `{"mode": "global"\|"unlimited"\|"custom", "ratio": double?, "seedingMinutes": int?, "inactiveMinutes": int?, "action": string? (default "default"), "confirm": bool?}` | `torrents/setShareLimits` with all five fields (global = -2s, unlimited = -1s) | 200 `ShareLimits`; 428 with `details.impact` "qBittorrent will delete <name> and its files once ratio ≥ 1.0" (or "...removes <name>, keeping files...") |
| `PUT /torrents/{hash}/files/priority` | admin | `{"indexes": int[], "priority": "skip"\|"normal"\|"high"\|"max"}` | `torrents/filePrio` (0/1/6/7) | 200 `{"ok": true}` |
| `POST /torrents/add` | admin | `{"urls": string[]? (1..20 magnet/http(s) URLs), "torrentFilesBase64": string[]? (max 5 files, 5 MB each decoded, must start with `d`), "category": string? (default "manual"), "tags": string[]?, "stopped": bool?}` (at least one of urls/files) | `torrents/add` (`multipart` via `UpstreamClient.send`; `stopped` v5 name). Creates category `manual` first if missing and requested. http(s) URLs are passed to qBittorrent, which fetches them itself through the VPN (the gateway never fetches them). | 201 `{"ok": true}`; 422 when qBittorrent answers 415 (invalid torrent). Used by the app's "Add torrent" sheet and incoming `magnet:` links (APP.md §6.4). |

### 8.5 Transfer
| Method + path | Role | Body | Upstream | Response |
|---|---|---|---|---|
| `GET /transfer` | member | – | snapshot `server_state` + cached limits/schedule | `TransferState` |
| `PUT /transfer/alt-speed` | admin | `{"enabled": bool}` | `transfer/setSpeedLimitsMode mode=0\|1` (never toggle) | 200 `TransferState` |
| `PUT /transfer/limits` | admin | `{"dlBps": int, "upBps": int, "altDlBps": int, "altUpBps": int}` (0 = unlimited) | `transfer/setSpeedLimits` | 200 `TransferState` |
| `PUT /transfer/session` | admin | `{"paused": bool}` | `transfer/pauseSession` / `resumeSession` | 200 `TransferState` |
| `GET /transfer/categories` | member | – | `torrents/categories`, `torrents/tags` (cache 60 s) | **CategoryList** `{"categories": [{"name": string, "savePath": string?, "readOnly": bool}], "tags": string[]}` (`readOnly` for `tv-sonarr`, `radarr`, `lidarr`, `books`) |

### 8.6 VPN
`GET /vpn` (cache 30 s) → **VpnStatus**:
`{"status": "connected"|"degraded"|"down"|"unknown", "publicIp": string?, "country": string?, "region": string?, "city": string?, "organization": string?, "forwardedPort": int?, "listenPort": int?, "portInSync": bool, "qbitConnection": string, "gluetunHealth": "healthy"|"unhealthy"|"starting"|"none"|"unknown", "checkedAt": Instant}`.
Upstream: gluetun `/v1/publicip/ip` and `/v1/openvpn/portforwarded` (JSON with text/plain content type), qBittorrent
`listen_port` (whitelisted preferences, cache 10 min) and `connection_status`, Docker container list for gluetun health
(Dart enum name for `gluetunHealth`: **VpnGluetunHealth**).
Rules: `down` when `publicIp` empty or gluetun unreachable; `degraded` when port 0, out of sync, or qBittorrent not
`connected`; else `connected`. `forwardedPort` 0 → null.

### 8.7 Merged history
`GET /activity/history`
Query: `service=all|sonarr|radarr` (default all), `types` (comma list of ArrHistoryType; default all), `limit` (max 100),
`cursor`. Upstream: `history?page&pageSize=50&sortKey=date&sortDirection=descending&includeSeries=true&includeEpisode=true`
(Sonarr) / `includeMovie=true` (Radarr), with `eventType` ints from §5. The cursor stores each source's page and index
(ARCHITECTURE: merged-feed cursor); upstream pages are cached 30 s.
200 `CursorPage<ArrHistoryItem>`.

### 8.8 Role summary
Reads: member. All torrent/transfer/queue writes: admin.

### 8.9 Dashboard card `activity` — **ActivityCard** (cache 5 s; touches the poller lease)
`{"transfer": {"dlBps", "upBps", "altSpeedEnabled", "connectionStatus"}, "counts": {"downloading": int, "seeding": int, "stalled": int, "attention": int}, "top": QueueItem[] (max 3: attention first, then by eta), "vpn": VpnStatus}`.
Alerts: `vpn.down` (error, route `/activity`), `vpn.port` (warning, "Forwarded port not in sync"),
`qbittorrent.auth` (error, when `QbitSession.credentialsRejected`), `queue.import.<key>` (warning per item with
importBlocked/importPending, max 5, "Manual import needed: <title>", route `/activity?tab=queue&import=<key>`, which
opens the manual-import sheet for that item, §8.3.1).

---

## 9. Calendar — feature `calendar`

### 9.1 `GET /calendar`
Query: `start` (Date, required), `end` (Date, required, `end - start` ≤ 62 days), `unmonitored=true|false` (default
false), `types=episode,movie` (default both). The gateway converts dates to UTC bounds using `YAMS_HUB_TZ_OFFSET`
(start 00:00 local → UTC; end 23:59:59 local).
Upstream: Sonarr `calendar?start&end&unmonitored&includeSeries=true`, Radarr `calendar?start&end&unmonitored`, plus
the Sonarr queue (`episodeId`) and the Radarr queue (`movieId`), each fetched with `queue?page=1&pageSize=200` and
cached 5 s, to set `downloading` on episode **and** movie items; queue failures are ignored (`downloading: false`).
Cache 5 min per window (the `downloading` flags are re-applied from the 5 s queue caches on every request).
200 **CalendarResponse**:
```json
{"start": "2026-11-07", "end": "2026-11-21",
 "items": [{"id": "episode:5600", "kind": "episode", "airDateUtc": "2026-11-10T15:00:00Z", "date": "2026-11-10",
            "title": "The Apothecary Diaries", "subtitle": "S02E17 · Title", "seriesId": 159, "episodeId": 5600,
            "seasonNumber": 2, "episodeNumber": 17, "absoluteEpisodeNumber": null, "finaleType": null,
            "network": "Nippon TV", "hasFile": false, "monitored": true, "downloading": false,
            "posterPath": ImagePath?},
           {"id": "movie:204:digital", "kind": "movie", "date": "2026-11-17", "title": "The Odyssey",
            "subtitle": "Digital release", "movieId": 204, "releaseType": "digital", "hasFile": false,
            "monitored": true, "downloading": false, "posterPath": ImagePath?}],
 "sources": {"sonarr": SectionStatus, "radarr": SectionStatus}}
```
**CalendarItem** [calendar]: `id`, `kind: "episode"|"movie"`, `airDateUtc: Instant?` (episodes), `date: Date`
(episodes: local date of `airDateUtc` with the configured offset, falling back to Sonarr `airDate`; movies: the release
date), `title`, `subtitle`, `seriesId?`, `episodeId?`, `movieId?`, `seasonNumber?`, `episodeNumber?`,
`absoluteEpisodeNumber?`, `finaleType?`, `network?`, `releaseType: "cinema"|"digital"|"physical"?`, `hasFile`,
`monitored`, `downloading`, `posterPath?`. A movie produces one item **per** release date inside the window.
Items sorted by `date`, then `airDateUtc`, then title.

### 9.2 Dashboard card `calendar` — **CalendarCard** (cache 5 min)
`{"items": CalendarItem[] (today .. today+7, max 8), "countNext7Days": int}`. No alerts.

---

## 10. Indexers (Prowlarr) — feature `indexers`

Routes: `/indexers/**`. Reads [member]; writes [admin]. Prowlarr `description`, `fields`, `capabilities.categories`
and any `downloadUrl` never reach the app.

### 10.1 DTOs [indexers]
**Indexer**:
```json
{"id": 15, "name": "Uindex", "enabled": true, "priority": 25, "protocol": "torrent", "privacy": "public",
 "tags": [{"id": 1, "label": "flaresolverr"}], "usesFlareSolverr": true, "status": "failing",
 "disabledTill": "2026-11-08T19:06:16Z", "failingSince": "2026-05-29T23:36:28Z", "lastFailure": "2026-11-07T19:06:16Z",
 "supportsRss": true, "supportsSearch": true, "baseUrl": "https://uindex.org/", "implementation": "Cardigann",
 "language": "en-US", "added": Instant, "stats": IndexerStats?}
```
`status: "ok"|"failing"|"disabled"`: disabled when `enable` false; failing when an indexerstatus row has
`disabledTill > now`; else ok. `usesFlareSolverr`: has the tag whose label is `flaresolverr`.
**IndexerStats**: `{"queries": int, "grabs": int, "rssQueries": int, "authQueries": int, "failedQueries": int, "failedGrabs": int, "failedRssQueries": int, "avgResponseMs": int}`.

### 10.2 Reads
| Method + path | Query | Upstream | Cache | Response |
|---|---|---|---|---|
| `GET /indexers` | – | `indexer`, `indexerstatus`, `tag`, `health`, `indexerstats` (stats cached 10 min, last 30 days) | 60 s | **IndexerList** `{"items": Indexer[], "health": HealthMessage[], "statsFrom": Instant, "statsTo": Instant}` |
| `GET /indexers/{id}` | – | `indexer/{id}` + the same joins | 60 s | `Indexer` + `description: string?`, `categories: string[]` (top-level names) |
| `GET /indexers/history` | `page`, `pageSize` (max 100, clamped), `type=grabbed\|query\|rss\|auth` (1/2/3/4), `successful=true\|false`, `indexerId` | `history?page&pageSize&sortKey=date&sortDirection=descending[&eventType][&successful][&indexerIds]` | 15 s | `PagedList<IndexerHistoryItem>` |
| `GET /indexers/categories` | – | `indexer/categories` | 24 h | `ItemList<{id: int, name: string, subCategories: {id, name}[]}>` (**IndexerCategory**) |

**IndexerHistoryItem**: `{"id": int, "indexerId": int, "indexerName": string, "date": Instant, "successful": bool, "type": "grabbed"|"query"|"rss"|"auth"|"infoQuery"|"unknown", "source": string?, "host": string?, "query": string?, "queryType": string?, "categories": string?, "results": int?, "elapsedMs": int?, "grabTitle": string?}`
(from `data` strings; `url` dropped).

### 10.3 Writes [admin]
| Method + path | Body | Upstream | Response |
|---|---|---|---|
| `PATCH /indexers` | `{"ids": int[] (1..50), "enabled": bool?, "priority": int? (1..50)}` (at least one) | `PUT indexer/bulk {ids, enable?, priority?}` (accept any 2xx) | 200 `IndexerList` (re-read) |
| `POST /indexers/{id}/test` | – | `GET indexer/{id}` → `POST indexer/test?forceTest=true` with the full resource; timeout 150 s | 202 `{"job": Job}`; job `result`: **IndexerTestResult** `{"id": int, "valid": bool, "failures": string[]}` |
| `POST /indexers/test-all` | – | `POST indexer/testall` (parse body on 200 and 400) | 202 `{"job": Job}`; `result: {"items": IndexerTestResult[]}` |

### 10.4 Manual search and grab [admin] [long]
- `GET /indexers/search?q=&type=search|tvsearch|movie|music|book&indexerIds=1,2&categories=2000,5000&limit=100`
  (q required 2..200 chars, limit ≤ 100). Upstream `GET search?query&type&indexerIds=..(repeated)&categories=..&limit`,
  timeout 150 s. One concurrent search per user (`409 job_running`). 200 **ReleaseList**
  `{"items": Release[], "tookMs": int}`.
  **Release**: `{"releaseId": string (gateway token), "indexerId": int, "indexer": string, "title": string, "sizeBytes": int, "publishDate": Instant?, "ageHours": int?, "seeders": int?, "leechers": int?, "grabs": int?, "categories": string[], "infoUrl": string?, "protocol": string, "hasMagnet": bool, "imdbId": string?, "tmdbId": int?, "tvdbId": int?}`.
  The gateway keeps `releaseId → {indexerId, downloadUrl, magnetUrl}` for 30 min; `downloadUrl` is never returned.
- `POST /indexers/grab` `{"releaseId": string, "category": string (default "manual"), "tags": string[]?}` → magnet to
  qBittorrent `torrents/add urls=`, else the gateway downloads the `.torrent` itself and uploads the bytes (multipart).
  201 `{"ok": true}`; `404 not_found` "Release expired, search again". **SSRF rules for the download**
  (`downloadUrl` may come from tracker HTML, i.e. untrusted):
  - Prowlarr advertises its external base in `downloadUrl`; the gateway rewrites scheme/host/port to `PROWLARR_URL`
    when the path starts with `/<indexerId>/download` (Prowlarr's proxied download route). Such a URL is fetched with
    the Prowlarr client (key in the header, the `apikey=` query parameter removed).
  - Any other `downloadUrl` is fetched only if it is `https` on a public address, through `ctx.remoteHttp`
    (`RemoteFetcher`: no automatic redirects, at most 3 followed manually, every hop public-IP-checked; loopback,
    RFC 1918, `100.64/10`, `169.254/16`, `fc00::/7`, the `yams_network` subnet and single-label Docker names are
    rejected → `422 validation_failed` "Release URL not allowed").
  - A redirect (from either path) to `magnet:` is handed to qBittorrent as a magnet.
  - Timeout 60 s, body capped at 5 MB **while streaming**, and the body must be bencode starting with `d` (else
    `502 upstream_bad_response`).
  - `downloadUrl` is never logged (only `indexerId` and the release title); errors are passed through `redactSecrets`.
  Tested: a redirect to `http://socket-proxy:2375/...` is refused.

### 10.5 Role summary
Reads: member. Writes, search and grab: admin.

### 10.6 Dashboard card `indexers` — **IndexersCard** (cache 60 s)
`{"total": int, "enabled": int, "failing": [{"id": int, "name": string, "disabledTill": Instant?}], "grabs24h": int?, "queries24h": int?}`
(24 h numbers from `indexerstats?startDate=now-24h`, cached 10 min; omitted on failure).
Alerts: `prowlarr.indexer.<id>` (warning, "Indexer Uindex failing, retry at 19:06", route `/indexers`); Prowlarr health
warnings/errors as `prowlarr.health.<source>` (AllowedHostsCheck as info).

---

## 11. Containers, updates, maintenance — feature `containers`

Routes: `/containers/**`, `/updates/**`, `/maintenance/**`. Reads [member] except logs (admin). Writes [admin].

Background: Docker events stream (always on, filtered to container
`start|stop|die|kill|restart|oom|health_status|create|destroy`, ring buffer of 1000 events), stats poller (10 s, lease 60 s,
`one-shot=true` for running containers, deltas computed in the gateway), Watchtower check every 6 h.

### 11.1 DTOs [containers]
**ContainerSummary**:
```json
{"name": "sonarr", "service": "sonarr", "group": "automation", "image": "lscr.io/linuxserver/sonarr:latest",
 "imageVersion": "4.0.20.3014-ls2", "state": "running", "statusText": "Up 25 minutes", "health": "none",
 "startedAt": Instant?, "uptimeSeconds": int?, "cpuPercent": 3.04, "memBytes": 231051264, "memPercent": 2.87,
 "netRxBps": 1200, "netTxBps": 800, "sharesNetworkWith": null, "autoUpdate": false, "pinned": false,
 "update": {"available": true, "checkedAt": Instant}?, "protection": "none"|"confirm"|"locked",
 "ports": [{"public": 8989, "private": 8989, "protocol": "tcp"}], "links": [ExternalLink]}
```
`state: "created"|"running"|"paused"|"restarting"|"removing"|"exited"|"dead"|"unknown"`, `health: "healthy"|"unhealthy"|"starting"|"none"|"unknown"`.
`service` from label `com.docker.compose.service` (fallback name without slash). `group` from policy groups
(else `other`). `imageVersion` from label `org.opencontainers.image.version`. `autoUpdate` = label
`com.centurylinklabs.watchtower.monitor-only == "false"`. `pinned` = image tag is not `latest`/absent. Stats fields
absent until the poller has two samples. `sharesNetworkWith`: `gluetun` for `container:<id>` network mode (its net
counters are then omitted to avoid double counting). `statusText` without the `(healthy)` suffix. `ports` de-duplicated
on `public`. `links`: native web UI when the service is an ExternalApp.

**ContainerDetail**: `ContainerSummary` fields plus `{"restartCount": int, "finishedAt": Instant?, "exitCode": int?, "oomKilled": bool, "error": string?, "restartPolicy": string, "imageId": string, "createdAt": Instant, "healthLog": ContainerHealthLogEntry[], "events": ContainerEvent[] (last 20), "dependents": string[], "dependsOn": string[], "mounts": [{"destination": string, "readOnly": bool}], "networkMode": string, "pids": int?}`.
**ContainerHealthLogEntry** `{"start": Instant, "end": Instant, "exitCode": int, "output": string?}`: `output` is
returned **to admins only**, passed through `redactSecrets` and truncated to the first 200 chars (healthcheck
commands and their output can echo URLs with keys); members get exit codes and times only. `error` is redacted too.
`dependents/dependsOn` from a static map: gluetun → [qbittorrent]; jellystat-db → [jellystat]; sonarr/radarr →
[recyclarr, decluttarr, bazarr]; socket-proxy → [homepage, uptime-kuma]. **Never** `Config.Env`, `Cmd`, `HostConfig` or mount sources.

**ContainerEvent**: `{"at": Instant, "name": string, "action": "start"|"stop"|"die"|"kill"|"restart"|"oom"|"health"|"create"|"destroy"|"unknown", "health": string? (for health events), "exitCode": int?}`.

**LogLine**: `{"at": Instant?, "stream": "stdout"|"stderr", "text": string}`. `text` is passed through `redactSecrets`
(ARCHITECTURE §5.14) before it leaves the gateway.

### 11.2 Reads
| Method + path | Query | Upstream | Response |
|---|---|---|---|
| `GET /containers` | `group`, `q` | `/v1.54/containers/json?all=true` (cache 5 s) + stats cache + update cache | **ContainerList** `{"items": ContainerSummary[], "engine": {"version": string, "running": int, "stopped": int, "total": int, "images": int}, "statsAt": Instant?}` |
| `GET /containers/{name}` | – | `/v1.54/containers/{name}/json` | `ContainerDetail`; 404 |
| `GET /containers/{name}/logs` [admin] | `tail` (1..2000, default 200), `since` (Instant), `stream=all\|stdout\|stderr` | `/v1.54/containers/{name}/logs?stdout&stderr&timestamps=1&tail&since` (multiplexed frames decoded; Tty containers read raw) | **LogResponse** `{"lines": LogLine[], "truncated": bool}`; `503 service_not_configured` with message "Logs need ALLOW_LOGS=1" when the proxy returns 403 |
| `GET /containers/events` | `limit` (max 200), `name` | ring buffer | `ItemList<ContainerEvent>` newest first |

### 11.3 Control [admin]
`POST /containers/{name}/actions` body `{"action": "restart"|"stop"|"start", "confirm": bool?}`.
- `{name}` is resolved by **exact name** first (§11.6); the canonical name is used for every check and for the
  upstream path.
- `features.containerActions == false` (proxy self-test failed) → `503 service_not_configured`.
- `locked` containers → `403 policy_denied`. `confirm` containers and every `stop` → [confirm] (428 without).
- Runs as a job (kind `containers.<action>`, target name). Upstream `POST /v1.54/containers/{name}/{action}?t=30`
  (start has no `t`), HTTP timeout 90 s. 304 counts as success ("already running/stopped").
- `gluetun` restart/start adds a second step: wait until gluetun reports healthy (poll inspect every 2 s, max 90 s), then
  restart `qbittorrent`. Stopping gluetun warns in `details.impact` that qBittorrent loses network.
- 202 `{"job": Job}`; job `result`: `{"state": string, "health": string}` (inspect after the action).
- Audit `containers.<action>`.

### 11.4 Updates
**UpdateInfo**: `{"name": string, "image": string, "updateAvailable": bool?, "pinned": bool, "currentVersion": string?, "currentDigest": string?, "latestDigest": string?, "error": string?, "autoUpdate": bool, "canUpdate": bool}`
(`canUpdate`: updater configured, service in its allow-list, not locked).

| Method + path | Role | Body | Upstream | Response |
|---|---|---|---|---|
| `GET /updates` | member | – | cached check (`$DATA/updates.json`) + Watchtower `GET /v1/metrics` (cache 60 s; also used by health) | **UpdatesResponse** `{"checkedAt": Instant?, "checking": bool, "available": bool (watchtower check endpoint enabled), "items": UpdateInfo[], "updaterAvailable": bool, "lastScan": WatchtowerScan?}` |
| `POST /updates/check` | admin | `{"containers": string[]?}` | Watchtower `POST /v1/check?timeout=2m[&container=a,b]`, HTTP timeout 150 s | 202 `{"job": Job}`; 429 if the last full check was < 5 min ago; 503 `service_not_configured` with enable instructions when `/v1/check` is 404 |
| `POST /updates/{service}` | admin [confirm] | – | `{service}` must match `^[a-z0-9][a-z0-9_.-]*$` **and** be in the updater's `GET /services` allow-list (cached 10 min), else 404; then updater `POST /update/{service}`, poll `GET /jobs/{id}` every 3 s; afterwards Watchtower check for that container | 202 `{"job": Job}` (gateway job mirrors the updater's steps/log, redacted); 403 `policy_denied` for locked; 503 when the updater is not configured |

**WatchtowerScan** `{"scanned": int, "updated": int, "failed": int, "skipped": int, "restarted": int, "scansTotal": int, "at": Instant?}`
parsed from the Prometheus text of `/v1/metrics` (`watchtower_containers_scanned|updated|failed|skipped|restarted`,
`watchtower_scans_total`; fixture `system/watchtower_v1_metrics.txt`). `at` from `GET /v1/status` `timestamp` when it
answers 200 (204 before the first scan → absent). Present whenever Watchtower is reachable, **even when
`available == false`**, so the Updates screen and the ContainersCard match Homepage's Watchtower widget before the
user enables `/v1/check`.

### 11.5 Maintenance
`GET /maintenance/decluttarr` (cache 60 s; logs `since=now-24h`, stderr) → **DecluttarrStatus**:
`{"container": {"state": string, "health": string}, "lastRunAt": Instant?, "intervalMinutes": 10, "nextRunAt": Instant?, "testMode": bool, "last24h": {"runs": int, "removed": [{"at": Instant, "job": string, "title": string, "kind": "removal"|"queueRemoval"}], "strikes": [{"at": Instant, "job": string, "title": string, "count": int, "max": int}], "searches": int, "obsoleteTagged": int}, "warnings": [{"at": Instant, "text": string}], "errors": [{"at": Instant, "text": string}]}`.
Parser: integrations/system.md §8 regexes (job-name tuple bug handled).

`GET /maintenance/recyclarr` (cache 5 min; newest `*.debug.log` in `RECYCLARR_LOG_DIR/cli`) → **RecyclarrStatus**:
`{"container": {...}, "schedule": "0 4 * * 0", "nextRunAt": Instant, "lastRun": {"startedAt": Instant, "ok": bool, "instances": [{"name": string, "type": "sonarr"|"radarr", "customFormatsCreated": int, "customFormatsUpdated": int, "customFormatsSkipped": int, "profilesSynced": int?, "qualitySizesSynced": bool, "completedAt": Instant?}], "warnings": string[], "errors": string[]}?, "canSyncNow": bool}`.

`POST /maintenance/recyclarr/sync` [admin] [confirm] → updater `POST /exec/recyclarr-sync` → 202 `{"job": Job}`;
503 without the updater.

### 11.6 Guardrail summary
- **Exact-name resolution** for every `{name}` route (`/containers/{name}`, `/logs`, `/actions`): the route regex is
  `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$` (so `.` and `..` never match → 404), then `{name}` must equal one entry's
  `Names[0]` without the leading `/` in the current `/containers/json?all=true` list (cache 5 s; refreshed once on a
  miss). Anything else, **including full container ids and unique id prefixes** (which the Docker Engine would
  otherwise resolve), returns `404 not_found`. The canonical name is used for the locked/confirm checks, the
  gluetun → qbittorrent coupling and the upstream path. Tests: an id prefix of a locked container → 404; `..` → 404.
- locked: `yams-hub`, `socket-proxy-hub`, `yams-hub-updater` (policy). confirm: policy list + every stop.
- `/updates/{service}`: validated against the updater allow-list (§11.4).

### 11.7 Role summary
List/detail/events/updates/maintenance reads: member. Logs, actions, checks, updates, sync: admin.

### 11.8 Dashboard card `containers` — **ContainersCard** (cache 10 s)
`{"total": int, "running": int, "unhealthy": string[], "stopped": string[] (excluding profiles-disabled ones that never ran), "updatesAvailable": int, "lastScan": WatchtowerScan?, "topCpu": [{"name": string, "cpuPercent": double}] (max 3), "decluttarr": {"lastRunAt": Instant?, "removed24h": int}?}`.
Alerts: `container.unhealthy.<name>` (error), `container.stopped.<name>` (warning, for containers that are exited with a
non-zero code or that were running in the last 24 h), `updates.available` (info, "N container updates available", route
`/containers/updates`).

---

## 12. Subtitles (Bazarr) — feature `subtitles`

Routes: `/subtitles/**`. Reads [member]; writes [admin]. Write parameters go in the Bazarr query string.

### 12.1 DTOs [subtitles]
**SubtitleLanguage**: `{"code": "en", "name": "English", "forced": bool, "hi": bool}`.
**WantedSubtitle**: `{"type": "episode"|"movie", "title": string (series or movie), "episodeLabel": string? ("S01E11" from "1x11"), "episodeTitle": string?, "seriesId": int?, "episodeId": int?, "movieId": int?, "missing": SubtitleLanguage[], "posterPath": ImagePath? (Sonarr/Radarr cover via /img/arr), "seriesType": string?}`.
**SubtitleHistoryItem**: `{"type": "episode"|"movie", "title": string, "episodeLabel": string?, "action": "deleted"|"downloaded"|"manual"|"upgraded"|"uploaded"|"synced"|"translated"|"extracted"|"unknown", "language": SubtitleLanguage?, "provider": string?, "score": string?, "description": string?, "at": Instant? (from parsed_timestamp MM/dd/yy HH:mm:ss UTC)}`.

### 12.2 Reads
| Method + path | Query | Upstream | Cache | Response |
|---|---|---|---|---|
| `GET /subtitles/summary` | – | `/api/badges`, `/api/providers`, `/api/system/health`, `/api/system/status`, `/api/system/tasks` | 60 s | **SubtitlesSummary** `{"missingEpisodes": int, "missingMovies": int, "throttledProviders": int, "providers": [{"name": string, "status": string, "retry": string?, "ok": bool}], "signalr": {"sonarr": "live"\|"down", "radarr": "live"\|"down"}, "health": [{"object": string, "issue": string}], "version": string?, "tasks": [{"id": string, "name": string, "interval": string, "nextRun": string, "running": bool}]}` |
| `GET /subtitles/wanted` | `type=episodes\|movies` (required), `page`, `pageSize` (max 100) | `/api/{type}/wanted?start&length` (always send length) | 30 s | `PagedList<WantedSubtitle>` |
| `GET /subtitles/history` | `type=episodes\|movies`, `page`, `pageSize` (max 100) | `/api/{type}/history?start&length` | 60 s | `PagedList<SubtitleHistoryItem>` |
| `GET /subtitles/jobs` | `status=running\|pending\|failed\|completed` (default running) | `/api/system/jobs?status=` | none | `ItemList<{"id": int, "name": string, "status": string, "progress": double?, "message": string?, "lastRunAt": Instant?}>` (**SubtitleJob**) |

### 12.3 Writes [admin]
| Method + path | Body | Upstream | Response |
|---|---|---|---|
| `POST /subtitles/search` | `{"type": "episode"\|"movie", "seriesId": int?, "episodeId": int?, "movieId": int?, "language": string, "forced": bool, "hi": bool}` | episode: `PATCH /api/episodes/subtitles?seriesid&episodeid&language&forced&hi`; movie: `PATCH /api/movies/subtitles?radarrid&language&forced&hi` | 202 `{"queued": true}` (Bazarr 204) |
| `POST /subtitles/search-item` | `{"type": "series"\|"movie", "id": int}` | `PATCH /api/series?seriesid=&action=search-missing` / `PATCH /api/movies?radarrid=&action=search-missing` | 202 `{"queued": true}` |
| `POST /subtitles/search-all` [confirm] | `{"type": "episodes"\|"movies"}` | `POST /api/system/tasks?taskid=wanted_search_missing_subtitles_series\|_movies` | 202 `{"queued": true}` |
| `POST /subtitles/providers/reset` | – | `POST /api/providers?action=reset` | 204 |
| `POST /subtitles/tasks/{taskId}/run` | – | `POST /api/system/tasks?taskid=` (taskId must be in the cached task list) | 202 `{"queued": true}` |

### 12.4 Role summary
Reads: member. Writes: admin.

### 12.5 Notes
Bazarr's `providers` badge is a hint: `throttledProviders` = count of providers whose `status != "Good"`, not the badge.

### 12.6 Dashboard card `subtitles` — **SubtitlesCard** (cache 60 s)
`{"missingEpisodes": int, "missingMovies": int, "throttledProviders": int, "signalrDown": bool}`.
Alerts: `bazarr.signalr` (warning when either is down, "Bazarr lost its live link to Sonarr"), `bazarr.health.<n>`
(warning per health item).

---

## 13. System (host metrics, Uptime Kuma) — feature `system`

Routes: `/system/**`, `/uptime`. All [member].

The host sampler runs every 5 s (always on) and keeps a ring buffer: 5 s resolution for 1 h, 1 min averages for 24 h.

### 13.1 `GET /system/host` (from the sampler; no upstream)
200 **HostMetrics** [system]:
```json
{"hostname": "Zenith", "cpu": {"model": "Intel(R) N100", "cores": 4, "percent": 12.5, "perCorePercent": [10.1, 15.0, 9.8, 15.1],
         "load1": 0.57, "load5": 0.89, "load15": 1.04, "packageTempC": 48.0, "coreTempsC": [46.0, 47.0, 48.0, 45.0]},
 "memory": {"totalBytes": 8059052032, "usedBytes": 5100000000, "availableBytes": 2959052032,
            "swapTotalBytes": 4026531840, "swapUsedBytes": 600000000},
 "uptimeSeconds": 10289,
 "storage": [{"mount": "/volume1", "totalBytes": 7904532574208, "usedBytes": 3873220961362, "freeBytes": 4031311612846, "usedPercent": 49.0}],
 "raid": [{"device": "md1", "level": "raid0", "state": "active", "members": ["sda2", "sdb2"], "redundant": false, "healthy": true}],
 "network": [{"interface": "eth0", "rxBps": 120000, "txBps": 2400000, "rxTotalBytes": 1, "txTotalBytes": 2},
             {"interface": "tailscale0", "rxBps": 0, "txBps": 0, "rxTotalBytes": 0, "txTotalBytes": 0}],
 "diskIo": {"readBps": 0, "writeBps": 5000000},
 "sampledAt": "2026-11-08T09:00:00Z", "sources": {"temperature": true, "hostNetwork": true}}
```
Sources (integrations/system.md §4): `/proc/stat` (busy = user+nice+system+irq+softirq+steal; total = busy+idle+iowait),
`/proc/meminfo` (used = MemTotal − MemAvailable), `/proc/loadavg`, `/proc/uptime`, `/proc/cpuinfo`, `/proc/mdstat`,
`/proc/diskstats` `dm-0` (sectors × 512) — all from the container's **own** `/proc` (host-global). hwmon with
`name == coretemp` (`temp1_input` package, `temp2..5` cores) under `HOST_SYS/class/hwmon` (`HOST_SYS=/sys`, the
container's own sysfs; no bind mount). The entries `hwmon0`, `hwmon1` are **relative symlinks**
(`../../devices/platform/coretemp.0/hwmon/hwmon1`): the sampler lists the directory, resolves each entry with
`Link(entry).resolveSymbolicLinksSync()` inside a try/catch (a dangling link is skipped, never fatal), and reads
`name`/`tempN_input` from the resolved directory; the test fixture builds a temp tree with symlinked hwmon entries
(and one dangling link). `statvfs("/data")` via `dart:ffi` (it is on `/volume1`). Host network from `HOST_NET_DEV`
(`/host/proc/1/net/dev`: `eth0`, `tailscale0`; missing mount → `sources.hostNetwork: false` and `network: []`).
Fields that cannot be read are omitted and the matching `sources` flag is false.

### 13.2 `GET /system/history`
Query `metric=cpu|memory|temperature|netRx|netTx|diskRead|diskWrite`, `range=1h|24h` (default 1h).
200 **MetricSeries** `{"metric": string, "unit": "percent"|"bytes"|"celsius"|"bps", "points": [{"t": Instant, "v": double}]}`.

### 13.3 `GET /uptime` (cache 30 s)
Upstream `GET /api/status-page/{slug}` + `GET /api/status-page/heartbeat/{slug}` (no auth; beat `time` is UTC without a
zone marker; ordered oldest → newest).
200 **UptimeResponse**:
```json
{"title": "Zenith", "incident": {"title": string, "content": string, "style": string, "createdAt": Instant}?,
 "groups": [{"name": "Media", "monitors": [{"id": 2, "name": "jellyfin", "type": "docker", "status": "up",
     "lastBeatAt": Instant?, "uptime24h": 0.9957, "pingMs": null, "beats": [{"t": Instant, "status": "up"}]}]}],
 "counts": {"up": 19, "down": 0, "pending": 1, "maintenance": 0, "unknown": 1}}
```
`status: "down"|"up"|"pending"|"maintenance"|"unknown"` (0/1/2/3; no beats → unknown). `beats`: last 30.
`uptime24h` from `uptimeList["<id>_24"]`. Groups ordered by `weight`.

### 13.4 Dashboard card `system` — **SystemCard** (cache 5 s)
`{"cpuPercent": double?, "packageTempC": double?, "memUsedBytes": int, "memTotalBytes": int, "uptimeSeconds": int, "volume": {"totalBytes": int, "usedBytes": int, "usedPercent": double}?, "raid": {"level": string, "state": string, "redundant": bool, "healthy": bool}?, "net": {"rxBps": int, "txBps": int, "tailscaleActive": bool}?, "monitors": {"up": int, "down": int, "pending": int, "total": int}?, "cpuSparkline": double[] (last 60 samples, 5 s apart)}`.
Alerts: `raid.degraded` (critical when any md device is not `active`), `raid.noRedundancy` (info, dismissible, "Storage
is RAID0: a single disk failure loses all data"), `host.temperature` (warning above `alerts.cpuTempWarnC`),
`host.volume` (warning above `alerts.volumeUsedWarnPercent`), `uptime.down.<id>` (error per monitor whose latest beat
is down, route `/system`), `uptime.incident` (warning when an incident is pinned).

---

## 14. Media (Jellyfin, Jellystat, Audiobookshelf, Kavita) — feature `media`

Routes: `/media/**`. Reads [member]; writes [admin].

### 14.1 DTOs [media]
**NowPlayingSession**:
```json
{"id": "eb96632f72ed3854021c5466f350a158", "userName": "Zenith Greyrat", "userId": "8bed8d8c...",
 "client": "Jellyfin Android TV", "deviceName": "Xiaomi TV Box", "itemId": "d078a144bb4719f0e6babd8d90ba0b11",
 "itemType": "episode", "title": "A Spark. To Pierce the Dark.", "seriesName": "Desperate Housewives",
 "seasonNumber": 5, "episodeNumber": 18, "year": null, "runtimeSeconds": 2583, "positionSeconds": 165,
 "progress": 0.064, "paused": false, "playMethod": "directPlay",
 "transcode": {"videoCodec": "h264", "audioCodec": "aac", "container": "ts", "hwAccel": "qsv", "reasons": ["VideoCodecNotSupported"],
               "bitrate": 8000000, "completionPercent": 12.0, "videoDirect": false, "audioDirect": true, "width": 1920, "height": 1080}?,
 "imagePath": ImagePath, "remoteAddress": "192.168.10.160"?, "jellyfin": ExternalLink, "canControl": true}
```
`itemType: "movie"|"episode"|"audio"|"other"`, `playMethod: "directPlay"|"directStream"|"transcode"|"unknown"`,
`reasons` raw strings (unknown values kept). `imagePath`: episode Primary, else series Primary via `SeriesId` +
`SeriesPrimaryImageTag`. `remoteAddress` only for admins. Sessions without `NowPlayingItem`, and clients
`Homepage`, `Seerr`, `YAMS Hub` are dropped. Ticks ÷ 10 000 000 = seconds.

Every Jellyfin `ExternalLink` in this section is built with `ctx.jellyfin.itemLink(itemId, serverId)` and
`ctx.jellyfin.serverId()` (core, shared with requests and `/server`); user-scoped calls use `ctx.jellyfin.adminUserId()`.

**MediaItem**: `{"id": string, "type": "movie"|"series"|"season"|"episode"|"audio"|"book"|"other", "title": string, "subtitle": string?, "year": int?, "imagePath": ImagePath?, "addedAt": Instant?, "newEpisodeCount": int?, "progress": double?, "jellyfin": ExternalLink?}`.

### 14.2 Now playing and sessions
| Method + path | Role | Body | Upstream | Response |
|---|---|---|---|---|
| `GET /media/now-playing` | member | – | `GET /Sessions?activeWithinSeconds=960` (cache 5 s) | **NowPlaying** `{"sessions": NowPlayingSession[], "transcoding": int, "hwAccel": string? (from `/System/Configuration/encoding`, cache 1 h)}` |
| `POST /media/sessions/{id}/playback` | admin | `{"command": "pause"\|"unpause"\|"stop"}` | `POST /Sessions/{id}/Playing/Pause\|Unpause\|Stop` | 204 |
| `POST /media/sessions/{id}/message` | admin | `{"text": string (1..200), "header": string? (default "YAMS Hub"), "timeoutMs": int? (default 10000)}` | `POST /Sessions/{id}/Message {Header, Text, TimeoutMs}` | 204 |

### 14.3 Jellyfin library
`GET /media/jellyfin` (cache 60 s) → **JellyfinOverview**:
`{"server": {"name": string, "version": string, "hwAccel": string?}, "counts": {"movies": int, "series": int, "episodes": int, "songs": int, "albums": int, "books": int}, "libraries": [{"id": string, "name": string, "type": "movies"|"tvshows"|"music"|"books"|"other", "sizeBytes": int?, "files": int?, "itemCount": int?, "refreshing": bool}], "recentlyAdded": MediaItem[] (16), "continueWatching": MediaItem[] (for the caller's linked Jellyfin user; empty if none), "nextUp": MediaItem[]}`.
Upstream: `/System/Info/Public`, `/Items/Counts`, `/Library/VirtualFolders`, Jellystat `/stats/getLibraryMetadata`
(sizes; ignore failures), `/Items?recursive=true&includeItemTypes=Movie,Episode&sortBy=DateCreated&sortOrder=Descending&limit=16&fields=DateCreated,ProviderIds`
(or `/Items/Latest?userId={admin}&parentId=<lib>` per library), `/UserItems/Resume?userId={linked}&limit=12`,
`/Shows/NextUp?userId={linked}&limit=12`.

`POST /media/jellyfin/library/refresh` [admin] → `POST /Library/Refresh` → 202 `{"queued": true}`.

### 14.4 Watch statistics (Jellystat)
`GET /media/stats` query `days=7|30|90|365` (default 30). Cache 5 min.
200 **WatchStats**:
```json
{"days": 30, "libraries": [{"id": "f137...", "name": "Movies"}],
 "viewsOverTime": [{"date": "2026-11-01", "plays": {"f137...": 1}, "durationSeconds": {"f137...": 5400}}],
 "byWeekday": [{"day": "monday", "plays": 3}], "byHour": [{"hour": 21, "plays": 2}],
 "playMethods": [{"method": "directPlay", "count": 1}],
 "topMovies": [{"id": string, "name": string, "plays": int, "durationSeconds": int, "imagePath": ImagePath?}],
 "topSeries": [...], "popularSeries": [{"id": string, "name": string, "uniqueViewers": int, "imagePath": ImagePath?}],
 "topUsers": [{"userId": string, "name": string, "plays": int}], "topClients": [{"client": string, "plays": int}],
 "topLibraries": [{"id": string, "name": string, "plays": int}],
 "totals": {"plays": int, "durationSeconds": int}}
```
Upstream (parallel; any failing piece becomes empty and `partial: true` is added): `GET /stats/getViewsOverTime?days`
(keys are library **names** → map to ids via the `libraries` list; `Key` date strings like "Nov 01, 2026" parsed),
`getViewsByDays`, `getViewsByHour`, `POST getPlaybackMethodStats {days}`, `POST getMostViewedByType {days, type: "Movie"|"Series"}`
(days required), `POST getMostPopularByType {days, type: "Series"}`, `POST getMostActiveUsers {days}`,
`POST getMostUsedClient {days}`, `POST getMostViewedLibraries {days}`. Images via `/img/jellyfin/{Id}/Primary`
(Jellystat `PrimaryImageHash` is a BlurHash; ignored).

| Method + path | Query | Upstream | Response |
|---|---|---|---|
| `GET /media/stats/users` | – | `GET /stats/getAllUserActivity` (cache 5 min) | `ItemList<{"userId": string, "name": string, "totalPlays": int, "totalWatchSeconds": int, "lastSeenAt": Instant?, "lastWatched": string?, "lastClient": string?, "avatarPath": ImagePath?}>` (**WatchUser**; `LastSeen` interval converted to an instant = now − interval) |
| `GET /media/stats/history` | `page`, `pageSize` (max 50), `userId` (admins only; **members are always scoped to their own linked `jellyfinUserId`** and get an empty page when unlinked; a member-supplied `userId` is ignored) | `GET /stats/getPlaybackActivity?size&page&sort=ActivityDateInserted&desc=true[&filters=[{"field":"UserId",...}]]` (URL-encoded JSON) | `PagedList<{"id": string, "userName": string, "title": string, "seriesName": string?, "client": string, "device": string, "playMethod": string, "durationSeconds": int, "at": Instant, "imagePath": ImagePath?}>` (**PlaybackRecord**; episode image from `EpisodeId`) |

Jellystat `/api/keys`, `/api/getconfig`, `/sync/*`, `/backup/*`, `/api/stopTask` are never called.

### 14.5 Audiobookshelf
`GET /media/audiobooks` (cache 60 s; personalized shelves not used, `discover` is random) → **AudiobooksOverview**:
`{"version": string?, "libraries": [{"id": string, "name": string, "mediaType": "book"|"podcast", "items": int, "authors": int, "durationSeconds": int, "sizeBytes": int}], "continueListening": [{"id": string, "title": string, "author": string?, "narrator": string?, "coverPath": ImagePath, "progress": double, "currentTimeSeconds": int, "durationSeconds": int, "lastUpdateAt": Instant?, "link": ExternalLink}], "recentlyAdded": [{"id": string, "title": string, "author": string?, "coverPath": ImagePath, "addedAt": Instant, "durationSeconds": int?, "link": ExternalLink}], "listening": {"todaySeconds": int, "totalSeconds": int, "last7Days": [{"date": Date, "seconds": int}]}, "library": ExternalLink}`.
Upstream: `/status`, `/api/libraries`, `/api/libraries/{id}/stats`, `/api/me/items-in-progress?limit=10` joined with
`/api/me` `mediaProgress` on `libraryItemId` (strip `token`, `email`), `/api/libraries/{id}/items?sort=addedAt&desc=1&limit=12&page=0&minified=1`,
`/api/me/listening-stats`. Times are epoch ms. Links: `{app: audiobookshelf, path: "/item/{id}"}`, library
`/library/{libraryId}`.

### 14.6 Kavita
`GET /media/books` (cache 60 s) → **BooksOverview**:
`{"auth": "ok"|"missingKey"|"rejected", "version": string?, "libraries": [{"id": int, "name": string, "type": "manga"|"comic"|"book"|"image"|"lightNovel"|"comicVine"|"unknown"}], "stats": {"series": int, "volumes": int, "chapters": int, "files": int, "sizeBytes": int}?, "recentlyAdded": BookSeries[], "onDeck": BookSeries[], "hint": string?, "library": ExternalLink}`
with **BookSeries** `{"id": int, "name": string, "libraryId": int, "libraryName": string?, "coverPath": ImagePath, "pages": int?, "pagesRead": int?, "format": "image"|"archive"|"epub"|"pdf"|"unknown", "link": ExternalLink}` (link path `/library/{libraryId}/series/{id}`).
Upstream (`x-api-key`): `/api/Server/server-info-slim`, `/api/Library/libraries`, `/api/Stats/server/stats`,
`POST /api/Series/recently-added-v2?PageNumber=1&PageSize=12` with body
`{"id":0,"name":null,"statements":[],"combination":1,"sortOptions":null,"limitTo":0}`,
`POST /api/Series/on-deck?PageNumber=1&PageSize=12&libraryId=0`. Always send `PageSize`.
`auth: missingKey` when `KAVITA_API_KEY` is empty (200 with empty lists, not 503), `rejected` on 401. `hint` when there
are 0 series: "Kavita found no series. It needs one folder per series, e.g. books/lightnovels/<Series>/<file>.epub".
Never call `POST /api/Account/login` (lockout risk).

### 14.7 Shelfmark (book and audiobook downloads)
`GET /media/shelfmark` (cache 30 s) → **ShelfmarkStatus**:
`{"status": "ok"|"degraded"|"down", "coordinator": "running"|"stopped"|"unknown", "queue": {"active": int, "queued": int, "awaitingPickup": int}, "requests": {"pending": int, "delivered": int, "failed": int, "cancelled": int, "rejected": int}, "added": {"ebook7d": int, "ebook30d": int, "audiobook7d": int, "audiobook30d": int, "total7d": int, "total30d": int}, "failed7d": int, "generatedAt": Instant?, "web": ExternalLink}`.
Upstream (no auth; Shelfmark runs `auth_mode: none`): `GET /api/health` (`{status, coordinator}`, 503 when the download
coordinator is stopped → `status: degraded`) and `GET /api/stats` (read-only SQLite counters:
`{added:{audiobook_7d,…}, errors:{failed_7d}, generated_at, queue:{active, awaiting_pickup, queued}, requests:{…}}`;
fixtures `system/shelfmark_health.json`, `system/shelfmark_stats.json`). `web`: `{app: shelfmark, path: "/"}`.
**Never call** `GET /api/status` (it writes delivery states and emits socket events as a side effect),
`GET /api/restart`, `GET /api/debug`, `GET /api/localdownload`, `GET /api/releases` / `GET /api/metadata/search`
(live searches against external sources), or any POST/PUT/DELETE (integrations/system.md §12). Book search and
download from the hub are v1.1 (ARCHITECTURE §11).

### 14.8 Launcher and dashboard
`GET /media/apps` (cache 30 s) → `ItemList<MediaApp>`, **MediaApp**:
`{"app": "jellyfin"|"audiobookshelf"|"kavita"|"seerr"|"shelfmark", "name": string, "status": "up"|"down"|"degraded"|"disabled", "version": string?, "headline": string ("179 movies · 54 shows · 1,694 episodes"; Shelfmark: "2 downloading · 1 queued · 5 added this week"), "web": ExternalLink, "route": string (app route with the details, e.g. "/media/audiobooks", "/media/shelfmark"; Seerr: "/requests")}`.
`status`/`version` come from `ctx.health.report()` (core), the headline from the feature's own cached overviews.
This is the rich tile list for the media apps; the plain launcher for every web UI is core (ARCHITECTURE §7.9).

Dashboard card `media` — **MediaCard** (cache 10 s for now playing, 60 s for the rest):
`{"nowPlaying": NowPlayingSession[] (max 4), "transcoding": int, "counts": {"movies": int, "series": int, "episodes": int}?, "audiobooks": {"items": int, "inProgress": int}?, "books": {"series": int, "auth": string}?, "shelfmark": {"active": int, "queued": int, "failed7d": int}?, "recentlyAdded": MediaItem[] (max 8)}`.
Alerts: `kavita.auth` (warning when `rejected` or `missingKey`, "Kavita needs an Auth Key", route `/media/books`, which
shows the setup card), `jellyfin.restart` (info when `HasPendingRestart`, "Jellyfin needs a restart", route
`/containers/jellyfin`, where the restart action lives behind a confirm), `shelfmark.coordinator` (warning when the
coordinator is stopped, route `/media/shelfmark`).

---

## 15. Route ownership

| Prefix | Owner |
|---|---|
| `/ping`, `/auth/**`, `/admin/**`, `/server`, `/health`, `/jobs/**`, `/img/**`, `/dashboard` | core-gateway |
| `/discover/**`, `/search`, `/titles/**`, `/requests/**`, `/issues/**` | requests |
| `/library/**` | library |
| `/activity/**`, `/torrents/**`, `/transfer/**`, `/vpn` | activity |
| `/calendar` | calendar |
| `/indexers/**` | indexers |
| `/containers/**`, `/updates/**`, `/maintenance/**` | containers |
| `/subtitles/**` | subtitles |
| `/system/**`, `/uptime` | system |
| `/media/**` | media |

Any route not listed in this document returns `404 not_found` (JSON, also for method mismatches). Feature slices may
add read-only helper routes under their own prefix if a screen needs them, and must document them in their slice
summary. Every route exists under both `/api/v1` (bearer) and `/yh/api/v1` (cookie).
