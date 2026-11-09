# YAMS Hub app: information architecture and screens

Flutter app (Android, iOS, web), Material 3, dark by default. Architecture: [ARCHITECTURE.md](ARCHITECTURE.md) §7.
Endpoints: [API.md](API.md) (paths below are relative to `/api/v1`). Every screen lists its route, owner slice, widgets,
endpoints, refresh interval, and its loading / empty / error states.

---

## 1. Navigation map

```
/onboarding                      server setup (core)                        no auth
/login                           sign in (core)                             no auth
Shell (bottom bar on phones, rail on tablet/web)
├─ /home                         Dashboard (core)
│   └─ apps                      Web apps launcher (core)
├─ /requests                     Discover (requests)
│   ├─ search?q=                 Search results
│   ├─ discover/:slider          Full grid for one carousel
│   ├─ title/:mediaType/:tmdbId  Title detail → request sheet, report-issue sheet
│   ├─ list?tab=pending|mine|all|failed   Requests list
│   │   └─ :id                   Request detail
│   └─ issues                    Issues list
│       └─ :id                   Issue detail
├─ /library                      Library (library)  tabs TV | Movies | Wanted
│   ├─ tv/:id                    Series detail
│   │   └─ season/:n             Season detail (episodes)
│   ├─ movies/:id                Movie detail
│   ├─ add?kind=tv|movie&term=   Add new (lookup) → add sheet
│   └─ history/:service/:id      Full item history
├─ /activity?tab=&import=       Activity (activity)  tabs Queue | Torrents | History; `import=<key>` opens the manual-import sheet
│   ├─ torrent/:hash             Torrent detail
│   ├─ transfer                  Speed & session settings
│   └─ add?url=                  Add torrent sheet as a page (admin; target of magnet: links)
├─ /calendar                     Calendar agenda (calendar)
├─ /media                        Media (media)  tabs Now playing | Stats | Apps
│   ├─ jellyfin                  Jellyfin overview
│   ├─ audiobooks                Audiobookshelf overview
│   ├─ books                     Kavita overview
│   ├─ shelfmark                 Shelfmark (book/audiobook downloads) status
│   └─ stats/users               Watch stats per user
├─ /containers                   Containers (containers)
│   ├─ :name                     Container detail
│   │   └─ logs                  Log viewer (admin)
│   ├─ updates                   Updates
│   └─ maintenance               Decluttarr + Recyclarr
├─ /indexers                     Indexers (indexers)
│   ├─ :id                       Indexer detail
│   ├─ history                   Prowlarr history
│   └─ search                    Manual search (admin)
├─ /subtitles                    Subtitles (subtitles)  tabs Episodes | Movies | History
├─ /system                       System (system)  host + uptime + service health
├─ /settings                     Settings (settings)
│   ├─ servers, servers/:id      Server profiles
│   ├─ account                   Password
│   ├─ sessions                  Signed-in devices
│   ├─ users, users/:id          Hub users (admin)
│   ├─ audit                     Audit log (admin)
│   ├─ appearance                Theme
│   ├─ refresh                   Refresh rate
│   ├─ apps                      Media app links & schemes
│   └─ about                     Versions, health, licenses
└─ /more                         phone-only list of the destinations not in the bottom bar (core)
```

Phone bottom bar: **Home, Requests, Library, Activity, More**. Tablet rail / web: Home, Requests, Library, Activity,
Calendar, Media, Containers, Indexers, Subtitles, System, Settings (grouping in ARCHITECTURE §7.3).
Icons (the bundled `Icons` class, `_outlined` variant unselected, filled when selected; no symbols package): Home
`dashboard`, Requests `movie_filter`, Library `video_library`, Activity `swap_vert`, Calendar `calendar_month`, Media
`play_circle`, Containers `inventory_2` (`deployed_code` does not exist in `Icons`), Indexers `travel_explore`,
Subtitles `subtitles`, System `monitor_heart`, Settings `settings`, More `more_horiz`, Web apps `apps`.
Badges (from `navBadgesProvider`, refreshed every 30 s on every tab): Requests = pending count (admins), Activity =
queue items needing attention.

Within each feature's route list, static sub-routes are declared before parameterised ones (`updates`/`maintenance`
before `:name`, `history`/`search` before `:id`). Every route above has an `AppPaths` helper (ARCHITECTURE §7.3).

Back navigation: each branch keeps its own stack (StatefulShellRoute). Detail routes open full-screen on phones; on
expanded widths, Library and Activity use a list/detail split (list 400 dp + detail) when the route is a child of the
tab.

---

## 2. Global patterns

### 2.1 States
- **Loading (first load):** skeleton placeholders shaped like the content (grey rounded boxes; poster grids show
  poster-shaped boxes). No full-screen spinners except for login.
- **Refresh:** pull-to-refresh on every scrollable screen; auto-refresh per the interval column (base value, scaled by
  the Refresh preset; paused when the app is backgrounded).
- **Error (first load failed):** `ErrorView` with an icon chosen by error code (`upstream_unavailable` → cloud_off,
  `service_not_configured` → settings, network → wifi_off), the `ApiError.message`, the service name, and a Retry button.
  `service_not_configured` shows "Not configured on the hub" with no retry.
- **Error (refresh failed, data shown):** keep the data, show `StaleBanner` "Couldn't refresh · showing data from 2 min ago".
- **Empty:** `EmptyView` with an icon, a short title and a hint; specified per screen.
- **Offline (no server reachable):** a top banner "Can't reach Zenith (tried LAN and Tailscale)" with "Retry" and
  "Server settings". Cached screens stay visible.
- **Member vs admin:** admin-only actions are hidden for members (not disabled). Admin-only screens redirect.

### 2.2 Formatting
Bytes binary units (GiB), speeds `12.3 MB/s` (decimal, like qBittorrent), relative times ("5 min ago") with the
absolute time in a tooltip/long-press, dates in the device locale, all instants converted to device local time,
`Date` fields shown as-is.

### 2.3 Feedback
Mutations show an inline progress state on the control (button spinner or switch disabled) and a SnackBar on
completion ("Search started" / error message). Commands and jobs show a small progress chip that polls
(`/library/commands/...` every 2 s, `/jobs/{id}` every 2 s) and turns into a result SnackBar.

