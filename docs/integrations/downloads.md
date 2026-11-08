# YAMS Hub integration spec: downloads (qBittorrent, Gluetun, Prowlarr, Bazarr)

Status: probed live on Zenith on 2026-11-08 using **GET requests only** (plus the qBittorrent login).
I did not call any write endpoint. Request shapes for writes come from the source and docs that each
service ships: the qBittorrent 5.3.0 WebUI JavaScript served by the container, the Prowlarr 2.7.0
frontend source map (`/app/prowlarr/bin/UI/*.js.map`), and Bazarr 1.6.2's `swagger.json` and Python
API sources inside the container.

Fixtures are in `fixtures/downloads/` (see the [fixture index](#7-fixture-index)). Secrets, the VPN
exit IP and peer IPs are redacted there. Field names and structure match the live responses exactly.

---

## 0. Topology, versions, auth summary

The gateway container `yams-hub` must join the external Docker network `yams_network` (172.28.0.0/24).
Use the hostnames below. Do not use host-published ports from inside the gateway.

| Service | Version (live) | Base URL from gateway | Auth | Notes |
|---|---|---|---|---|
| qBittorrent | v5.3.0, WebAPI 2.16.2, libtorrent 2.1.2.0 | `http://gluetun:8081/api/v2` (or the pinned IP `http://172.28.0.18:8081`) | Cookie session `QBT_SID_8081`, from `POST /auth/login` | qBittorrent runs in gluetun's network namespace (`network_mode: container:gluetun`), so it is reached through the **gluetun** hostname. Both forms tested from a container on `yams_network`. |
| Gluetun control server | qmcgaw/gluetun v3.40.0 | `http://gluetun:8000` | none (only 2 routes allowed; every other route returns `401 Unauthorized`) | `config/gluetun/auth/config.toml` role `readonly-status` |
| Prowlarr | 2.7.0.5723 (linuxserver, .NET 8) | `http://prowlarr:9696/api/v1` | header `X-Api-Key: <key>` (`?apikey=` also works) | key: `<ApiKey>` in `/volume1/mediashare/config/prowlarr/config.xml` |
| Bazarr | 1.6.2 (Sonarr 4.0.20, Radarr 6.4.4 linked) | `http://bazarr:6767/api` | header `X-API-KEY: <key>` (case-insensitive; `?apikey=` and form field `apikey` also work) | key: `HOMEPAGE_VAR_BAZARR_KEY` |

Unauthenticated liveness probes, useful for the gateway's own health page:
- Prowlarr `GET /ping` returns `{"status":"OK"}` (no auth).
- Bazarr `GET /api/system/ping` returns `{"status": "OK"}` (no auth).
- qBittorrent: no unauthenticated ping. Any `/api/v2/*` call without a cookie returns `403 Forbidden`, which is enough to show the WebUI is up.
- Gluetun: `GET /v1/openvpn/portforwarded` (no auth).

---

## 1. qBittorrent 5.3.0 (WebAPI 2.16.2)

### 1.1 Authentication and session

```
POST /api/v2/auth/login
Content-Type: application/x-www-form-urlencoded
username=<HOMEPAGE_VAR_QBIT_USER>&password=<HOMEPAGE_VAR_QBIT_PASS>
```

| Result | Status | Body | Notes |
|---|---|---|---|
| success | **204** (empty) | — | `Set-Cookie: QBT_SID_8081=<sid>; HttpOnly; SameSite=Lax; expires=<now+1h>; path=/` |
| bad credentials | **401** | `Unauthorized` | 4.x returned `200 Fails.`. Do not test for the string `Ok.`; test the status code. |
| bad `Origin` header | 401 | | CSRF protection is on (`web_ui_csrf_protection_enabled: true`). **Do not send `Origin` or `Referer`** from the gateway, or set them to the exact qBittorrent origin. Dart's `http`/`HttpClient` sends neither by default. |

Gotchas, all observed:
- **The cookie name is `QBT_SID_8081`, not `SID`.** A request with `Cookie: SID=<sid>` gets 403. The suffix is the WebUI port. Parse the name from `Set-Cookie` and don't hard-code it.
- **Session lifetime:** `web_ui_session_timeout: 3600`, an idle timeout. When it expires, every call returns **403**. On 403, log in once and retry once.
- **Ban:** `web_ui_max_auth_fail_count: 5` and `web_ui_ban_duration: 3600`. Five bad logins ban the *gateway's IP* for one hour, and that would also lock out Homepage. **Never retry a 401 login in a loop.** Surface "qBittorrent credentials rejected" and back off.
- `web_ui_secure_cookie_enabled: true` has no effect over plain HTTP: the cookie came back without `Secure`. Keep the internal URL on `http://`.
- Host header validation is on with `web_ui_domain_list: "*"`, so any Host is accepted. If you keep a cookie jar, bind it to the same host you call. Logging in via `172.28.0.18` and then calling `gluetun:8081` fails with 403 only because the jar doesn't send the cookie.
- Homepage logs in on **every** poll. The qBittorrent log fills with `WebAPI login success. IP: ::ffff:172.28.0.1`. The gateway should keep **one long-lived session** and re-login only on 403.
- `bypass_local_auth: true` is needed by the gluetun port hook that calls `127.0.0.1`. It does not apply to the gateway, which connects from a different IP. Subnet bypass is off (`bypass_auth_subnet_whitelist_enabled: false`).
- An **API key** feature exists in this version: preference `web_ui_api_key`, endpoints `app/rotateAPIKey` and `app/deleteAPIKey`, and an "API Key" box in Preferences > WebUI. No key is set (`web_ui_api_key: ""`). I did not verify the request header for key auth because no key exists. The cookie flow is the supported path for now. Treat API-key auth as a later improvement once a key is generated in the WebUI.
- `POST /api/v2/auth/logout` exists (GET returns 405). The gateway normally never needs it.

### 1.2 Endpoint existence check (v5 renames)

POST-only endpoints return **405** to a GET. Removed endpoints return **404**. I used this to check the v5
renames without changing state. The parameterless GETs below would be no-ops even if they were accepted.

| Endpoint | GET result | Meaning |
|---|---|---|
| `torrents/stop`, `torrents/start` | 405 | **exist (POST)**, the v5 names |
| `torrents/pause`, `torrents/resume` | **404** | **removed in 5.x; do not use** |
| `torrents/delete`, `setShareLimits`, `setCategory`, `addTags`, `removeTags`, `setTags`, `createCategory`, `editCategory`, `removeCategories`, `recheck`, `reannounce`, `setForceStart`, `topPrio`, `increasePrio`, `filePrio`, `rename`, `setLocation`, `setComment`, `setDownloadLimit`, `setUploadLimit`, `torrents/add` | 405 | exist (POST) |
| `transfer/toggleSpeedLimitsMode`, `transfer/setSpeedLimitsMode`, `transfer/setDownloadLimit`, `transfer/setUploadLimit` | 405 | exist (POST) |
| `torrents/count` | 200 `22` | exists (GET, text) |
| `transfer/getSpeedLimits` | 200 JSON | **new**: all four global limits in one call |

The WebUI JS also uses `transfer/setSpeedLimits`, `transfer/pauseSession`, `transfer/resumeSession`,
`torrents/setAutoManagement`, `torrents/toggleSequentialDownload`, `torrents/toggleFirstLastPiecePrio`,
`torrents/setSuperSeeding`, `torrents/removeTrackers`, `torrents/deleteTags`, `torrents/fetchMetadata`,
`torrents/parseMetadata`, `clientdata/load|store`.

Version detection: `GET /api/v2/app/version` returns `v5.3.0` and `GET /api/v2/app/webapiVersion`
returns `2.16.2`, both **text/plain**. `GET /api/v2/app/buildInfo` returns JSON
`{"bitness":64,"boost":"1.92.0","libtorrent":"2.1.2.0","openssl":"4.1.0","platform":"linux","qt":"6.12.0","zlib":"1.3.2"}`.
Refuse to start the qBittorrent module, or fall back to `pause`/`resume`, if webapiVersion < 2.11.0
(the v5 rename).

### 1.3 Feature: live torrent list (recommended: `sync/maindata`)

```
GET /api/v2/sync/maindata?rid=<last rid, 0 for the first call>
Cookie: QBT_SID_8081=<sid>
```
Response is `application/json`. Measured ~3.5 ms. A full snapshot for 22 torrents is 64 KB, or **7.5 KB with
`Accept-Encoding: gzip`** (supported; Dart's `HttpClient` decompresses automatically).

Top-level keys on a full update: `rid`, `full_update: true`, `server_state`, `torrents` (an **object keyed
by hash**, not an array), `categories` (object keyed by name), `tags` (array of strings), `trackers`
(object: tracker URL → array of hashes).

A delta (`rid=N`) contains **only changed keys**: `rid`, partial `server_state`, and partial `torrents`
where each hash carries only the changed fields. Optional removal arrays: `torrents_removed`,
`categories_removed`, `tags_removed`, `trackers_removed`. Real delta excerpt
(`fixtures/downloads/qbittorrent_sync_maindata_delta.json`):

```json
{"rid":2,
 "server_state":{"alltime_dl":8030115506827,"alltime_ul":7409991435409,"up_info_speed":906283, "...":"..."},
 "torrents":{"e66aac4c7d8a4f813a4e5b3a63c1bb52beee342e":{"connections_count":40,"eta":32732,"num_leechs":39,
   "ratio":0.4380794209597125,"upspeed":686561,"uploaded":15413602877, "...":"..."}}}
```

Merge algorithm (the same one the official WebUI uses in `client.js`):
1. `full_update == true`: replace all local state.
2. Otherwise deep-merge each `torrents[hash]` into the stored torrent, and merge `server_state` and `categories[name]` field by field.
3. Apply each `*_removed` array.
4. Store `rid` and send it on the next call.

Observed behaviour:
- `rid=0`, a missing `rid`, or an unknown `rid` (tested with 999999) all return `full_update: true`. A bad rid never errors.
- **rid is per session.** The sync state is attached to the cookie session. After a re-login (on a 403), restart from `rid=0`.
- `server_state.refresh_interval` = **1500** ms is the server's suggested poll interval. The WebUI uses `max(refresh_interval, 500)`.

**Recommendation:** the gateway runs **one** maindata poller, and only while at least one app client is
subscribed (for example over a WebSocket or SSE stream from the gateway). Poll every 1.5–2 s, hold the merged
state in memory, and push either snapshots or its own deltas to phones. Do **not** forward qBittorrent's `rid`
to phones, because many phones would share one session's rid. For a one-off list, such as a widget or a
background refresh, use `torrents/info` (section 1.4). When nobody is watching, stop polling.

`server_state` fields that matter (types from the live sample):

| field | type | meaning |
|---|---|---|
| `dl_info_speed`, `up_info_speed` | int B/s | current global speeds |
| `dl_info_data`, `up_info_data` | int bytes | session totals |
| `alltime_dl`, `alltime_ul` | int bytes | lifetime totals (maindata only) |
| `global_ratio` | **string** `"0.92"` | parse as double |
| `dl_rate_limit`, `up_rate_limit` | int B/s | **currently effective** limit (alt limit when alt mode is on); 0 = unlimited |
| `use_alt_speed_limits` | bool | alternative ("turtle") mode on |
| `connection_status` | string | `connected` \| `firewalled` \| `disconnected` |
| `dht_nodes`, `total_peer_connections` | int | |
| `free_space_on_disk` | int bytes | free space of the default save path (4.05 TB here) |
| `queueing` | bool | queueing enabled (it is: max 10 DL / 3 UP / 20 total active) |
| `session_state` | bool | **true = whole session paused** (`transfer/pauseSession`); the WebUI shows "[PAUSED]" |
| `last_external_address_v4` | string | VPN exit IP (redacted in fixtures) |
| `read_cache_hits`, `read_cache_overload`, `write_cache_overload` | **string** | numbers encoded as strings |
| `refresh_interval` | int ms | suggested poll interval |

`GET /api/v2/transfer/info` returns the small subset (`connection_status, dht_nodes, dl_info_data,
dl_info_speed, dl_rate_limit, last_external_address_v4, last_external_address_v6, up_info_data,
up_info_speed, up_rate_limit`). Use it for a cheap dashboard tile.

### 1.4 `GET /api/v2/torrents/info` (one-shot list with server-side filtering)

Query params (all optional):

| param | values | verified behaviour |
|---|---|---|
| `filter` | `all, downloading, seeding, completed, stopped, running, active, inactive, stalled, stalled_uploading, stalled_downloading, checking, moving, errored` | all of these work (table below). **`paused`, `resumed` and any unknown value are silently ignored and return ALL torrents.** The v4 names are not rejected. Validate the value in the gateway. |
| `category` | name; `""` = uncategorised | `category=` returned 0 here (every torrent is `tv-sonarr`) |
| `tag` | name; `""` = untagged | `tag=Keep` → 0, `tag=` → 22 |
| `sort` | any torrent field name, e.g. `added_on`, `name`, `progress`, `dlspeed`, `upspeed`, `eta`, `ratio`, `size` | an invalid field returns **400 `'sort' parameter is invalid`** (text/plain) |
| `reverse` | `true/false` | |
| `limit`, `offset` | int | offset/limit pagination over the sorted list |
| `hashes` | `h1\|h2\|...` | |
| `private` | `true/false` | works (0 private torrents here) |
| `includeTrackers` | `true` | adds a `trackers` array (same shape as `torrents/trackers`) to each torrent |
| `includeFiles` | `true` | adds a `files` array (same shape as `torrents/files`) to each torrent. Expensive; use only with `hashes=` |

Filter semantics, from the WebUI's `applyFilter` and confirmed with live counts (22 torrents):
`downloading` = state contains `DL` (or is `downloading`): 0. `seeding` = `uploading|forcedUP|stalledUP|queuedUP|checkingUP`: 12.
`completed` = state contains `UP`: 22. `stopped` = contains `stopped`: 10. `running` = not stopped: 12.
`active`/`inactive` = (dlspeed>0 or upspeed>0): 3/19. `stalled` = `stalledUP|stalledDL`: 1.
`checking` = `checkingUP|checkingDL|checkingResumeData`. `errored` = `error|unknown|missingFiles`.

Measured: full list (22) 51 KB in ~3 ms. Response is a JSON array of torrent objects.

### 1.5 Torrent object (5.3.0): fields that matter

Full real objects are in `qbittorrent_torrents_info.json`. Types:

| field | type | notes |
|---|---|---|
| `hash` | string (40 hex) | primary key; also `infohash_v1`, `infohash_v2` (`""` for v1-only) |
| `name` | string | |
| `state` | string enum | see 1.6 |
| `progress` | double 0..1 | |
| `size` / `total_size` | int bytes | `size` = selected files only |
| `amount_left`, `completed`, `downloaded`, `uploaded`, `downloaded_session`, `uploaded_session` | int bytes | |
| `dlspeed`, `upspeed` | int B/s | |
| `eta` | int seconds | **8640000 = infinity/unknown** (seen on all `queuedUP`). While seeding, eta = time until the share limit is reached. |
| `ratio` | double | |
| `num_seeds`, `num_leechs` | int | connected peers; `num_complete`/`num_incomplete` = swarm totals from trackers |
| `category` | string | `""` = none |
| `tags` | **string**, comma-separated (`""` = none) | not an array. Split on `", "`/`","` and trim. |
| `added_on`, `completion_on`, `last_activity`, `seen_complete` | int unix seconds | `-1` = never |
| `creation_date` | int | `-1` = unknown |
| `save_path`, `content_path`, `root_path`, `download_path` | string | container paths (`/data/downloads/torrents/...`) |
| `priority` | int | queue position; **0 = not in queue** (all seeds here) |
| `force_start`, `seq_dl`, `f_l_piece_prio`, `super_seeding`, `auto_tmm`, `private`, `has_metadata` | bool | |
| `dl_limit`, `up_limit` | int B/s | **0 = unlimited** in `torrents/info`. Note that `torrents/properties` reports **-1** for unlimited. |
| `ratio_limit`, `seeding_time_limit`, `inactive_seeding_time_limit` | number | **-2 = use global, -1 = no limit**, otherwise ratio / minutes |
| `max_ratio`, `max_seeding_time`, `max_inactive_seeding_time` | number | effective limits after resolving globals (`max_ratio: 1` here) |
| `share_limit_action` | string | `Default \| Stop \| Remove \| RemoveWithContent \| EnableSuperSeeding` (new in this API version) |
| `share_limits_mode` | string | `Default \| MatchAny \| MatchAll` (new) |
| `popularity` | double | new in 5.x |
| `availability` | double | `-1` when seeding |
| `tracker` | string | current working tracker URL |
| `trackers_count` | int | |
| `has_tracker_error`, `has_tracker_warning`, `has_other_announce_error` | bool | new; useful for an "issues" badge |
| `magnet_uri` | string | |
| `comment`, `created_by` | string | |
| `time_active`, `seeding_time` | int seconds | |
| `reannounce` | int seconds | seconds to next announce |

### 1.6 States in v5 and how to group them in the UI

From the WebUI state-icon mapping in `dynamicTable.js`:

| UI group | raw states |
|---|---|
| Downloading | `downloading`, `forcedDL`, `metaDL`, `forcedMetaDL` |
| Seeding | `uploading`, `forcedUP` |
| Stalled | `stalledDL`, `stalledUP` |
| Stopped (v5, formerly "paused") | `stoppedDL`, `stoppedUP` |
| Queued | `queuedDL`, `queuedUP` |
| Checking | `checkingDL`, `checkingUP`, `queuedForChecking`, `checkingResumeData` |
| Moving | `moving` |
| Error | `error`, `missingFiles`, `unknown` |

States seen live: `uploading` 3, `queuedUP` 8, `stalledUP` 1, `stoppedUP` 10. **There are no downloading
torrents in the fixtures.** Parsers must handle every state above and should map an unknown string to
"Unknown" rather than throw.

Why so many `stoppedUP`: the global share limit is `max_ratio_enabled: true, max_ratio: 1, max_ratio_act: 0`
(0 = stop). Every stopped torrent has ratio ≈ 1.000x. That is expected, not an error.

### 1.7 Speed limits and alternative mode

| need | call | response |
|---|---|---|
| is alt mode on? | `GET /api/v2/transfer/speedLimitsMode` | text `1` (on) / `0` (off) |
| all 4 global limits | `GET /api/v2/transfer/getSpeedLimits` | `{"alt_dl_limit":10240000,"alt_up_limit":10240000,"dl_limit":0,"up_limit":0}` (B/s, 0 = unlimited) |
| effective limits | `GET /api/v2/transfer/downloadLimit` / `uploadLimit` | text `10240000` (reflects the alt limit while alt mode is on) |
| toggle alt mode | `POST /api/v2/transfer/toggleSpeedLimitsMode` (no body) | 200 |
| set alt mode explicitly | `POST /api/v2/transfer/setSpeedLimitsMode` form `mode=0\|1` | 200. **Prefer this over toggle**: it is idempotent when two phones tap at once. |
| set all 4 limits | `POST /api/v2/transfer/setSpeedLimits` form `up_limit=<B/s>&dl_limit=<B/s>&alt_up_limit=<B/s>&alt_dl_limit=<B/s>` | 200; shape from `views/globalspeedlimits.html` (sends all four; KiB × 1024) |
| set normal global DL/UL only | `POST /api/v2/transfer/setDownloadLimit` / `setUploadLimit` form `limit=<B/s>` | 200 |
| per-torrent limits | `POST /api/v2/torrents/setDownloadLimit` / `setUploadLimit` form `hashes=h1\|h2&limit=<B/s>` | 200 |

**Gotcha: the speed scheduler is enabled.** `scheduler_enabled: true`, alt limits 08:00–17:00 every day
(`scheduler_days: 0`), container local time Africa/Johannesburg. A manual toggle is overridden at the next
schedule boundary. Show "Scheduled 08:00–17:00" next to the switch, using `app/preferences` →
`scheduler_enabled`, `schedule_from_hour/min`, `schedule_to_hour/min`, `scheduler_days`.

### 1.8 Torrent detail screen

| need | call | notes |
|---|---|---|
| general | `GET /api/v2/torrents/properties?hash=<h>` | Fields include `save_path, total_size, piece_size, pieces_have, pieces_num, share_ratio, seeding_time, time_elapsed, eta, dl_speed, dl_speed_avg, up_speed, up_speed_avg, total_downloaded, total_uploaded, total_wasted, peers, peers_total, seeds, seeds_total, nb_connections, addition_date, completion_date, last_seen, reannounce, popularity, is_private, has_metadata, comment`. Here `dl_limit`/`up_limit` use **-1** for unlimited. Missing `hash` → 400 `Missing required parameters: hash`; unknown hash → **404 `Not Found`** (text). |
| files | `GET /api/v2/torrents/files?hash=<h>` (optional `indexes=0\|3`) | array of `{index, name (relative path with "/"), size, progress, priority, is_seed?, piece_range:[a,b], availability}`. `is_seed` is present only on some entries. Priority: 0 = do not download, 1 = normal, 6 = high, 7 = max. Unknown hash → 404. |
| trackers | `GET /api/v2/torrents/trackers?hash=<h>` | array. The first three pseudo-entries are `** [DHT] **`, `** [PeX] **` and `** [LSD] **` (tier −1). Real trackers carry `url, tier, status, msg, num_peers, num_seeds, num_leeches, num_downloaded, updating, min_announce, next_announce` **plus a new `endpoints[]`** array, one per local interface, with `name` like `10.80.0.2:36681`, `bt_version`, and a per-endpoint `status`/`msg`. Status: 0 disabled, 1 not contacted, 2 working, 3 updating, 4 not working, 5 tracker error (v5), 6 unreachable (v5). The IPv6 tun0 endpoint always shows `status 6 "skipping tracker announce (unreachable)"`. That is normal noise; hide endpoints and use the top-level `status`. |
| peers (optional) | `GET /api/v2/sync/torrentPeers?hash=<h>&rid=0` | `{full_update, peers:{"ip:port":{client, country, country_code, dl_speed, up_speed, progress, flags, flags_desc, connection, ...}}, rid, show_flags}`. Same rid/delta model as maindata. Low value on a phone; optional. |
| piece map | `GET /api/v2/torrents/pieceStates?hash=<h>` | int array (0/1/2), 33,533 entries for a 35 GB torrent. **Too big for mobile; don't proxy it.** |

### 1.9 Categories and tags

- `GET /api/v2/torrents/categories` returns an object keyed by name:
  `{"tv-sonarr":{"name":"tv-sonarr","savePath":"","download_path":null,"ratio_limit":-2,"seeding_time_limit":-2,"inactive_seeding_time_limit":-2,"share_limit_action":"Default","share_limits_mode":"Default"}, ...}`
  The live categories are `books, lidarr, radarr, tv-sonarr`. `savePath: ""` = default path. `download_path: null` = inherit.
  Sonarr uses `tv-sonarr` and Radarr uses `radarr`. **Don't let the app rename or delete these**; mark them read-only in the UI.
- `GET /api/v2/torrents/tags` returns `["Keep","Obsolete"]`. **`Keep` is meaningful: decluttarr never removes a torrent tagged `Keep`.** Expose it as a one-tap "Protect" toggle.

### 1.10 Write actions (shapes verified from the WebUI source; NOT called)

All are `POST`, `Content-Type: application/x-www-form-urlencoded` (or multipart for `add`), with the session
cookie. Success = **HTTP 200**, usually with an empty body. `hashes` is pipe-separated (`h1|h2`) or the
literal `all`. Booleans are the strings `true`/`false`. Failure modes: 400 missing or invalid parameter (text body
names it), 403 session expired, 404 unknown torrent or category, 409 conflict (for example creating a category that exists,
or an invalid name/path; the body text is the reason and the WebUI shows it verbatim).

| app action | endpoint | body |
|---|---|---|
| Stop (was "pause") | `torrents/stop` | `hashes=<h\|h>` |
| Start (was "resume") | `torrents/start` | `hashes=<h\|h>` |
| Force start | `torrents/setForceStart` | `hashes=..&value=true\|false` |
| Delete torrent only | `torrents/delete` | `hashes=..&deleteFiles=false` |
| Delete torrent + data | `torrents/delete` | `hashes=..&deleteFiles=true`. **`torrent_content_remove_option: "Delete"`, so files are deleted permanently, not moved to trash.** Use a strong confirm in the app. |
| Recheck / Reannounce | `torrents/recheck` / `torrents/reannounce` | `hashes=..` |
| Share limits | `torrents/setShareLimits` | `hashes=..&ratioLimit=<float>&seedingTimeLimit=<min>&inactiveSeedingTimeLimit=<min>&shareLimitAction=<Default\|Stop\|Remove\|RemoveWithContent\|EnableSuperSeeding>&shareLimitsMode=<Default\|MatchAny\|MatchAll>`. For each limit, -2 = use global and -1 = unlimited. The WebUI always sends all five; "use global" = `-2,-2,-2,Default,Default`; "no limit" = `-1,-1,-1,Default,Default`. |
| Set category | `torrents/setCategory` | `hashes=..&category=<name or "" to clear>` |
| Create category | `torrents/createCategory` | `category=<name>&savePath=<path or "">`, optional `downloadPathEnabled=true\|false&downloadPath=<p>`, optional `ratioLimit, seedingTimeLimit, inactiveSeedingTimeLimit` (same -2/-1 convention) |
| Edit category | `torrents/editCategory` | same fields as create (the name cannot change); 404 if missing |
| Remove categories | `torrents/removeCategories` | `categories=<a\nb>` (newline-separated) |
| Add/remove tags | `torrents/addTags` / `torrents/removeTags` | `hashes=..&tags=Keep` (comma-separated) |
| Queue order | `torrents/topPrio`, `bottomPrio`, `increasePrio`, `decreasePrio` | `hashes=..` (409 if queueing is disabled; it is enabled here) |
| File priority | `torrents/filePrio` | `hash=<h>&id=<idx\|idx>&priority=0\|1\|6\|7` |
| Pause/resume whole session | `transfer/pauseSession` / `transfer/resumeSession` | no body; reflected in `server_state.session_state` |
| Add torrent (for Prowlarr manual grab, see 3.8) | `torrents/add` (multipart or urlencoded) | `urls=<magnet or http URL, newline-separated>` and/or file part(s) named `torrents`; optional `category`, `tags` (comma), `savepath`, **`stopped=true\|false`** (v5 name; `paused` is gone), `stopCondition=None\|MetadataReceived\|FilesChecked`, `addToTopOfQueue`, `sequentialDownload`, `firstLastPiecePrio`, `contentLayout=Original\|Subfolder\|NoSubfolder`, `upLimit`, `dlLimit`, `ratioLimit`, `seedingTimeLimit`, `autoTMM`, `rename`. 2xx = accepted; 415 = not a valid torrent. |

After a write, the next `sync/maindata` delta shows the change. The WebUI fires `updateMainData()` straight
after each action, so the gateway can likewise trigger an immediate poll.

**Cross-service advice for "delete":** torrents in `tv-sonarr`/`radarr` belong to Sonarr/Radarr. For those,
the app should prefer the *arr queue delete (`DELETE /api/v3/queue/{id}?removeFromClient=true&blocklist=...`,
documented in the *arr spec). That way Sonarr/Radarr don't re-grab the release or report a missing download.
Offer raw qBittorrent delete for uncategorised or `books` torrents, or as an "advanced" option.

### 1.11 Other qBittorrent notes

- `GET /api/v2/app/preferences` has 241 keys and contains secrets (`web_ui_username`, `web_ui_api_key`, `proxy_password`, `mail_notification_*`, `dyndns_*`). **Never pass it through to the app.** The gateway should whitelist the keys it needs: scheduler, share limits (`max_ratio*`, `max_seeding_time*`, `max_inactive_seeding_time*`, `max_ratio_act`), queueing (`max_active_*`), `listen_port`, `save_path`, `alt_*_limit`, `dl_limit`, `up_limit`.
- `listen_port` (36681) must equal gluetun's forwarded port (section 2). The gluetun `VPN_PORT_FORWARDING_UP_COMMAND` hook pushes it automatically. The hub can show a "port forward in sync" check.
- `GET /api/v2/log/main?last_known_id=<id>` returns `[{id,message,timestamp,type}]` (type is a bit flag: 1 normal, 2 info, 4 warning, 8 critical). Use incremental `last_known_id`. Most entries are Homepage login noise.
- All `/api/v2` JSON is `application/json`. Text endpoints are `text/plain; charset=UTF-8`.

---

## 2. Gluetun control server (2 routes only)

Base URL from the gateway: `http://gluetun:8000` (host-published as `192.168.10.183:8003`). No auth.

| route | response body (real) | notes |
|---|---|---|
| `GET /v1/publicip/ip` | `{"public_ip":"203.0.113.10","region":"Provence-Alpes-Côte d'Azur","country":"France","city":"Marseille","location":"43.2970,5.3811","organization":"AS212238 Datacamp Limited","postal_code":"13000","timezone":"Europe/Paris"}` | all strings. `location` is a "lat,lon" string. While the VPN reconnects, expect `public_ip: ""` and empty fields: treat an empty `public_ip` as "VPN down / reconnecting". |
| `GET /v1/openvpn/portforwarded` | `{"port":36681}` | int. **`0` = no forwarded port yet.** Compare with qBittorrent `listen_port`. |

Gotchas:
- **Content-Type is `text/plain; charset=utf-8`** even though the body is JSON, and the body ends with `\n`. Decode the body as JSON regardless of the header.
- Every other route returns **401 `Unauthorized`** (text). Tested: `/v1/portforward`, `/v1/openvpn/status`, `/v1/vpn/status`, `/v1/dns/status`, `/v1/updater/status`, `/v1/openvpn/settings`. The hub therefore **cannot** read VPN status or restart the VPN through gluetun. Infer VPN status from "publicip non-empty and qBittorrent `connection_status == connected`", plus the container health from the Docker spec (gluetun reports `(healthy)`). Restarting gluetun means restarting the container through the containers module. Warn the user that qBittorrent loses network when gluetun restarts and usually needs restarting afterwards.
- Latency is under 1 ms. Poll every 30–60 s at most; the values rarely change.
- Every request is logged by gluetun (`HTTP_CONTROL_SERVER_LOG=on`). Keep polling modest.

Suggested gateway composite "VPN" tile: `{publicIp, country, city, forwardedPort, qbitListenPort, portInSync: forwardedPort>0 && forwardedPort==qbitListenPort, qbitConnection: server_state.connection_status}`.

---

## 3. Prowlarr 2.7.0 (API v1)

Header `X-Api-Key: <key>`. Missing or wrong key → `401` with an empty body. All responses are
`application/json; charset=utf-8`. Errors use the Servarr shape `{"message": "...", "description": "<.NET stack trace>"}`.
Example: `GET /api/v1/indexer/999999` → 404 `{"message":"IndexerDefinition with ID 999999 does not exist", ...}`.
**Never forward `description` to the app**, because it is a stack trace.

### 3.1 Indexer list (screen: Indexers)

`GET /api/v1/indexer` returns an array (10 here, all public `Cardigann` torrent indexers), ~11 ms.

| field | type | notes |
|---|---|---|
| `id` | int | |
| `name` | string | e.g. `1337x`, `Nyaa.si`, `Uindex` |
| `enable` | bool | user enable switch |
| `priority` | int | 1–50, **lower = higher priority**; default 25 (all are 25 here) |
| `tags` | int[] | tag ids → `GET /api/v1/tag` (`[{"label":"flaresolverr","id":1}]`). Tag 1 = route through the FlareSolverr proxy. |
| `protocol` | string | `torrent` \| `usenet` |
| `privacy` | string | `public` \| `semiPrivate` \| `private` |
| `appProfileId` | int | → `GET /api/v1/appprofile` (`Standard`, id 1) |
| `implementation`, `implementationName`, `configContract`, `definitionName` | string | |
| `supportsRss`, `supportsSearch`, `supportsRedirect`, `supportsPagination`, `redirect` | bool | |
| `indexerUrls`, `legacyUrls` | string[] | |
| `description`, `language`, `encoding`, `infoLink` | string | |
| `added` | ISO-8601 UTC | |
| `downloadClientId` | int | 0 = default |
| `capabilities` | object | `limitsMax`, `limitsDefault`, `supportsRawSearch`, `searchParams`, `tvSearchParams`, `movieSearchParams`, `musicSearchParams`, `bookSearchParams` and `categories[]` (`{id,name,subCategories[]}`; up to 85 per indexer, so **strip it** from list responses to the phone) |
| `fields` | array of `{order?, name, label?, value, type, advanced?, privacy, ...}` | provider settings, needed only for PUT/test. `privacy` ∈ `normal`, `apiKey`, `password`, `userName`. **Secret values are masked as `"********"`** in GET responses (verified on `/api/v1/applications` `apiKey` fields). |

`GET /api/v1/indexer/{id}` returns the same object for one indexer.

### 3.2 Indexer status (failures / back-off)

`GET /api/v1/indexerstatus` returns **only indexers currently in failure back-off**, about 2 ms. Live:
```json
[{"indexerId":15,"disabledTill":"2026-11-08T19:06:16Z","mostRecentFailure":"2026-11-07T19:06:16Z","initialFailure":"2026-05-29T23:36:28Z"}]
```
- All timestamps are ISO-8601 UTC strings. `disabledTill` may be in the past for a short time; the indexer counts as "failing" only while `disabledTill > now`.
- Join with `/indexer` on `indexerId`. The app status per indexer: `enable == false` → Disabled; status present and `disabledTill > now` → "Failing, retry at …"; otherwise OK.
- Matching health message: `GET /api/v1/health` → `IndexerLongTermStatusCheck` "Indexers unavailable due to failures for more than 6 hours: Uindex".

### 3.3 Indexer stats

`GET /api/v1/indexerstats` takes 0.25–0.5 s (the slowest call here; **cache it 5–10 min**). Optional
`startDate`/`endDate` (ISO-8601) were tested and work.
```json
{"indexers":[{"indexerId":3,"indexerName":"EZTV","averageResponseTime":884,"averageGrabResponseTime":0,
  "numberOfQueries":38,"numberOfGrabs":0,"numberOfRssQueries":1842,"numberOfAuthQueries":0,
  "numberOfFailedQueries":0,"numberOfFailedGrabs":0,"numberOfFailedRssQueries":0,"numberOfFailedAuthQueries":0}],
 "hosts":[{"host":"sonarr","numberOfQueries":23655,"numberOfGrabs":69}],
 "userAgents":[{"userAgent":"Sonarr","numberOfQueries":23655,"numberOfGrabs":69}]}
```
`averageResponseTime` is in ms. The `indexers` array includes only indexers with history in the range.

### 3.4 Health and system

- `GET /api/v1/health` returns `[{source, type, message, wikiUrl}]`, with `type` ∈ `ok | notice | warning | error`. Live: `AllowedHostsCheck` (warning: "Allowed Hosts is not configured") and `IndexerLongTermStatusCheck`. **Gotcha:** if the user later sets Allowed Hosts in Prowlarr to silence the warning, they must include `prowlarr` (the Docker hostname the gateway uses), or every gateway call will be rejected.
- `GET /api/v1/system/status` returns `{appName, instanceName, version:"2.7.0.5723", buildTime, startTime, branch, isDocker, packageVersion:"2.7.0.5723-ls167", packageUpdateMechanism:"docker", authentication:"forms", ...}`.
- `GET /api/v1/system/task` returns scheduled tasks `[{name, taskName, interval (minutes), lastExecution, nextExecution, lastDuration ("hh:mm:ss.fffffff")}]`.
- `GET /api/v1/update` returns `[{version, releaseDate, installed, installable, latest, ...}]`. Use it for an "update available" badge, but the update itself goes through the container module (Watchtower or compose), never Prowlarr's self-updater (`packageUpdateMechanism: docker`).
- `GET /api/v1/applications` returns the linked Sonarr/Radarr (`syncLevel: fullSync`). Their `apiKey` fields are masked `********`. Read-only use only.
- `GET /api/v1/indexerproxy` returns the FlareSolverr proxy (`host: http://flaresolverr:8191/`, `requestTimeout: 120`, tag 1).
- `GET /api/v1/downloadclient` returns **`[]` (none configured)**. This matters for section 3.8.

### 3.5 History

```
GET /api/v1/history?page=1&pageSize=20&sortKey=date&sortDirection=descending
     [&eventType=<int>][&successful=true|false][&indexerIds=<id>][&downloadId=<id>]
```
Response: `{page, pageSize, sortKey, sortDirection, totalRecords, records:[...]}`; `totalRecords` = 33,088 here.

- `eventType` filter values (verified): **1 = releaseGrabbed (80), 2 = indexerQuery (1718), 3 = indexerRss (31296)**, 4 = indexerAuth (0), 5 = indexerInfoQuery (0). In records, `eventType` is the **camelCase string** (`"indexerRss"`), not the int.
- `successful=false` works (78 failures). `indexerIds=15` works (21 records).
- `GET /api/v1/history/indexer?indexerId=15&limit=2` returns a plain array for one indexer.
- `GET /api/v1/history/since?date=<ISO>` returns a plain array with **no paging** (2,222 rows in 24 h). Avoid it, or use it only for short windows.
- **`pageSize` is not capped.** `pageSize=100000` returned 17 MB. The gateway must clamp it (for example to 100 or less).
- Latency: ~0.4 s for the first page sorted by date; filtered queries ~40 ms.

Record shape: `{id, indexerId, date (ISO UTC), successful (bool), eventType (string), data: {...}}`. `data` is
**a map of strings only**, even for numbers:
- query/RSS: `{"limit":"100","offset":"0","elapsedTime":"993","query":"","queryType":"tvsearch","categories":"5000,5040","source":"Sonarr","host":"sonarr","queryResults":"20","url":"https://...","cached":"0"}`
- grab: `{"source":"Sonarr","host":"sonarr","grabMethod":"Proxy","grabTitle":"[SubsPlease] ... [Batch]","url":"magnet:?xt=urn:btih:..."}`

Recommended app views: "Recent grabs" (`eventType=1`) and "Failures" (`successful=false`). Map `indexerId` to a name via the cached indexer list.

### 3.6 Enable/disable, priority, tags (writes, NOT called)

**Preferred: bulk edit.** It needs no full resource body and doesn't run a connectivity test. Shape from
`createBulkEditItemHandler.js` + `EditIndexerModalContent.tsx` + `IndexerIndexSelectFooter.tsx`:
```
PUT /api/v1/indexer/bulk
Content-Type: application/json
{"ids":[15], "enable": false}                       // enable/disable
{"ids":[4,5], "priority": 10}                       // priority
{"ids":[4], "tags":[1], "applyTags":"add"}          // tags; applyTags = add | remove | replace
// other optional keys: appProfileId, minimumSeeders, seedRatio, seedTime, packSeedTime, preferMagnetUrl
```
Returns **202 Accepted** with the updated indexer array. This is the Servarr provider-controller convention, taken from Sonarr/Radarr source. I could not check it live without a write, so accept any 2xx.

Alternative single update (full body, as the UI's `createSaveProviderHandler.js` does):
```
GET  /api/v1/indexer/{id}            -> resource
PUT  /api/v1/indexer/{id}[?forceSave=true]
Content-Type: application/json
<the entire resource from GET, with "enable" (or priority/tags) changed>
```
- Returns **202** with the saved resource (Servarr convention, not verified live; accept any 2xx). On save, Prowlarr validates **and tests** an enabled indexer. If the site is down, the save fails with `400` and a validation array. `forceSave=true` skips the test (the UI adds it when you press Save again with no changes).
- Masked secret fields (`"********"`) can be sent back unchanged; Servarr keeps the stored value. This is expected behaviour, but it is **unverified**: all indexers here are public. Prefer `/indexer/bulk`, which never touches `fields`.

### 3.7 Test indexer(s) (writes, NOT called)

```
POST /api/v1/indexer/test[?forceTest=true]
Content-Type: application/json
<full indexer resource, exactly as returned by GET /api/v1/indexer/{id}>
```
- Success: **200** (empty or `{}` body; Servarr convention, not verified live). Failure: **400** with
  `[{"propertyName":"BaseUrl","errorMessage":"Unable to connect to indexer...","attemptedValue":...,"severity":"error","errorCode":...,"isWarning":false,"infoLink":...,"detailedDescription":...}]`. Show `errorMessage` values.
- Prowlarr caches the result of testing an identical body. The UI adds `forceTest=true` when the body is unchanged since the last test. **The gateway should always send `forceTest=true` for a user-pressed "Test".**
- Test all: `POST /api/v1/indexer/testall` (no body) returns `[{"id":4,"isValid":true,"validationFailures":[]}, ...]`. The status is 400 if any is invalid (Servarr convention, not verified live), but the body has the same shape, so parse it on both 200 and 400.
- Latency: tests go out through FlareSolverr (timeout **120 s**) for tag-1 indexers. Give the gateway an upstream timeout of about 150 s for test endpoints, and show a spinner in the app.

### 3.8 Manual search (document only; NOT run)

```
GET /api/v1/search?query=<text>&type=<search|tvsearch|movie|music|book>
                   [&indexerIds=<id>&indexerIds=<id>...][&categories=<id>&categories=<id>...]
                   [&limit=100][&offset=0]
```
Parameter names come from `SearchIndex.js` (`{query, indexerIds, categories, type, limit, offset}`). The types
come from `QueryParameterModal.js`. Send array params as repeated keys (ASP.NET Core form binding). The
category ids are the Newznab ids from `GET /api/v1/indexer/categories` (1000 Console, 2000 Movies, 3000 Audio,
4000 PC, 5000 TV, 6000 XXX, 7000 Books, 8000 Other, each with `subCategories[]`). Omitting `indexerIds` searches all
enabled indexers. `query` supports Prowlarr's `{ImdbId:tt…}`, `{Season:1}`, `{Episode:2}` tokens with `type=tvsearch|movie`.

Response: array of releases (field list from `SearchIndexRow.tsx`):
`guid (string, key), indexerId, indexer, title, fileName, protocol, age (days), ageHours, ageMinutes, publishDate (ISO),
size (bytes), files?, grabs?, seeders?, leechers?, infoUrl, downloadUrl?, magnetUrl?, imdbId?, tmdbId?, tvdbId?, tvMazeId?,
indexerFlags (string[]), categories ([{id,name,subCategories}])`.

Gotchas:
- **Latency:** a fan-out across 10 indexers, some behind FlareSolverr (120 s timeout). Expect 5–60 s, worst case about 2 min. Use a long gateway timeout (~150 s), require explicit user action, and debounce. **Never search-as-you-type.**
- **`downloadUrl` embeds Prowlarr's API key** (a Prowlarr proxy link `.../{indexerId}/download?apikey=...&link=...`). The gateway must **strip `downloadUrl` before sending results to the phone.** Keep a server-side map `guid → {indexerId, downloadUrl, magnetUrl}` for about 30 min, which matches Prowlarr's release cache.
- **Grab via Prowlarr will not work as configured.** `POST /api/v1/search` with `{"guid":"...","indexerId":N,"downloadClientId":<optional>}` (and `POST /api/v1/search/bulk` with an array of releases) sends to *Prowlarr's* download client, and **none is configured** (`/downloadclient` → `[]`). It also returns 404 once the release has dropped out of Prowlarr's cache (~30 min). Recommended hub flow for "grab": the gateway sends `magnetUrl` (preferred), or fetches the `.torrent` from `downloadUrl` server-side and uploads the bytes, to **qBittorrent `torrents/add`** (section 1.10). Uploading the bytes avoids depending on qBittorrent's VPN-namespace DNS to resolve `prowlarr`. Use a non-*arr category (for example `books` or a new `manual` category). A torrent dropped into `tv-sonarr`/`radarr` that Sonarr/Radarr didn't grab shows up as an unknown queue item or manual-import warning.
- For TV and movies, the better UX is the *arr interactive search (Sonarr/Radarr `GET /api/v3/release?episodeId=`), which keeps import tracking. Treat the Prowlarr search as a power-user tool, mainly for books.

---

## 4. Bazarr 1.6.2

Header `X-API-KEY: <key>` (`x-api-key` works too). Wrong or missing key → **401**
`{"message": "The server could not verify that you are authorized ..."}`. Content-Type is `application/json`.
Most list endpoints wrap results as `{"data": [...]}` or `{"data": [...], "total": N}`. Bad parameters →
**400** `{"errors": {"start": "Paging start integer invalid literal for int() with base 10: 'abc'"}, "message": "Input payload validation failed"}`.
The swagger spec is at `GET /api/swagger.json`.

**Argument location:** Bazarr uses flask-restx `reqparse` with the default `location=("json","values")`. All
documented "query" params of PATCH/POST also work as a query string, form fields or a JSON body. **Use the query
string**, as the swagger documents, with no body.

### 4.1 Badges (dashboard tile)

`GET /api/badges` takes ~0.12 s:
```json
{"episodes":111,"movies":3,"providers":1,"status":0,"sonarr_signalr":"LIVE","radarr_signalr":"LIVE","announcements":2}
```
- `episodes`/`movies` = counts of items with missing subtitles. They match `episodes/wanted.total` (111) and `movies/wanted.total` (3).
- `providers` = number of **throttled** providers (`len(get_throttled_providers())`). Observed: `1` in badges at the same time `/api/providers` listed all five providers as `Good`, and `throttled_providers.dat` was `{}`. The throttle had just expired. Use `/api/providers` for detail and treat the badge as a hint.
- `status` = number of health issues (`/api/system/health`).
- `sonarr_signalr`/`radarr_signalr`: `"LIVE"` or `"DOWN"`. When DOWN, Bazarr misses new imports until the next 60-min sync. Show it as a warning.

### 4.2 Wanted (missing subtitles)

```
GET /api/episodes/wanted?start=0&length=25      (optional: episodeid[]=<id>&episodeid[]=<id>)
GET /api/movies/wanted?start=0&length=25        (optional: radarrid[]=<id>)
```
- Pagination is `start` (offset) + `length`. Response `{data:[...], total:int}`. **No `length`, or `length=-1`, returns everything** (111 rows). That's fine here, but always send a length.
- Episode item: `{"seriesTitle":"Gachiakuta","episode_number":"1x11" (string "SxE"),"episodeTitle":"...","missing_subtitles":[{"name":"English","code2":"en","code3":"eng","forced":false,"hi":false}],"sonarrSeriesId":164,"sonarrEpisodeId":7941,"sceneName":null|string,"tags":[],"seriesType":"anime|standard"}`
- Movie item: `{"title":"Hotel","missing_subtitles":[...],"radarrId":190,"sceneName":null,"tags":[]}`
- No posters in wanted items. For artwork, use `GET /api/series?seriesid[]=<id>` → `poster` is a **relative** path like `/images/series/MediaCover/157/poster-250.jpg` served by Bazarr, which proxies Sonarr. The gateway should proxy it, or better, use Sonarr's own MediaCover.

### 4.3 Trigger subtitle searches (writes, NOT called)

All of these are **queued**: Bazarr 1.6 adds a job to its job queue and returns **204 No Content** immediately
(verified in `subtitles/mass_download/series.py`: `if not job_id: return jobs_queue.add_job_from_function(...)`).
Track progress with `GET /api/system/jobs`.

| app action | request | source |
|---|---|---|
| Search one episode's missing language | `PATCH /api/episodes/subtitles?seriesid=<sonarrSeriesId>&episodeid=<sonarrEpisodeId>&language=<code2>&forced=<true\|false>&hi=<true\|false>` (take `language/forced/hi` from the `missing_subtitles` entry) | `api/episodes/episodes_subtitles.py` (all 5 params required; `forced`/`hi` are strings, `.capitalize()`d server-side) |
| Search one movie | `PATCH /api/movies/subtitles?radarrid=<id>&language=<code2>&forced=..&hi=..` | swagger |
| Search all missing for one series | `PATCH /api/series?seriesid=<id>&action=search-missing` | `api/series/series.py`; 500 `Series directory not found. Path mapping issue?` on OSError |
| Search all missing for one movie | `PATCH /api/movies?radarrid=<id>&action=search-missing` | |
| **Search ALL wanted (series)** | `POST /api/system/tasks?taskid=wanted_search_missing_subtitles_series`, **or** `PATCH /api/series?action=search-wanted` | both call `wanted_search_missing_subtitles_series()` |
| **Search ALL wanted (movies)** | `POST /api/system/tasks?taskid=wanted_search_missing_subtitles_movies`, or `PATCH /api/movies?action=search-wanted` | |
| Other actions on `PATCH /api/series` / `/api/movies` | `action=scan-disk` \| `sync` | unknown action → 400 `Unknown action` |
| Reset throttled providers | `POST /api/providers?action=reset` | 204 |
| Run any scheduled task now | `POST /api/system/tasks?taskid=<job_id from GET /api/system/tasks>` | 204 (`scheduler.execute_job_now`) |

Manual (interactive) subtitle search, `GET /api/providers/episodes?episodeid=<id>`, is a GET but it **queries
external providers live** and is slow (tens of seconds). I didn't call it. To download a chosen result:
`POST /api/providers/episodes?seriesid=..&episodeid=..&hi=True|False&forced=True|False&original_format=True|False&provider=<name>&subtitle=<id from GET>`
(note the **capitalised** `True`/`False` here). Movies: `/api/providers/movies?radarrid=..`. Low priority for v1 of the app.

### 4.4 Jobs queue (progress of triggered searches)

`GET /api/system/jobs[?status=pending|running|failed|completed][&id=<job_id>]` returns:
```json
{"data":[{"job_id":29,"job_name":"Synced movies with Radarr","status":"completed","last_run_time":"2026-11-08T08:22:37.270754+00:00",
  "is_progress":true,"is_signalr":false,"progress_value":256,"progress_max":256,"progress_message":"Austin Powers in Goldmember"}]}
```
`last_run_time` is ISO-8601 with microseconds and an offset. Poll `?status=running` every 2–3 s only while the
app shows a "searching…" indicator. Other ops: `DELETE /api/system/jobs?id=`, `PATCH ?queueName=pending|failed|completed`
(empties a queue), `POST ?id=&action=force_start|move_top|move_bottom`.

### 4.5 Scheduled tasks

`GET /api/system/tasks[?taskid=<id>]` returns `{"data":[{"interval":"every 6 hours","job_id":"wanted_search_missing_subtitles_series","job_running":false,"name":"Search for Missing Series Subtitles","next_run_in":"in 3 hours","next_run_time":"in 3 hours"}, ...]}`.
**`interval`, `next_run_in` and `next_run_time` are humanised English strings, not timestamps.** Display them as-is.
Use `job_running` to disable the "Run now" button. Live task ids: `update_release, update_movies, update_series,
update_announcements, wanted_search_missing_subtitles_movies, wanted_search_missing_subtitles_series, check_health,
upgrade_subtitles, cache_cleanup, movies_full_scan_subtitles, series_full_scan_subtitles, backup`.

### 4.6 History

```
GET /api/episodes/history?start=0&length=25[&episodeid=<id>]
GET /api/movies/history?start=0&length=25[&radarrid=<id>]
```
- `{data:[...], total}`: total 2,226 episodes and 435 movies. **Without `length`, it returns the whole table: 2.2 MB in 2.5 s.** Always paginate.
- Episode record fields: `seriesTitle, episode_number ("3x17"), episodeTitle, sonarrSeriesId, sonarrEpisodeId, monitored, action (int), description, language {name,code2,code3,forced,hi}, provider, score ("100.0%" string), subtitles_path, subs_id, upgradable, blacklisted, matches[], dont_matches[], tags[], timestamp, parsed_timestamp`.
  Movie records: `title, radarrId, path (may be null)` instead of the series fields.
- **Timestamps:** `timestamp` is humanised ("an hour ago", "yesterday"). `parsed_timestamp` is `"11/08/26 07:53:14"`, format **`MM/dd/yy HH:mm:ss` in UTC**. Bazarr's timezone is `Etc/UTC`; this matched a job's `last_run_time` of `2026-11-08T07:53:14Z`. Parse `parsed_timestamp` as UTC.
- `action` codes, from the Bazarr frontend bundle: **0 Delete, 1 Download, 2 Manual, 3 Upgrade, 4 Upload, 5 Sync, 6 Translated, 7 Extracted**. Live mix in the last 500: 499 × 1, 1 × 3.
- Stats: `GET /api/history/stats?timeFrame=week|month|trimester|year&action=All&provider=All&language=All` returns `{"series":[{"date":"2026-10-11","count":20},...],"movies":[...]}`, one entry per day, good for a sparkline.

### 4.7 Providers, health, status, misc

- `GET /api/providers` returns `{"data":[{"name":"opensubtitlescom","status":"Good","retry":"-"}, ...]}` (5 enabled: animesubinfo, embeddedsubtitles, opensubtitlescom, tvsubtitles, yifysubtitles). A throttled provider has a reason in `status` and a retry time in `retry`. `?history=<provider>` changes the semantics: it lists providers that appear in history, with `status: "History"`. Don't use it for health.
- `GET /api/system/health` returns `{"data":[]}` when healthy. Items are `{object, issue}`.
- `GET /api/system/status` returns `{"data":{"bazarr_version":"1.6.2","package_version":"v1.6.2-ls371 by linuxserver.io","sonarr_version":"4.0.20.3014","radarr_version":"6.4.4.10685","python_version":"3.12.16","start_time":1794118925.33 (unix float),"timezone":"Etc/UTC","cpu_cores":4,...}}`.
- `GET /api/system/announcements` returns `{"data":[{text, link, hash, dismissible, timestamp (humanised), enabled}]}`. Dismiss with `POST /api/system/announcements?hash=<hash>`.
- `GET /api/system/releases` returns `{"data":[{name:"v1.6.2", date, prerelease, current, body:[markdown lines]}]}`. Use it for an "update available" check (`current` marks the running one).
- `GET /api/system/languages/profiles` returns language profiles (one profile, "en").
- Note: the subtitle-wanted badge equals the wanted totals, so the dashboard tile needs only `/api/badges`.

---

## 5. Suggested polling and caching (gateway)

| data | source | cadence |
|---|---|---|
| torrent list + global speeds (live screen open) | qBit `sync/maindata` (single poller, merged state) | 1.5–2 s while ≥1 subscriber, else stop |
| downloads tile (home screen) | qBit `transfer/info` + `torrents/info?filter=downloading` (or the cached maindata) | 10–15 s |
| VPN tile | gluetun 2 routes + qBit `connection_status` / `listen_port` | 60 s |
| indexers + status | Prowlarr `/indexer` (strip `capabilities.categories`, `fields`) + `/indexerstatus` + `/health` | 60 s; invalidate after writes |
| indexer stats | Prowlarr `/indexerstats` | 5–10 min |
| Prowlarr history | `/history?page&pageSize<=50` | on demand |
| subtitles tile | Bazarr `/api/badges` | 60 s |
| subtitles wanted/history | Bazarr paginated endpoints | on demand |
| subtitle search progress | Bazarr `/api/system/jobs?status=running` | 2–3 s while visible |

Upstream timeouts: qBittorrent/gluetun/Bazarr GETs 10 s. Prowlarr list GETs 15 s. Prowlarr search and test 150 s.
Bazarr manual provider search 120 s.

---

## 6. Gotcha checklist (quick reference)

1. qBit cookie is `QBT_SID_8081`; login returns **204**, bad login returns **401**; 5 failures ban the IP for 1 h.
2. qBit `pause`/`resume` are **gone (404)**; use `stop`/`start`. The `filter=paused` alias silently returns **all** torrents.
3. qBit `tags` is a comma-separated **string**. `global_ratio` and the cache stats are **strings**. `eta` 8640000 = ∞. In `torrents/info` limit 0 = unlimited, but in `properties` -1 = unlimited.
4. qBit share-limit sentinels: **-2 global, -1 unlimited**. New `share_limit_action` / `share_limits_mode` strings.
5. qBit alt-speed **scheduler is on (08:00–17:00)** and overrides manual toggles. Use `setSpeedLimitsMode mode=`, not toggle.
6. qBit deleteFiles deletes permanently (`torrent_content_remove_option: Delete`). `Keep` tag = decluttarr protection.
7. qBit `app/preferences` contains secrets: whitelist keys, never pass it through.
8. Gluetun responses are JSON with a `text/plain` content type. Port `0` = none. Every other route is 401.
9. Prowlarr `pageSize` is uncapped (17 MB seen); `history/since` is unpaged. Clamp both.
10. Prowlarr history `data` values are all strings. `eventType` filters by int but reads back as a camelCase string.
11. Prowlarr search `downloadUrl` contains the API key, so strip it. Prowlarr has **no download client**, so grabbing must go through qBit `torrents/add`.
12. Prowlarr PUT returns **202**, not 200. Use `PUT /indexer/bulk {ids, enable}` for toggles. Test with `forceTest=true`; tests can take up to 120 s (FlareSolverr).
13. Prowlarr Allowed Hosts (currently unset): if configured later, it must include `prowlarr`.
14. Bazarr list endpoints without `length` return everything (history is 2.2 MB in 2.5 s).
15. Bazarr `parsed_timestamp` is `MM/dd/yy HH:mm:ss` UTC. `timestamp`, `next_run_in` and `interval` are humanised strings.
16. Bazarr search triggers return 204 immediately (queued). Watch `/api/system/jobs`. `providers/*` manual endpoints use `True`/`False`; the others use `true`/`false`.

---

## 7. Fixture index

All files are in `fixtures/downloads/`. They are real GET responses from 2026-11-08: arrays trimmed to at most 5
items, hash-keyed maps (`torrents`, `trackers`) trimmed to 5 entries, and nested arrays trimmed to 5. Redactions: qBittorrent
`web_ui_username` (and any non-empty mail/proxy/dyndns credential) → `"REDACTED"`; VPN exit IP
(`last_external_address_v4`, `public_ip`) → `203.0.113.10`; peer IPs → `198.51.100.x` (map keys rebuilt to match).
Prowlarr's own `"********"` masks are kept as returned.

| file | source call |
|---|---|
| `qbittorrent_torrents_info.json` | `GET /api/v2/torrents/info?sort=added_on&reverse=true&limit=5` |
| `qbittorrent_torrents_info_stopped.json` | `GET /api/v2/torrents/info?filter=stopped&limit=3` (`stoppedUP`) |
| `qbittorrent_torrents_info_include_files_trackers.json` | `GET /api/v2/torrents/info?limit=2&includeFiles=true&includeTrackers=true` |
| `qbittorrent_sync_maindata_full.json` | `GET /api/v2/sync/maindata?rid=0` (full_update) |
| `qbittorrent_sync_maindata_delta.json`, `..._delta_2.json` | `GET /api/v2/sync/maindata?rid=<prev>` (partial) |
| `qbittorrent_transfer_info.json` | `GET /api/v2/transfer/info` |
| `qbittorrent_transfer_getSpeedLimits.json` | `GET /api/v2/transfer/getSpeedLimits` |
| `qbittorrent_torrents_categories.json` / `_tags.json` | `GET /api/v2/torrents/categories` / `tags` |
| `qbittorrent_torrents_properties.json` | `GET /api/v2/torrents/properties?hash=` |
| `qbittorrent_torrents_files.json` | `GET /api/v2/torrents/files?hash=` |
| `qbittorrent_torrents_trackers.json` | `GET /api/v2/torrents/trackers?hash=` (incl. DHT/PeX/LSD pseudo-rows and `endpoints[]`) |
| `qbittorrent_sync_torrentPeers.json` | `GET /api/v2/sync/torrentPeers?hash=&rid=0` |
| `qbittorrent_app_buildInfo.json` | `GET /api/v2/app/buildInfo` |
| `qbittorrent_app_preferences.json` | `GET /api/v2/app/preferences` (redacted) |
| `qbittorrent_log_main.json` | `GET /api/v2/log/main?last_known_id=-1` (last 5) |
| `qbittorrent_text_responses.json` | **not a raw body**: a map of text/plain endpoints and error responses to their exact bodies (version, webapiVersion, speedLimitsMode, count, 400/401/403/404 texts) |
| `gluetun_publicip_ip.json`, `gluetun_openvpn_portforwarded.json` | the two allowed gluetun routes |
| `prowlarr_indexer.json` | `GET /api/v1/indexer` |
| `prowlarr_indexerstatus.json` | `GET /api/v1/indexerstatus` |
| `prowlarr_indexerstats.json` | `GET /api/v1/indexerstats` |
| `prowlarr_indexer_categories.json` | `GET /api/v1/indexer/categories` |
| `prowlarr_health.json`, `prowlarr_system_status.json`, `prowlarr_system_task.json`, `prowlarr_update.json`, `prowlarr_command.json`, `prowlarr_log.json` | system endpoints |
| `prowlarr_history.json`, `prowlarr_history_failed.json` | `GET /api/v1/history?page=1&pageSize=5...` (`&successful=false`) |
| `prowlarr_history_since_mixed.json` | items picked from `GET /api/v1/history/since` (3 grabs, 1 failure, 1 RSS) |
| `prowlarr_tag.json`, `prowlarr_tag_detail.json`, `prowlarr_applications.json`, `prowlarr_appprofile.json`, `prowlarr_indexerproxy.json`, `prowlarr_downloadclient.json` (`[]`) | config endpoints |
| `prowlarr_error_404.json` | `GET /api/v1/indexer/999999` (stack trace shortened) |
| `bazarr_badges.json` | `GET /api/badges` |
| `bazarr_episodes_wanted.json`, `bazarr_movies_wanted.json` | `GET /api/{episodes,movies}/wanted?start=0&length=5` |
| `bazarr_episodes_history.json`, `bazarr_movies_history.json` | `GET /api/{episodes,movies}/history?start=0&length=5` |
| `bazarr_history_stats.json` | `GET /api/history/stats?timeFrame=month&...` (last 5 days) |
| `bazarr_system_tasks.json`, `bazarr_system_jobs.json`, `bazarr_system_status.json`, `bazarr_system_health.json`, `bazarr_system_announcements.json`, `bazarr_system_releases.json`, `bazarr_system_languages_profiles.json` | system endpoints |
| `bazarr_providers.json` | `GET /api/providers` |
| `bazarr_series.json`, `bazarr_movies.json`, `bazarr_episodes_blacklist.json` | `GET /api/series?start=0&length=2`, `/api/movies?...`, `/api/episodes/blacklist` |
| `bazarr_error_400.json`, `bazarr_error_401.json` | validation error / bad key bodies |