### 2.4 Destructive-action confirmations
| Action | Dialog |
|---|---|
| Delete series/movie **without** files | `ConfirmDialog`: "Remove <title> from Sonarr? Files stay on disk." + checkbox "Add to import exclusion list" |
| Delete series/movie **with** files | `TypedConfirmDialog`: red, "Permanently delete <N> files (<size>)? There is no recycle bin." User must type the title. |
| Delete torrent | ConfirmDialog with radio "Keep files" / "Delete files (permanent)"; if the gateway answers `managed_by_arr`, a second dialog offers "Remove via Sonarr/Radarr instead" (blocklist + search again options) |
| Remove *arr queue item | ConfirmDialog with switches "Remove from qBittorrent" (on), "Blocklist release" (off), "Search again" (enabled only with blocklist) |
| Stop container | ConfirmDialog; gluetun adds "qBittorrent will lose network until gluetun is back" |
| Restart/start container in the confirm list | ConfirmDialog |
| Update container | ConfirmDialog "Pull the latest image and recreate <name>? It will be offline for a moment." |
| Delete a Seerr request | ConfirmDialog "Delete this request? Nothing is removed from the library." |
| Decline request | ConfirmDialog |
| Bazarr "Search all wanted" | ConfirmDialog "Search providers for 111 episodes?" |
| Revoke session / delete user | ConfirmDialog |
| Global *arr search | Hidden while `policy.allowGlobalSearch` is false; otherwise TypedConfirmDialog ("type SEARCH") |
| Jellyfin stop playback | ConfirmDialog "Stop playback for <user> on <device>?" |
| Share limit action "Remove" / "Remove with files" | ConfirmDialog with the gateway's `details.impact` ("qBittorrent will delete <name> and its files once ratio ≥ 1.0") |
| Grab a release the *arr rejected | ConfirmDialog listing the rejections ("Grab anyway?") |
| Manual import with "Move" mode | ConfirmDialog "Files are moved out of the download folder; the torrent stops seeding them" |
| Import into Seerr | ConfirmDialog "Create a Seerr account for <name> with the default permissions?" |

After confirming, the app sends `confirm=true` (ARCHITECTURE §5.12). If a non-GET action times out while receiving the
response, the app does **not** retry; it shows "Result unknown, refresh to check" and refreshes the screen
(ARCHITECTURE §7.4).

---

### 2.5 Notifications
The hub sends **no push notifications** in v1. Discord (`#alerts`, `#requests`, `#updates`) stays the out-of-app
channel, unchanged. Alerts appear in the app's Alerts panel when the dashboard loads, and every alert `route` is a
valid hub web URL path (`http://<hub>:8090/requests/list?tab=pending`), so links pasted into or generated for Discord
open the right hub screen. Badges stay fresh while the app is open (`navBadgesProvider`). A self-hosted ntfy push is a
v1.1 option (ARCHITECTURE §11).

### 2.6 Deferred to v1.1
Shelfmark book search/download in the hub (v1: status + launcher); step-up re-authentication for destructive admin
actions; ntfy push; Seerr webhooks; tag editing for series/movies.

## 3. Core screens (core-app slice)

### 3.1 Onboarding `/onboarding`
Shown when no server profile exists (not on the gateway-served web build).
- Fields: Name (default "Zenith"), LAN URL (default `http://192.168.10.183:8090`), Tailscale URL (optional, hint
  `http://zenith.<tailnet>.ts.net:8090`). "Test" pings each (`GET /ping`) and shows ✓ with latency or the error.
- "Continue" saves the profile (stores `instanceId` from the ping) and goes to `/login`.
- Validation: at least one URL must answer `/ping` with `name == "yams-hub"`; `apiVersion` must be 1 (otherwise "This hub
  needs a newer/older app"). Both URLs must report the same `instanceId`.
- Warning (amber, not blocking) on an `http://` URL whose host is not private/Tailscale: "This address is on the
  internet. Passwords and tokens would travel unencrypted." Hint under the fields: "On untrusted Wi-Fi the app uses the
  Tailscale URL".

### 3.2 Login `/login`
- Username, password (obscured, show toggle), "Sign in". Device name defaults to the platform model from
  `device_info_plus` ("Pixel 8", "iPhone", "Chrome on Linux"). `POST /auth/login` with `transport` cookie
  (gateway-served web, `/yh/api/v1`) or token; the token response's `serverProofKey` is stored with the tokens.
- Errors inline: `invalid_credentials` → "Wrong username or password"; `rate_limited` → "Too many attempts. Try again in
  N min" (from `retryAfterSeconds`); network → "Can't reach the hub" with the server picker link.
- Shows the active server name and URL with a "Change server" link (not on web).

### 3.3 Dashboard `/home` — interval 15 s (`GET /dashboard`); fast cards (`activity`, `system`, `media`) refreshed every 5 s with `?cards=activity,system,media` while visible
Layout: a responsive masonry of cards (1 column < 600 dp, 2 columns < 1200 dp, 3 columns above). Header: greeting,
server chip ("LAN"/"Tailscale" + host), last update time.

1. **Alerts panel** (core): top of the page, only when alerts exist. Rows sorted by severity with a colour bar, title,
   message, relative `since`; tap opens `route`. Dismissible alerts have a close button (stored per device by `id`).
   Collapses to "N more" after 3.
2. Cards, in this order (each owned by its feature, wrapped by core's `DashboardCardFrame` which handles `status:
   error/disabled`, stale badge, and the card title/icon/route):
   - **System** (system): CPU % with a 5-min sparkline, temperature, memory bar, volume bar (used/total), RAID chip
     ("RAID0 · active", amber info icon "no redundancy"), network ↓/↑ with a Tailscale dot, Uptime Kuma "19/21 up".
     Tap → `/system`.
   - **Now playing** (media): one row per session: thumbnail, title (series + SxxEyy), user · device, progress bar,
     play method chip ("Direct play" / "Transcode · QSV"), paused icon. Empty: "Nothing playing". Plus a line with library
     counts. Tap a session → `/media`; tap counts → `/media/jellyfin`.
   - **Downloads** (activity): ↓/↑ speed big numbers, alt-speed turtle chip, counts (downloading / seeding /
     attention), top 3 queue items with progress + ETA, VPN line ("VPN · France · port 36681 ✓" or red "VPN down").
     Tap → `/activity`.
   - **Upcoming** (calendar): next 7 days, max 8 rows grouped by day ("Today", "Tomorrow", weekday): poster thumb, title,
     subtitle, time. Empty: "Nothing scheduled this week". Tap → `/calendar`.
   - **Requests** (requests): counts row (pending · processing · available), admins see up to 5 pending requests with
     inline Approve / Decline buttons; members see their recent requests with status chips. Tap → `/requests/list`.
   - **Library** (library): two halves Sonarr / Radarr: items, missing, cutoff unmet, size on disk, free space,
     queue badge, health warnings count. Tap → `/library`.
   - **Containers** (containers): running/total, unhealthy names in red chips, updates available, top CPU. Tap → `/containers`.
   - **Indexers** (indexers): enabled/total, failing indexers with "retry at". Tap → `/indexers`.
   - **Subtitles** (subtitles): missing episodes / movies, SignalR status. Tap → `/subtitles`.
3. **Web apps** (core, always last, not a feature card): a compact grid of `WebAppTile`s (icon, name, status dot) for
   every service web UI from `GET /server` `externalApps` + `GET /health` (§3.5). Members see it too. "All apps" →
   `/home/apps`. Hidden apps (Settings > Appearance) are left out; the section hides when all are hidden.
- Cards can be hidden from Settings > Appearance ("Dashboard cards" checklist). Hidden cards are excluded from `?cards=`.
- Empty state for the whole page is impossible (system card is always there); if `/dashboard` fails entirely, show the
  ErrorView with "Server settings".

### 3.4 More `/more` (phone only)
List tiles with icon + subtitle (live counts from `navBadgesProvider`, raw dashboard keys of API.md §4): **Web apps**
("13 apps · 12 up") → `/home/apps`, Calendar ("6 episodes this week"), Media, Containers ("21 running"), Indexers
("1 failing"), Subtitles ("111 missing"), System, Settings.

### 3.5 Web apps `/home/apps` (core) — interval 30 s (health)
The Homepage-replacement launcher. Responsive grid of `WebAppTile`s, grouped Media (Jellyfin, Audiobookshelf, Kavita,
Seerr, Shelfmark, Jellystat), Automation (Sonarr, Radarr, Prowlarr, Bazarr), Downloads (qBittorrent), System
(Uptime Kuma, Portainer). Tile: Material icon in a tinted circle (no brand assets), name, status dot (`/health`; none
for Portainer), version. Tap → `openExternal(ExternalLink(app, '/'))` (new browser tab on web). Long-press → "Copy
link". Visible to members and admins (members may not have accounts in the admin UIs; the tile still opens them).
Empty impossible; `/server` failure → ErrorView. Apps can be hidden per device in Settings > Appearance.

---

## 4. Requests (requests slice)

### 4.1 Discover `/requests` — interval: none (manual), cache-friendly
- Top: search field (submits to `/requests/search?q=`; no search-as-you-type), filter chips "All / Movies / Series".
- Horizontal carousels (each "See all" → a full grid route `/requests/discover/:slider` handled inside the feature):
  Trending (`GET /discover/trending?mediaType=`), Popular movies (`/discover/popular-movies`), Popular series
  (`/discover/popular-tv`), Upcoming movies, Upcoming series, Your watchlist (`/discover/watchlist`: the caller's own
  Seerr watchlist; empty for unlinked members, and the carousel is hidden when empty).
- `TitleCardTile`: poster 2:3, title, year, availability badge in the corner (Available green ✓, Partial half-filled,
  Requested/Processing clock, Pending hourglass). Tap → title detail.
- Admins: an app-bar action "Requests" with the pending count badge → `/requests/list?tab=pending`. Members: "My requests".
- Loading: carousel skeletons. Error per carousel (inline retry) so one failing slider doesn't blank the page.

### 4.2 Search `/requests/search?q=`
Infinite grid (`GET /search?q=&page=`), stops at `totalPages`. Empty: "No titles match '<q>'". Prefix hint below the
field: "Tip: tmdb:603, imdb:tt0133093, tvdb:81189".

### 4.3 Title detail `/requests/title/:mediaType/:tmdbId`
`GET /titles/movie/{id}` or `/titles/tv/{id}`; ratings lazily (`/ratings`); recommendations/similar carousels lazily.
- Header: backdrop (16:9) with gradient, poster, title, year · runtime · certification, genres chips, vote average,
  RT/IMDb scores when loaded.
- Primary action button by state:
  - `canRequest` → "Request" (movie: one tap with confirm SnackBar; tv: opens **season picker sheet**).
  - availability available → "Play in Jellyfin" (`media.jellyfin` link) + secondary "Report issue".
  - partial → "Request more" (season picker) + "Play in Jellyfin".
  - pending/processing → disabled "Requested" with status, plus download progress bars from `media.downloads`.
  - `reason: notLinked` → disabled "Request" with the explanation "Your account isn't linked to Seerr. Ask the admin."
- Season picker sheet (tv): checklist of `seasons` (name, episode count, air year, availability chip); non-requestable
  rows disabled with their status; "Select all requestable"; footer "Request N seasons". Admin-only "Advanced" expander:
  server, quality profile, root folder (`GET /requests/options`); hidden for members.
- Quota line (members with a limit, from `meProvider` `seerr.quota`): under the Request button and in the season
  sheet footer, "3 of 5 movie requests left this week" (or "No requests left until <date>" when `remaining == 0`, and
  the button is disabled with that text). Unlimited quotas show nothing.
- Request result handling: `created` → SnackBar "Requested" (members: "Waiting for approval"); `autoApproved` →
  "Requested · sent to Sonarr"; `nothingToRequest` → "Everything is already requested"; `already_requested`,
  `quota_exceeded` (with the quota line from `details.quota`), `blocklisted` → SnackBar with message.
- Body: tagline, overview, trailer button (opens YouTube URL), cast carousel (profile images), directors/creators,
  networks, "Where to watch (ZA)" provider logos, collection link, existing requests list (status + requester), open
  issues count.
- "Report issue" sheet: type (Video / Audio / Subtitles / Other segmented), season/episode pickers (tv), message field;
  `POST /issues`. Hidden when `media` is null.
- Not found (404): EmptyView "This title doesn't exist on TMDB".

### 4.4 Requests list `/requests/list?tab=` — interval 30 s
Tabs: **Pending** (admin only), **Mine**, **All** (admin), **Failed** (admin). `GET /requests?filter=&mine=&page=`
infinite list; `GET /requests/counts` for tab badges.
- Row: poster, title + year, type icon, season chips ("S1 S2"), requester avatar + name, relative time, status chip
  (Pending amber, Approved blue, Processing blue with progress, Available green, Declined grey, Failed red).
- Admin row actions: Pending → Approve (✓) / Decline (✗, confirm); Failed → Retry; overflow → Delete (confirm).
  Members: overflow Delete on their pending requests.
- Swipe actions on phones: right = approve, left = decline (pending tab only).
- Tap → request detail `/requests/list/:id` (`GET /requests/{id}`): all fields, seasons with per-season status,
  profile name, modified by, link to the title detail and "Open in Library" when `libraryId` is present
  (`AppPaths.seriesDetail(libraryId)` for tv, `AppPaths.movieDetail(libraryId)` for movies).
- Empty: Pending → "No requests waiting"; Mine → "You haven't requested anything yet" + "Discover" button.

### 4.5 Issues `/requests/issues` and `/requests/issues/:id` — interval 60 s
List with filter chips Open / Resolved / All (`GET /issues`). Row: poster, title, type icon, "S2E5" when set, creator,
relative time, comment count (`commentCount`). Detail: comment thread, compose field (`POST /issues/{id}/comments`),
Resolve / Reopen shown to admins and to the issue's creator (Seerr enforces it; a 403 shows "Only the reporter or an
admin can do that"). Unlinked members see the list read-only with "Link your account to Seerr to comment". Empty:
"No open issues".

---

## 5. Library (library slice)

### 5.1 Library `/library` — tabs TV | Movies | Wanted; interval 60 s (lists), 30 s (header)
- Header strip (`GET /library/summary`): per app "71 series · 892 missing · 2.8 TB · 4.0 TB free", health warning icon
  (tap → bottom sheet listing `health` messages with wiki links).
- **TV tab** (`GET /library/tv?filter=&sort=&q=`): search field (local filter as you type, server `q` not needed since
  the list is complete), filter chips (All, Monitored, Missing, Continuing, Ended, Anime, Upcoming), sort menu (Title,
  Added, Next airing, Size, Missing, Year), view toggle grid/list (remembered).
  - Grid tile: poster-250, progress ring/bar (`percentComplete`), missing count badge (red) when > 0, unmonitored
    overlay (dimmed + bookmark-off icon), anime "A" chip.
  - List row: poster thumb, title, network · year · status, `episodeFileCount/episodeCount`, size, next airing.
  - FAB (admin): "Add series" → `/library/add?kind=tv`.
- **Movies tab** (`GET /library/movies`): same pattern; filters All, Monitored, Missing, Available, Unreleased, Cutoff
  unmet; tile badges: file quality chip ("1080p Bluray"), missing (no file) red dot, "Not released" grey chip.
  FAB (admin): "Add movie".
- **Wanted tab**: segmented Sonarr | Radarr and Missing | Cutoff unmet (`GET /library/wanted/{kind}?service=`),
  infinite list. Row: poster, title, episode label + title / year, air date or "Not released yet" (unavailable movies),
  current → cutoff quality for cutoff rows, last searched. Admin: multi-select mode (long-press) with "Search selected"
  (`POST /library/wanted/search`). No "search all" button unless policy allows (then behind a typed confirm).
- Empty: TV "No series yet" + Add button; filter with no results: "No series match these filters" + "Clear filters".

### 5.2 Series detail `/library/tv/:id` — interval 30 s
`GET /library/tv/{id}`. Layout: fanart header, poster, title, year · network · status · runtime, profile chip,
series type chip, monitor toggle (admin), tag chips (`series.tags`, read-only).
- Action row (admin): **Search** (menu: Search monitored / Search missing), **Refresh**, **Edit** (sheet: monitored,
  quality profile, series type with a warning "Changes how future releases are searched and named", monitor new seasons),
  overflow **Delete** (dialog per §2.4). "Open in Sonarr" (external link `sonarr`, admin) and TVDB/IMDb links.
- **Choose release** (admin, [long]): in the episode overflow ("Choose release…", `GET /library/tv/episodes/{id}/releases`)
  and the season overflow (`GET /library/tv/{id}/seasons/{n}/releases`). Opens the **Release picker sheet**: spinner
  with elapsed seconds ("Searching indexers… up to 2 min"), then a list sortable by score/size/age/seeders: title,
  quality chip, custom-format score, size, age, seeders/leechers, indexer, language chips, "Season pack" chip;
  rejected releases are greyed with their rejection reasons (expandable) and sorted last. Tap → "Grab" (confirm for
  rejected ones) → `POST /library/releases/grab` → SnackBar "Sent to qBittorrent via Sonarr" and the episode shows
  "downloading" after the next refresh. `404` → "Results expired, search again".
- Stats row: episodes `62/110`, missing 48, size, next airing.
- Seasons list (specials last): season tile with monitored bookmark toggle (admin, `PATCH .../seasons/{n}`), progress
  `files/episodes`, size, next airing; tap expands inline on tablets or opens `/library/tv/:id/season/:n` on phones.
- Episode row: label (`S03E01 (049)` for anime), title, air date (local), monitored bookmark toggle (admin,
  `PATCH /library/tv/episodes`), file status icon (✓ quality chip / missing / unaired / downloading with %),
  overflow: Search episode (admin), File info sheet (MediaFileInfo: quality, size, codecs, audio/sub languages, release
  group, custom format score).
- Multi-select episodes (long-press, admin): Monitor / Unmonitor / Search selected.
- Recent history section (first 5 of `GET /library/tv/{id}/history`) with "See all" → `/library/history/sonarr/:id`.
- 404: EmptyView "Series not found (it may have been deleted)" + Back.

### 5.3 Movie detail `/library/movies/:id` — interval 30 s
`GET /library/movies/{id}`: fanart, poster, title, year · runtime · certification · studio, release dates
(cinema / digital / physical), availability chip, monitor toggle (admin), profile + minimum availability chips.
Actions (admin): Search, Refresh, **Choose release** (the release picker sheet of §5.2 with
`GET /library/movies/{id}/releases`), Edit (monitored, profile, minimum availability), Delete. Tag chips. File card:
MediaFileInfo, cutoff-not-met warning. Queue progress if downloading. History preview + "See all". Trailer button.

### 5.4 Add new `/library/add?kind=tv|movie&term=` (admin)
- Search field (submit-only; lookups take ~0.5 s), results list (`GET /library/{tv|movies}/lookup?term=`): poster,
  title, year, network/studio, overview (2 lines), "In library" chip (tap → detail) for `inLibrary`.
- Tap a new result → **Add sheet**: quality profile dropdown (pre-selected from `suggested`), root folder dropdown with
  free space, series type segmented (Standard / Anime / Daily; pre-selected; anime hint "Anime detected from genres"),
  monitor dropdown (All, Future, Missing, Existing, First season, Latest season, Pilot, None), season folders switch,
  "Start searching for missing episodes" switch (default on), "Also search cutoff unmet" (off). Movies: profile, root
  folder, minimum availability (Released default), monitor (Movie only / Movie and collection / None), "Search on add".
  Options from `GET /library/profiles`. "Add" → `POST /library/tv|movies` → navigate to the new detail.
- Errors: `already_exists` → "Already in your library" + open button.
- Empty results: "Nothing found for '<term>'".

### 5.5 History `/library/history/:service/:id`
Infinite `PagedList<ArrHistoryItem>`: event icon (grabbed: download, imported: check, failed: error, deleted: delete), source title,
quality chip, indexer/release group, size, date, reason for deletes.

---

## 6. Activity (activity slice)

### 6.1 Activity `/activity` — tabs Queue | Torrents | History
**Header (all tabs):** transfer bar (`GET /transfer` every 2 s while visible): ↓ speed, ↑ speed, alt-speed turtle
toggle (admin; `PUT /transfer/alt-speed`; caption "Scheduled 08:00–17:00" when the scheduler is on, with an info tooltip
"The schedule overrides manual changes at the next boundary"), connection status dot, VPN chip (`GET /vpn` every 30 s;
tap → VPN sheet with public IP, location, forwarded port vs listen port, gluetun health, "Restart VPN" (admin; →
container action on gluetun with confirm)). Overflow (admin): "Speed limits & session" → `/activity/transfer`.

**Queue tab** — interval 3 s (`GET /activity/queue?filter=`): filter chips Active (default) / Downloading / Seeding /
Needs attention / All.
- `QueueItemTile`: poster (arr) or file icon, title, subtitle ("Sonarr · S04E01–E24"), state chip, progress bar with
  %, size left, ETA, speeds; attention items get an amber/red left border and the first message ("Manual import needed:
  No files found are eligible…").
- Tap → torrent detail (when `torrent` present) or an arr item sheet (messages, mediaTitle link to the Library detail).
- **Attention items** with `canManualImport` show two buttons on the tile: **"Import…"** (opens the manual-import
  sheet) and **"Open in Sonarr/Radarr"** (the entry's `links[0]`, the *arr queue page, as the fallback).
- **Manual-import sheet** (admin; also opened by `/activity?tab=queue&import=<key>` from the `queue.import.<key>`
  alert; when the item is gone: SnackBar "Already resolved"): `GET /activity/queue/{service}/{queueId}/import`. List
  of candidate files: relative path, size, quality chip, language chips, matched series/episodes (or movie), and
  rejection reasons in red. Each row has a checkbox (pre-checked when `importable`) and an "Edit match" action (Sonarr:
  pick episodes of the matched series from `GET /library/tv/{seriesId}`; Radarr: shows the matched movie). Footer:
  import mode (Auto / Move / Copy; Move asks for confirmation) and "Import N files" → `POST /activity/queue/import` →
  command chip (polls `GET /library/commands/...`) → SnackBar and queue refresh. Empty: "Sonarr found no files to
  import" + "Open in Sonarr".
- Admin actions (overflow / swipe): Stop/Start, Remove (arr dialog §2.4 → `POST /activity/queue/remove`), Grab (for
  delayed), Protect/Unprotect ("Keep" tag), Import… (when `canManualImport`), Open in Library.
- Empty: "No active downloads" with a subtle "Seeding: 12" link to the Torrents tab.
- Source errors: an inline banner per failing source ("Radarr unreachable, its queue isn't shown").

**Torrents tab** — interval 2 s (`GET /torrents?filter=&category=&sort=`): filter chips (All, Downloading, Seeding,
Stopped, Stalled, Errored), category dropdown, sort menu, search field (local). Row: name, state icon + colour, progress,
size, ratio, ↓/↑ speed, ETA, category chip, "Keep" shield icon, a red tracker icon when `hasTrackerError` (no tracker
works; one failing tracker among working ones is not an error). Multi-select (long-press, admin): Start, Stop, Force
start, Recheck, Reannounce, Set category, Add/remove tag, Delete (§2.4, handles `managed_by_arr`).
Admin FAB **"Add torrent"** → the Add-torrent sheet (§6.4). Empty: "qBittorrent has no torrents".

**History tab** (`GET /activity/history?types=&service=`, cursor paging, manual refresh): filter chips Grabbed /
Imported / Failed / Deleted, service segmented All / Sonarr / Radarr. Row as in §5.5 plus media title and poster; tap
opens the Library item.

### 6.2 Torrent detail `/activity/torrent/:hash` — interval 2 s
`GET /torrents/{hash}`. Header: name, state chip, "Tracker error" chip only when no tracker works
(`TorrentDetail.hasTrackerError`), big progress, ↓/↑ speeds, ETA, ratio. Sections:
- General (KeyValueList): size, downloaded/uploaded, seeds/peers (connected/total), added/completed, save path, pieces,
  time active, seeding time, category, tags, comment.
- Share limits (admin editable sheet): Use global / Unlimited / Custom (ratio, seeding minutes, inactive minutes, action)
  → `PUT /torrents/{hash}/share-limits`; the actions "Remove" and "Remove with files" go through the 428 →
  ConfirmDialog → `confirm=true` flow (§2.4).
- Files: tree-ish list (path segments), progress, size, priority dropdown (admin; Skip/Normal/High/Max).
- Trackers: host (the gateway already strips paths/passkeys), status chip, message, seeds/peers; the card header says
  "N of M failing" when some trackers fail (not an error while another works).
- *arr link card when managed: "Tracked by Sonarr: <series> S04" → Library.
- Actions (admin): Stop/Start, Force start, Recheck, Reannounce, Protect toggle, Set category, Delete.
- 404 → "Torrent no longer exists" (decluttarr may have removed it) + Back.

### 6.3 Transfer settings `/activity/transfer` (admin)
Normal and alternative limits (KiB/s inputs, 0 = unlimited) → `PUT /transfer/limits`; alt-speed switch; schedule
display (read-only: "Configure the schedule in qBittorrent"); "Pause all torrents" / "Resume" session switch
(`PUT /transfer/session`); global ratio, all-time totals, free space, DHT nodes.

---

### 6.4 Add torrent (admin) — sheet, also routable as `/activity/add?url=`
Opened by the Torrents FAB, or by a `magnet:` link handed to the app (Android intent filter / iOS URL type, routed by
core to `/activity/add?url=<magnet>`; members get "Admins only").
- **Magnet or URL** multi-line text field (one per line; pre-filled from `url=`), validated client-side
  (`magnet:?xt=urn:btih:` or `http(s)://`).
- **.torrent file** picker (web build only: a hidden `<input type="file" accept=".torrent">` through `package:web`,
  behind a conditional import inside the activity feature; read as bytes → base64; max 5 files, 5 MB each). Not shown
  in the phone apps (no file-picker package).
- **Category** dropdown from `GET /transfer/categories` (default `manual`). Choosing `tv-sonarr` or `radarr` shows a
  warning: "Sonarr/Radarr did not grab this, so they will not import it. Use Library > Choose release instead."
  Read-only categories (`books`, `lidarr`) are not offered.
- **Tags** chips (from the same call), **Start stopped** switch.
- "Add" → `POST /torrents/add` → SnackBar "Added to qBittorrent" and switch to the Torrents tab; 422 → "qBittorrent
  rejected this torrent".

## 7. Calendar (calendar slice) `/calendar` — interval 5 min

`GET /calendar?start=&end=` with a 3-week window from yesterday; scrolling to the end loads the next 2 weeks (max one
62-day window per request).
- Agenda list grouped by local date with sticky day headers ("Today · Sun 8 Nov"). Row: time (episodes) or release-type
  chip (movies: Cinema / Digital / Physical), poster thumb, title, subtitle, status icon (✓ downloaded, ↓ downloading,
  ◯ missing/unaired, unmonitored dimmed), finale badge.
- Filter chips: Episodes, Movies, Show unmonitored. "Today" FAB scrolls back to today.
- Tablet/web: a month grid on the left (dots per day), agenda on the right.
- Tap → `/library/tv/:seriesId` or `/library/movies/:movieId`.
- Empty: "Nothing airing in this period".

---

## 8. Media (media slice) `/media` — tabs Now playing | Stats | Apps

### 8.1 Now playing tab — interval 5 s
`GET /media/now-playing`. Cards per session: backdrop/primary image, title, series/episode, user avatar + name, client
· device, progress bar with position/runtime, play-method chip; transcoding sessions expand to show codec → codec,
"HW: QSV", reasons as chips, bitrate. Admin actions: Pause/Resume, Stop (confirm), Send message (dialog). Tap title →
Jellyfin external link. Empty: "Nothing is playing right now" with Jellyfin's continue-watching row below
(`GET /media/jellyfin` `continueWatching`).

### 8.2 Stats tab — interval 5 min
`GET /media/stats?days=` with a period selector (7 / 30 / 90 / 365 days).
- Totals row (plays, watch time).
- Views over time: stacked bar chart per library (`fl_chart`), legend by library.
- By weekday and by hour: small bar charts.
- Play methods: donut (Direct play / Direct stream / Transcode) with percentages.
- Top movies / top series / popular series: horizontal poster lists with play counts.
- Top users, top clients, top libraries: ranked lists.
- "Users" button → `/media/stats/users` (`GET /media/stats/users`: avatar, plays, watch time, last seen, last watched;
  tap → playback history filtered by user `GET /media/stats/history?userId=`).
- Empty (Jellystat has almost no data yet): "Not enough watch history yet. Stats fill in as people watch." Charts show
  an empty frame rather than nothing.

### 8.3 Apps tab — interval 60 s
`GET /media/apps`. Large tiles (Jellyfin, Audiobookshelf, Kavita, Seerr, Shelfmark): app icon (Material icon in a tinted
circle; no brand assets), name, status dot, version, headline, buttons "Open app" (custom scheme / store / web per
ARCHITECTURE §7.10; Shelfmark: web only) and "Open web". Below them a "All web apps" link → `/home/apps`. Tap the tile
body → details route:
- **Jellyfin** `/media/jellyfin` (`GET /media/jellyfin`): counts, libraries (size, files, refreshing spinner), recently
  added grid (tap → Jellyfin web link), continue watching, next up; admin "Scan libraries" (`POST /media/jellyfin/library/refresh`).
- **Audiobookshelf** `/media/audiobooks` (`GET /media/audiobooks`): library stats (items, authors, total duration,
  size), continue listening (cover, progress ring, time left, tap → ABS web item), recently added, listening today and a
  7-day bar chart. A dismissible info card: "Some authors and narrators look swapped: check the folder naming in ABS".
- **Kavita** `/media/books` (`GET /media/books`): `auth == missingKey` → setup card "Create an Auth Key in Kavita
  (User settings → Auth Keys) and add it to the hub's env file as KAVITA_API_KEY"; `rejected` → "Kavita rejected the
  key"; otherwise stats, on deck, recently added, and the `hint` empty state ("Kavita needs one folder per series").
- **Seerr** tile opens `/requests`.
- **Shelfmark** `/media/shelfmark` (`GET /media/shelfmark`, interval 30 s): status (coordinator running/stopped with a
  warning banner when stopped), queue (active / queued / awaiting pickup), requests (pending / delivered / failed /
  cancelled / rejected), added in the last 7 / 30 days (ebooks vs audiobooks), failed in 7 days, and a big
  "Open Shelfmark to find books" button (web UI). Footnote: "Downloads land in Audiobookshelf and Kavita once
  imported." Searching and requesting books inside the hub is v1.1. Empty (all zero): "No book downloads yet".

---

## 9. Containers (containers slice)

### 9.1 Containers `/containers` — interval 10 s
`GET /containers`. Top summary: running/total, engine version, "Updates (N)" button → `/containers/updates`,
"Maintenance" button → `/containers/maintenance`.
- Grouped list (Media, Automation, Downloads, System, Other) with collapsible headers. Row: state dot (green running,
  grey exited, amber restarting), name, health chip (healthy/unhealthy/starting; nothing for `none`), uptime, CPU %
  and memory (small inline bars), image version, "update" dot, lock icon for locked, link icon for `sharesNetworkWith`.
- Search field and filter chips (All, Running, Stopped, Unhealthy, Updates).
- Admin row actions (overflow): Restart, Stop/Start, Update (if `canUpdate` and update available), Logs, Open web UI.
  Locked containers show the actions disabled with "Protected".
- Empty impossible; error → ErrorView ("Docker proxy unreachable").

### 9.2 Container detail `/containers/:name` — interval 10 s
`GET /containers/{name}`: header (name, image, version, state, health, uptime), live CPU/mem/net (from summary fields
and a client-side 2-min sparkline built from refreshes), KeyValueList (restart count, started/finished, exit code,
OOM killed, restart policy, network mode, ports, mounts (destination + ro/rw), image id short), health log (last 5:
time, exit code; admins also see the redacted, 200-char output in monospace), recent events timeline, dependency hints ("Restarting gluetun also restarts
qbittorrent"). Actions (admin): Restart / Stop / Start / Update / Logs. Job progress inline (job chip polling `/jobs/{id}`).

### 9.3 Logs `/containers/:name/logs` (admin) — manual refresh + "Follow" toggle (polls every 3 s with `since=<last>`)
`GET /containers/{name}/logs?tail=`: monospace list, stderr lines tinted, timestamps (toggle), tail selector (200 /
500 / 2000), stream filter (All / stdout / stderr), text filter, "Copy" (copies visible lines). If logs are disabled
→ EmptyView "Logs need ALLOW_LOGS=1 on socket-proxy-hub".

### 9.4 Updates `/containers/updates` — manual
`GET /updates`: a **Watchtower last scan** strip from `lastScan` (scanned / updated / failed / skipped, "last scan 3 h
ago"), shown whenever present, also when `available == false`. Then "Last checked 2 h ago" + "Check now" (admin;
`POST /updates/check` → job chip). List: name, current
version, status (Update available / Up to date / Pinned tag / Error), auto-update badge for the 7 infra containers
("Auto-updated by Watchtower"). Admin "Update" per row (confirm) → job sheet showing steps and streaming log lines.
When `available == false`: info card explaining the Watchtower env change (`WATCHTOWER_HTTP_API_ENDPOINTS=metrics,check,containers,history`).
When `updaterAvailable == false`: "Update now" hidden and a note "Run `yams update-containers` on the NAS".

### 9.5 Maintenance `/containers/maintenance` — interval 60 s
Two cards:
- **Decluttarr** (`GET /maintenance/decluttarr`): state, last run / next run, test-mode banner if on, 24 h removed list
  (title, job, time), strikes list, warnings/errors. Empty: "Queues are clean: nothing removed in the last 24 h".
- **Recyclarr** (`GET /maintenance/recyclarr`): schedule ("Sundays 04:00"), next run, last run result per instance
  (custom formats created/updated/skipped, profiles synced, ✓/✗), warnings. Admin "Sync now" (confirm; needs updater).

---

## 10. Indexers (indexers slice)

### 10.1 Indexers `/indexers` — interval 60 s
`GET /indexers`. Health messages banner at top (Prowlarr health). List: name, status chip (OK / Failing until 19:06 /
Disabled), protocol/privacy chips, FlareSolverr icon, priority, 30-day stats (queries, grabs, failure %, avg
response ms). Admin: enable switch per row (`PATCH /indexers`, optimistic), long-press multi-select → Enable / Disable /
Set priority (number dialog 1–50) / Test selected. App bar (admin): "Test all" (job; results sheet listing each
indexer ✓/✗ with failure messages), "Search" → `/indexers/search`, "History" → `/indexers/history`.
Empty: "No indexers configured in Prowlarr".

### 10.2 Indexer detail `/indexers/:id`
Fields, stats, failure timeline (`failingSince`, `lastFailure`, `disabledTill`), categories, base URL (tap opens),
admin "Test" (job, spinner up to 150 s with "FlareSolverr can take up to 2 minutes"), enable switch, priority.

### 10.3 History `/indexers/history`
Infinite list (`GET /indexers/history`), filter chips Grabs / Queries / RSS / Failed only, indexer dropdown. Row: type
icon, indexer, query or grab title, source app, results, elapsed ms, time, red ✗ when unsuccessful.

### 10.4 Manual search `/indexers/search` (admin)
Form: query, type (General / TV / Movie / Music / Book), indexers multi-select, categories multi-select (from
`/indexers/categories`). "Search" (explicit only; spinner with elapsed seconds; up to 150 s). Results table/list sortable
by seeders, size, age: title, indexer, size, age, seeders/leechers, categories. Tap → sheet with "Grab to qBittorrent"
(category dropdown, default `manual`; `POST /indexers/grab`) and "Open info page". A note: "For TV and movies prefer
the Library search, so Sonarr/Radarr track the download". Empty: "No releases found".

---

## 11. Subtitles (subtitles slice) `/subtitles` — tabs Episodes | Movies | History; interval 60 s

Header (`GET /subtitles/summary`): missing counts, SignalR chips (Sonarr/Radarr live/down), providers row (name +
status chips; throttled shows retry time), health issues. Admin overflow: "Search all missing episodes/movies"
(confirm), "Reset providers", "Tasks" sheet (list with interval, next run, running spinner, "Run now").
- **Episodes / Movies** (`GET /subtitles/wanted?type=`): infinite list. Row: poster, title, episode label + title,
  missing language chips (with "forced"/"HI" markers). Admin: tap a language chip → `POST /subtitles/search` (chip shows
  a spinner; jobs polled via `GET /subtitles/jobs` every 3 s while any search is running), overflow "Search all for this
  series/movie".
- **History** (`GET /subtitles/history?type=`): action icon, title, language, provider, score, time, description.
- Empty: "No missing subtitles" with a check icon.

---

## 12. System (system slice) `/system` — interval 5 s (host), 30 s (uptime), 30 s (health)

- **Host card** (`GET /system/host`): CPU % + per-core bars, load averages, package and core temperatures, memory and
  swap bars, uptime, CPU model. Charts (`GET /system/history?metric=&range=`) with a 1 h / 24 h toggle: CPU, temperature,
  network ↓/↑, disk read/write.
- **Storage card:** `/volume1` used/free bar, RAID panel: "RAID0 · md1 · active · sda2 + sdb2" with a persistent amber
  note "No redundancy: one disk failure loses all data. Keep backups."; red banner if not active.
- **Network card:** eth0 and tailscale0 throughput (Tailscale shows "Remote use" when traffic flows).
- **Uptime card** (`GET /uptime`): incident banner when pinned; groups with monitors: name, status dot, 30-beat bar
  (coloured ticks), 24 h uptime %, ping for http monitors.
- **Service health card** (`GET /health`): every service with status, latency, version, message; tap a service row
  opens the related screen (sonarr → Library, qbittorrent → Activity, shelfmark → `/media/shelfmark`, ...).
- Missing sources: "CPU temperature unavailable (no coretemp sensor under /sys/class/hwmon)"; "Host network
  unavailable (mount /proc/1/net/dev into the hub)".

---

## 13. Settings (settings slice) `/settings`

Grouped list:
- **Server**: active profile name + URL + LAN/Tailscale chip → `/settings/servers` (hidden on gateway-served web).
  - Servers list: profiles with active radio, edit, delete (confirm), "Add server". Edit `/settings/servers/:id`: name,
    ordered URL list (drag to reorder, add/remove, "Test" each with latency), "Sign out of this server".
- **Account**: signed in as `<displayName>` (role chip) → `/settings/account` (change password: current, new, confirm,
  strength hint; `POST /auth/password`), "Sign out" (`POST /auth/logout`).
- **Sessions** `/settings/sessions` (`GET /auth/sessions`; admins toggle "All users"): device, platform icon, IP,
  created, last seen, "This device" chip; revoke (confirm, `DELETE /auth/sessions/{id}`).
- **Users** (admin) `/settings/users` (`GET /admin/users`): list with role, linked Jellyfin user, disabled state. Add/
  edit `/settings/users/:id`: username (create only), display name, role, password (create/reset), Jellyfin user dropdown
  (`GET /admin/jellyfin-users`, shows the matching Seerr account, or "No Seerr account" with an **"Import into Seerr"**
  button → confirm → `POST /admin/jellyfin-users/{id}/import-to-seerr` → the row shows the new Seerr account), disabled
  switch, delete (confirm). The users list shows a "No Seerr account" chip for members whose Jellyfin user is not in
  Seerr (they cannot request until imported).
- **Audit log** (admin) `/settings/audit` (`GET /admin/audit`): infinite list; filter by user and action prefix; row:
  time, user, action, target, outcome chip; tap → params JSON viewer.
- **Appearance** `/settings/appearance`: theme mode (System / Dark / Light), dynamic color switch (Android 12+),
  accent seed picker (6 swatches), dashboard cards checklist and order (drag), **web apps checklist** (hide apps from
  the launcher; stored in `appSettingsProvider.hiddenLauncherApps`), list density (comfortable/compact).
- **Refresh** `/settings/refresh`: preset (Fast / Normal / Battery saver / Manual) with a table of the resulting
  intervals; "Refresh on app resume" switch (default on).
- **Media apps** `/settings/apps`: per app (every ExternalApp: Jellyfin, Audiobookshelf, Kavita, Seerr, Shelfmark and
  the admin web UIs of the launcher): base URL override (default derived from the hub host + port from `GET /server`),
  custom app URL scheme (Jellyfin/ABS only, e.g. `jellyfin://`), "Test open". (The Kavita Auth Key is **not** set here:
  it is a gateway secret, see `/media/books`.)
- **About** `/settings/about`: app version/build, gateway version (`GET /server`), API version, instance id, service
  health summary (`GET /health`), public URLs with copy buttons, the note "On untrusted Wi-Fi, use the Tailscale URL",
  open-source licenses (`showLicensePage`).

All settings except server/account are stored locally (SharedPreferences) per device.

---

## 14. Refresh interval summary (base values, Normal preset)

| Screen / data | Interval |
|---|---|
| Dashboard full | 15 s |
| Dashboard fast cards (activity, system, media) | 5 s |
| Torrents list, torrent detail, transfer bar | 2 s |
| Unified queue | 3 s |
| Now playing | 5 s |
| Host metrics | 5 s |
| Containers list/detail | 10 s |
| Requests list, Library header, VPN, uptime, health, web apps, nav badges, Shelfmark | 30 s |
| Library lists, indexers, subtitles, Kavita/ABS, maintenance, media apps | 60 s |
| Calendar, stats | 5 min |
| Discover, search, title detail, history, updates, logs | manual (pull-to-refresh) |

Presets multiply: Fast ×0.5 (min 1 s), Battery saver ×3, Manual = no timers.

---

## 15. Ownership of app files

| Path | Slice |
|---|---|
| `app/lib/main.dart`, `app/lib/app.dart`, `app/lib/core/**`, platform folders, `app/test/core/**`, `app/test/support/**` | core-app |
| `app/lib/features/<feature>/**`, `app/test/features/<feature>/**` | the feature slice (`requests`, `library`, `activity`, `calendar`, `indexers`, `subtitles`, `containers`, `system`, `media`, `settings`) |

Route constants used across features (e.g. Activity linking to `/library/tv/54`) are built with the `AppPaths` helpers
from core (full list in ARCHITECTURE §7.3: `AppPaths.seriesDetail(id)`, `AppPaths.movieDetail(id)`,
`AppPaths.torrent(hash)`, `AppPaths.container(name)`, `AppPaths.title(mediaType, tmdbId)`, `AppPaths.activity(tab:)`,
`AppPaths.mediaShelfmark()`, `AppPaths.webApps()`, ...), so features never import each other. Core also owns
`app/lib/core/launcher/**`, `app/lib/core/jobs/**`, `app/lib/core/intents/**` and deletes the generated
`app/test/widget_test.dart`.
