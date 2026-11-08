# YAMS Hub gateway: system integrations

Scope: Docker Engine (read and control), container updates (Watchtower), host metrics, Uptime Kuma,
Audiobookshelf, Kavita, Decluttarr, Recyclarr.

Everything here was probed on Zenith (192.168.10.183) on 2026-11-08 using **GET requests only**, plus one
Kavita login attempt, which failed (see section 7). Write endpoints were taken from upstream source at the exact
running revision and were **not called**. All secrets are redacted. Fixtures are in `fixtures/system/` (index in section 10).

Versions observed:

| Component | Version | Evidence |
|---|---|---|
| Docker Engine | 29.4.3, API 1.54 (min 1.40), cgroup v2, overlay2, root `/volume1/@docker` | `GET /version`, `/info` |
| socket-proxy (read-only) | lscr.io/linuxserver/socket-proxy 3.4.7-r0-ls105 (HAProxy) | image label |
| Watchtower | nickfedor/watchtower **1.24.0** (rev 147aa6a5), Docker API v1.54 | label + startup log |
| Uptime Kuma | 2.5.9 (`louislam/uptime-kuma:2-slim`) | `/app/package.json` |
| Audiobookshelf | 2.37.2 | `GET /status` |
| Kavita | **v0.9.1.4** (image rev d77d956b, built 2026-09-02; assembly reports 1.0.0) | image label + GitHub release |
| Decluttarr | v2.2.0 (commit 1937250) | image label |
| Recyclarr | v8.8.1 | `recyclarr --version` |
| Host | Intel N100 (4 cores), 7.87 GiB RAM, Debian 12 based UGOS, kernel 6.18.15 | `/proc`, `/info` |

---

## 0. Connection summary for the gateway (`yams-hub` on `yams_network`)

| Upstream | Base URL from the gateway | Auth |
|---|---|---|
| Docker (read) | `http://socket-proxy:2375` (existing; see section 1) **or** the hub's own proxy | none (network-level) |
| Docker (control) | `http://socket-proxy-hub:2375` (new; see section 2) | none (network-level) |
| Watchtower | `http://watchtower:8080` | `Authorization: Bearer <WATCHTOWER_HTTP_API_TOKEN>` |
| Uptime Kuma | `http://uptime-kuma:3001` | none (public status page `zenith`) |
| Audiobookshelf | `http://audiobookshelf:80` (host port 13378) | `Authorization: Bearer <ABS API key>` |
| Kavita | `http://kavita:5000` | `x-api-key: <Kavita auth key>` (preferred) or JWT from login |
| Host metrics | bind mounts: host `/proc` → `/host/proc:ro`, `/sys` → `/host/sys:ro`, `/volume1` → `/host/volume1:ro` (design review: the hub mounts only `/proc/1/net/dev`; host-global procfs files and `/sys` are read from the container itself) | n/a |
| Recyclarr logs | bind mount `/volume1/mediashare/config/recyclarr/logs` → `/host/recyclarr-logs:ro` | n/a |

The secrets the gateway needs come from `/opt/yams/monitoring/secrets/homepage.env`:
`HOMEPAGE_VAR_WATCHTOWER_TOKEN`, `HOMEPAGE_VAR_ABS_KEY`, `HOMEPAGE_VAR_KAVITA_USER`/`_PASS` (currently invalid, see section 7).
Give the gateway its own env file. Never pass these values through to the app.

> **Security gotcha (verified):** `GET /containers/{id}/json` via the read-only socket-proxy returns the full
> `Config.Env`. For `homepage` that includes every `HOMEPAGE_VAR_*` API key and password in plain text.
> The gateway **must never forward the raw inspect body to the app.** Map it to a DTO that leaves out `Config.Env`,
> `Config.Cmd`/`Args`, `HostConfig` and `Mounts[].Source`, or blank them before serialising.

---

## 1. Docker Engine, read side

All paths below can be used unversioned (the daemon answers at API 1.54) or pinned, for example `/v1.54/containers/json`.
`/v1.47/...` was also verified to work. Pin to `v1.54` so that newer fields such as `Health` in the list stay present.

### 1.1 Current proxy configuration (existing `socket-proxy`, 172.28.0.40)

Env: `CONTAINERS=1 EVENTS=1 INFO=1 PING=1 VERSION=1 POST=0`, all `ALLOW_*`=0, `IMAGES=0`, `SYSTEM=0`.
The proxy is read-only rootfs and the socket is mounted `:ro`.

Verified empirically:

| Request | Result |
|---|---|
| `GET /_ping` | 200 `OK` |
| `GET /version`, `/info`, `/containers/json`, `/containers/{id}/json`, `/containers/{id}/stats`, `/events` | 200 |
| `GET /containers/{id}/logs` | **403** (HTML `<h1>403 Forbidden</h1>Request forbidden by administrative rules.`) because `ALLOW_LOGS=0` |
| `GET /containers/{id}/top` | 403 (`ALLOW_TOP=0`) |
| `GET /images/json`, `GET /system/df` | 403 (`IMAGES=0`, `SYSTEM=0`) |
| `POST /containers/x/restart` | 403 (`ALLOW_RESTARTS=0`) |
| `GET /containers/nope/json` | 404 JSON `{"message":"No such container: nope"}` (Docker's own error format) |

So proxy denials are **403 with an HTML body**, and Docker errors are JSON `{"message": "..."}`. Handle both.

### 1.2 List containers: `GET /containers/json?all=true`

Latency about 90 ms for 21 containers. Optional `filters` is URL-encoded JSON, for example
`filters={"label":["com.docker.compose.project=yams"]}` or `{"status":["exited"]}`.

Fields that matter (fixture `docker_containers_json.json`):

| Field | Type | Notes |
|---|---|---|
| `Id` | string (64 hex) | |
| `Names` | string[] | Leading slash: `["/sonarr"]`. Strip `/`. |
| `Image` | string | Reference as configured, e.g. `lscr.io/linuxserver/qbittorrent:5.3.0`, `nickfedor/watchtower` (no tag means `latest`). |
| `ImageID` | string | `sha256:...` |
| `Created` | int | Unix **seconds** |
| `State` | string | `created`/`running`/`paused`/`restarting`/`removing`/`exited`/`dead` |
| `Status` | string | Human text: `"Up 25 minutes (healthy)"`, `"Exited (0) 2 hours ago"` |
| `Health` | object | `{"Status":"healthy"\|"unhealthy"\|"starting"\|"none","FailingStreak":0}`. **Present on this daemon (API 1.54) for every container**, with `"none"` when there is no healthcheck. On older pinned API versions fall back to parsing `(healthy)` from `Status`. |
| `Labels` | map | See below. |
| `HostConfig.NetworkMode` | string | `yams_network`, or `container:<gluetun id>` for `qbittorrent`. |
| `Ports[]` | `{IP,PrivatePort,PublicPort?,Type}` | IPv4 and IPv6 entries are duplicated. De-duplicate on `PublicPort`. |
| `NetworkSettings.Networks.yams_network.IPAddress` | string | |
| `Mounts[]` | `{Type,Source,Destination,Mode,RW}` | Do not expose `Source` to the app. |

Labels to use:

* `com.docker.compose.service` is the compose service name, equal to the container name here. Use it as the stable key.
* `com.docker.compose.project` = `yams`, `com.docker.compose.project.working_dir` = `/opt/yams`,
  `com.docker.compose.project.config_files` = `/opt/yams/docker-compose.yaml,/opt/yams/docker-compose.custom.yaml`.
* `com.centurylinklabs.watchtower.monitor-only` = `"false"` is present **only** on the auto-updated infra containers:
  homepage, uptime-kuma, socket-proxy, watchtower, flaresolverr, recyclarr, decluttarr.
  The label is absent on all the others, which means they inherit the global monitor-only=true.
* `com.centurylinklabs.watchtower` = `"true"` is on the watchtower container itself.
* `org.opencontainers.image.version` / `.revision` / `.source` are present on most images (e.g. homepage `v2.7.0`,
  watchtower `1.24.0`, kavita `latest`, decluttarr also has `com.decluttarr.version=v2.2.0`). This is a useful "current version" display.

Snapshot on 2026-11-08: 21 containers, all `running`. Healthchecks exist on homepage, gluetun, shelfmark,
uptime-kuma, watchtower, jellystat, jellystat-db, decluttarr, kavita and seerr. All the others are `none`.

### 1.3 Inspect: `GET /containers/{name|id}/json`

Fixture `docker_container_inspect.json` (sonarr; env values containing KEY/TOKEN/PASS/URL/USER redacted).
Use for the detail page only:

* `RestartCount` (int)
* `State.{Status,Running,Paused,Restarting,OOMKilled,Dead,Pid,ExitCode,Error,StartedAt,FinishedAt}`. Times are RFC3339
  with nanoseconds in **UTC** (`2026-11-08T06:21:17.288940434Z`). `FinishedAt` = `0001-01-01T00:00:00Z` when it never stopped.
* `State.Health.Log[]` (last 5 checks, `{Start,End,ExitCode,Output}`, local-offset times like `+02:00`). Only exists when there is a healthcheck.
* `HostConfig.RestartPolicy.Name` (`unless-stopped`)
* `Config.Image`, `Image` (sha256), `Created`

**Never forward `Config.Env`** (see section 0).

### 1.4 Stats: `GET /containers/{id}/stats?stream=false[&one-shot=true]`

* `stream=false`: Docker waits for **two** samples, so this takes **about 1.2 s per call**. `precpu_stats` is filled in.
* `stream=false&one-shot=true`: **about 90 ms**, but `precpu_stats` is all zeros and `preread` = `0001-01-01T00:00:00Z`.
  The gateway must keep the previous sample itself.
* `stream=true` (default): one JSON object per line, about every 1 s, for as long as the connection is open.

Recommendation: a background poller every 5 to 10 s calls `one-shot=true` for all running containers in parallel
(21 calls, about 100 ms total) and computes deltas against the previous poll. The app reads the cached values.

Formulas, matching `docker stats` (cgroup v2 host):

```
cpu_delta    = cpu_stats.cpu_usage.total_usage - prev.cpu_stats.cpu_usage.total_usage
system_delta = cpu_stats.system_cpu_usage     - prev.cpu_stats.system_cpu_usage
cpu_percent  = (system_delta > 0 && cpu_delta >= 0) ? cpu_delta / system_delta * online_cpus * 100 : 0
               // online_cpus = cpu_stats.online_cpus (4); range 0..400
mem_used     = memory_stats.usage - memory_stats.stats.inactive_file   // cgroup v2 ("anon"/"file" keys present)
mem_limit    = memory_stats.limit                                      // 8059052032 = host RAM (no limits set)
mem_percent  = mem_used / mem_limit * 100
net_rx/tx    = sum(networks[*].rx_bytes / tx_bytes)                    // cumulative bytes; rate = delta / seconds
pids         = pids_stats.current
```

Worked example from `docker_container_stats.json` (sonarr):
cpu_delta = 30,096,000 ns, system_delta = 3,960,000,000 ns, online_cpus = 4, giving **3.04 %**.
mem = 271,491,072 - 40,439,808 = 231,051,264 B (220.3 MiB), giving **2.87 %**.

Gotchas:

* `num_procs` is always 0 on Linux. Use `pids_stats.current`.
* **qbittorrent and gluetun share a netns.** Both report identical `networks.eth0` counters (fixture
  `docker_container_stats_qbittorrent.json`: rx 299,199,615 / tx 2,327,194,586 vs gluetun 299,201,243 / 2,327,312,674).
  Don't count them twice in totals. Show the traffic under gluetun/"VPN".
* `blkio_stats.io_service_bytes_recursive` lists every layer of the block stack (zram0-3, sda, sdb, md1, dm-0),
  so a naive sum is about 3 times too high. Count only `major=253, minor=0` (dm-0 = `/volume1`) plus `major=179` (eMMC system)
  if needed. Ops are lowercase `read`/`write` on cgroup v2.
* A stopped container returns zeros. `read` is still set.

### 1.5 Logs: `GET /containers/{id}/logs?stdout=1&stderr=1&timestamps=1&tail=200[&since=<unix>]`

**403 on the current proxy.** It needs `ALLOW_LOGS=1` on the hub's proxy (section 2).
Fixtures `docker_container_logs_{decluttarr,recyclarr}.json` hold the exact raw bodies (base64), captured
straight from the Docker socket on the host, plus the expected decoded frames.

All containers here have `Config.Tty=false`, so the body is **multiplexed**: repeated frames of
`[stream:1 byte (1=stdout, 2=stderr)][0,0,0][size: uint32 big-endian][payload: size bytes]`.
A frame is usually one line, but the parser must not assume that: split payloads on `\n` and keep partial lines across frames.
If `Tty=true` (check `/json` `Config.Tty`) the body is raw text with no headers.
With `timestamps=1` every line starts with `2026-11-08T08:27:25.804755366Z ` (RFC3339Nano UTC plus a space).
Add `follow=1` for live tailing. This is a long-lived chunked response; the proxy times out after 10 min idle (`timeout client/server 10m`).

* Decluttarr writes **everything to stderr** (stream byte 2).
* Recyclarr's container log only contains supercronic lines (stdout and stderr mixed). Sync output appears there only after a cron run (section 9).

### 1.6 Events: `GET /events?filters=...`

Wire format: NDJSON, one object per line, streamed (fixture `docker_events.json` holds the lines as an array).
Shape: `{"Type":"container","Action":"start|die|stop|restart|health_status: healthy|exec_start: ...","Actor":{"ID":"...","Attributes":{"name":"sonarr","image":"...","com.docker.compose.service":"...","exitCode":"0"(die only)}},"scope":"local","time":<unix s>,"timeNano":<ns>}`.

Gotchas:

* **History is useless.** The daemon keeps only the last 256 events in memory, and healthcheck `exec_create/exec_start/exec_die`
  events (10 containers checking every 10 to 30 s) fill that buffer in **about 80 seconds**. `since=<1h ago>` therefore returns nothing useful.
  To get a container-event timeline, the gateway must **keep `/events` open permanently** and store events itself.
* Filter server-side to avoid the exec noise:
  `filters={"type":["container"],"event":["start","stop","die","kill","restart","oom","health_status","create","destroy"]}`.
  Note `health_status` events have `Action` = `"health_status: healthy"` (status after the colon).
* HAProxy will close an idle stream after 10 minutes. Reconnect with `since=<last time>` to avoid a gap.

### 1.7 Engine info: `GET /info`, `GET /version`

`/info` gives `NCPU`(4), `MemTotal`(8059052032), `Containers`, `ContainersRunning/Paused/Stopped`, `Images`(114),
`ServerVersion`, `OperatingSystem`("Debian GNU/Linux 12 (bookworm)"), `KernelVersion`, `Name`("Zenith"),
`DockerRootDir`("/volume1/@docker"). Both are about 10 ms.

---

## 2. Docker control (restart / start / stop): the hub's own socket-proxy

### 2.1 Exactly what each flag opens (from `/templates/haproxy.cfg` in lscr socket-proxy 3.4.7-r0-ls105)

Rules are evaluated **in order**, and the first matching `allow`/`deny` wins:

1. **Deny** (only when the flag is 0): `/(containers|pods)/{id}/archive` (ALLOW_ARCHIVE), `/change` (ALLOW_CHANGES),
   `/export` (ALLOW_EXPORT), `/logs` (ALLOW_LOGS), `/top` (ALLOW_TOP), `/pause` (ALLOW_PAUSE), `/containers/{id}/exec` (EXEC).
2. **Allow regardless of `POST`**, for any HTTP method:
   * `ALLOW_RESTARTS=1` opens `/containers/{id}/stop`, **`/restart` and `/kill`**. One flag covers all three.
   * `ALLOW_START=1` opens `/containers/{id}/start`.
   * `ALLOW_STOP=1` opens `/containers/{id}/stop` only. This is redundant if ALLOW_RESTARTS=1.
   * `ALLOW_PAUSE` / `ALLOW_UNPAUSE` open `/pause` and `/unpause`.
   * (plus `LIBPOD_*` equivalents)
3. `http-request deny unless METH_GET || POST=1`: every other non-GET request (POST/PUT/DELETE) is refused unless `POST=1`.
4. Section allows by path prefix: `CONTAINERS` opens `/containers*`, `IMAGES` opens `/images*`, `EVENTS`, `INFO`, `PING`, `VERSION`, `SYSTEM`, `NETWORKS`, `VOLUMES`, `EXEC`, `BUILD`, and so on.
5. Anything else is denied.

Consequences:

* `POST=1` + `CONTAINERS=1` opens **every** write on `/containers*`: `POST /containers/create`, `DELETE /containers/{id}`,
  `POST /containers/{id}/update`, `/rename`, `/attach`, `/wait`, `/resize`, `POST /containers/prune`. It does **not** open
  logs/top/pause/exec/archive/export, which keep their own flags. Container create with a host bind mount means
  **root on the NAS**, so `POST=1` must not be given to the gateway's proxy.
* `POST /images/create` (pull) needs `POST=1` **and** `IMAGES=1`, and that combination also opens `DELETE /images/{id}`,
  `/images/prune`, `/images/load`, `/images/{name}/tag`, `/push`. It cannot be scoped to "pull only".
  So "pull and recreate through the proxy" needs `POST=1 CONTAINERS=1 IMAGES=1`, which is effectively full Docker access. Don't (see section 3).
* Restart/stop/start work with **`POST=0`**. That is the minimal, safe set.

### 2.2 Recommended second proxy (minimal flags)

```yaml
  socket-proxy-hub:
    image: lscr.io/linuxserver/socket-proxy:latest
    container_name: socket-proxy-hub
    environment:
      - CONTAINERS=1        # GET /containers/json, /{id}/json, /{id}/stats
      - EVENTS=1            # GET /events (container timeline)
      - INFO=1              # GET /info
      - PING=1
      - VERSION=1
      - ALLOW_LOGS=1        # GET /containers/{id}/logs (decluttarr/recyclarr summaries, log viewer)
      - ALLOW_RESTARTS=1    # POST /containers/{id}/restart, /stop, /kill
      - ALLOW_START=1       # POST /containers/{id}/start
      - POST=0              # keep 0: anything else non-GET stays forbidden (no create/delete/update/pull)
      - TZ=${TZ}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    read_only: true
    tmpfs: [/run]
    labels: *auto-update
    restart: unless-stopped
    networks: [yams_network]
```

`ALLOW_STOP=1` is not needed because `ALLOW_RESTARTS=1` already opens `/stop`. Note also that `ALLOW_RESTARTS` unavoidably opens `/kill`;
the gateway simply never calls it. The gateway can use this proxy for both reads and writes, which means the existing
`socket-proxy` can stay exactly as it is for homepage and uptime-kuma.

### 2.3 Control endpoints (Docker Engine API v1.54; not called)

| Action | Request | Body | Responses |
|---|---|---|---|
| Restart | `POST /v1.54/containers/{id}/restart?t=30` | none | 204 done (**blocks** until the container is back up; up to `t` s for stop plus the start time), 404 `{"message":"No such container: x"}`, 500 `{"message":...}` |
| Stop | `POST /v1.54/containers/{id}/stop?t=30` | none | 204 stopped, **304 already stopped** (empty body), 404, 500 |
| Start | `POST /v1.54/containers/{id}/start` | none | 204 started, **304 already started**, 404, 500 |
| (Kill) | `POST /containers/{id}/kill?signal=SIGKILL` | none | not used by the app |

Optional `signal=` on stop/restart. `t` = seconds before SIGKILL (the lscr images handle SIGTERM within about 10 s; watchtower uses 30 s).
Use an HTTP timeout of at least `t + 60 s` on the gateway side, and return 202 to the app with a job id instead of holding the phone's request open.

Guardrails the gateway must enforce:

* Deny-list for stop/restart: `yams-hub` (itself), `socket-proxy-hub` (its control path). Optionally require a "confirm"
  flag for `gluetun`, `jellyfin` and `portainer`. Stopping `socket-proxy` breaks homepage/uptime-kuma Docker monitors.
* **`gluetun` restarts must be followed by restarting `qbittorrent`.** qbittorrent uses `network_mode: service:gluetun`
  (`HostConfig.NetworkMode = container:1b55eec7...`). If gluetun restarts, qbittorrent keeps a dead netns and loses connectivity.
  If gluetun is **recreated** (new id), qbittorrent has to be recreated, not just restarted (section 3).
* `jellystat` depends on `jellystat-db`, and recyclarr/decluttarr depend on sonarr/radarr. A restart of those is harmless; just show "dependent" hints.
* Address containers by **name** (`/containers/sonarr/restart`). The proxy regex allows `[a-zA-Z0-9_.-]+`.

---

## 3. Container updates

### 3.1 Current Watchtower state (verified)

Env (values redacted): `WATCHTOWER_MONITOR_ONLY=true`, `WATCHTOWER_LABEL_TAKE_PRECEDENCE=true`, `WATCHTOWER_CLEANUP=true`,
`WATCHTOWER_HTTP_API_METRICS=true` (deprecated flag, enables `metrics` = `/v1/metrics` + `/v1/status`), `WATCHTOWER_HTTP_API_TOKEN`,
`WATCHTOWER_NOTIFICATION_URL` (discord), `WATCHTOWER_NOTIFICATIONS_HOSTNAME=Zenith`. No schedule, so the default `--interval 86400` applies.
Startup log: `Next scheduled run: 2026-11-09 09:54:04 SAST`. The container was recreated at 09:54, so **no scan has run yet**.

| Endpoint (from the gateway, Bearer token) | Result |
|---|---|
| `GET /v1/metrics` | 200 Prometheus text (fixture `watchtower_v1_metrics.txt`) |
| `GET /v1/status` | **204 No Content** (no scan since start). Becomes 200 `{"summary":{...},"timestamp","api_version"}` after a scan. |
| `GET /v1/{health,history,images,config,containers,swagger}` | 404 (not enabled) |
| no/invalid token | 401 `text/plain` "Missing or malformed API key" |
| Headers | `X-Ratelimit-Limit: 60`, `X-Ratelimit-Remaining`, `X-Ratelimit-Reset: 60` (60 req/min **per client IP**, counted before auth) |

Watchtower metric lines (all gauges/counters, describing the **last scan** only):
`watchtower_containers_scanned|updated|failed|skipped|restarted`, `watchtower_scans_total`, `watchtower_scans_failed_total`,
`watchtower_scans_skipped_total`, `watchtower_containers_restarted_total`, `watchtower_docker_images_bytes`, `watchtower_docker_images_reclaimable_bytes`, ...
Currently all 0. In monitor-only mode, a stale container is reported but **not** updated. **Metrics never say *which* containers are stale.**

### 3.2 (a) Learning which containers have updates: enable `check` (and `containers`)

Watchtower 1.24 has a proper API (docs `docs/http-api/endpoints/*` at tag v1.24.0, verified against source):

* `POST /v1/check[?container=<name>[,<name>]][&image=<ref>][&timeout=2m]`: queries the registry for each watched container's latest
  digest (HEAD, falling back to GET). It **does not pull, does not update**, and ignores monitor-only and cooldown. Default timeout 5 m
  (`WATCHTOWER_HTTP_API_CHECK_TIMEOUT`). Response 200:
  ```json
  {"containers":[{"name":"sonarr","image":"lscr.io/linuxserver/sonarr:latest","image_id":"sha256:...","digest":"sha256:old...",
    "update_available":true,"latest_image_id":"","latest_digest":"sha256:new...","update_source":"registry",
    "oci_source":"https://github.com/...","current_image_version":"4.0.x","current_revision":"...","error":"(only on failure)",
    "timestamp":"2025-01-20T11:30:45Z"}],
   "count":1,"timestamp":"...","api_version":"v1"}
  ```
  `latest_image_version` is always empty because nothing is pulled. Errors: 401, 500 `{"error":...,"api_version","timestamp"}`.
* `GET /v1/containers/details[?name=x]` returns `{containers:[{name,image,image_id,digest,running,watchtower,monitor_only,no_pull,enabled,stale,scope}],count,timestamp,api_version}`.
  `monitor_only` reflects label precedence. `stale` is only meaningful after a scan.
* `GET /v1/history?since=RFC3339&until=&limit=` returns `{entries:[{timestamp,scanned,updated,failed,restarted,skipped,scan_failed?}],count,...}` (in-memory, max 500, lost on restart).

Watchtower change needed (`/opt/yams/monitoring/secrets/watchtower.env` or the custom compose file):

```
WATCHTOWER_HTTP_API_ENDPOINTS=metrics,check,containers,history
# and remove WATCHTOWER_HTTP_API_METRICS=true (deprecated; do not combine)
```

Without `update` in the list, the daily scheduled scan and Discord notifications keep working unchanged.
(`WATCHTOWER_HTTP_API_PERIODIC_POLLS` only matters when `update` is enabled. Enabling `update` **disables the schedule** unless that is set to true.)

Gateway usage: call `POST /v1/check` (about 1 registry HEAD per container; a few seconds to about 30 s for 21 containers) **at most every
6 h plus on user pull-to-refresh**. Cache the result. Pass `?timeout=2m` and keep the gateway's HTTP timeout above that.
Note that `nickfedor/watchtower` (no tag) and the `:latest` images are tracked by digest. Pinned tags (`qbittorrent:5.3.0`, `gluetun:v3.40.0`)
will only show an update if that same tag is re-pushed, so the app should say "pinned" for them.

### 3.3 (b) Updating ONE container: Watchtower's API cannot do it here

`POST /v1/update?container=<name>` exists. It is targeted: the pattern is anchored as `^<pattern>$` (Go regex), and
`?image=` can be repeated or comma-separated. `async=true` returns 202, and targeted calls queue behind a running update instead of returning 429. **But** the handler
runs with the same base `UpdateParams` as scheduled runs (`internal/api/routes/update.go` → `BuildUpdateParams(opts)` →
`IsMonitorOnly(params)` = global `MONITOR_ONLY=true` unless the label overrides). Result:

* Containers **without** `monitor-only=false` (sonarr, radarr, jellyfin, seerr, prowlarr, bazarr, qbittorrent, gluetun, kavita,
  audiobookshelf, jellystat, shelfmark, portainer, ...) are scanned and reported **but never updated** via the API.
* The infra containers (`monitor-only=false`) would be updated, but they are auto-updated daily anyway.
* Enabling `update` also stops the daily schedule unless `WATCHTOWER_HTTP_API_PERIODIC_POLLS=true`.
* A second watchtower instance cannot fix this. Watchtower **removes other unscoped instances at startup**, and a scoped instance only manages
  containers labelled with its scope (`docs/advanced-features/running-multiple-instances`).

**Recommended: a tiny compose-aware updater sidecar** (`yams-hub-updater`). It reproduces exactly what the README documents
(`docker compose ... up -d --no-deps <service>`), so compose labels, networks and `network_mode: service:gluetun` stay correct,
something a hand-rolled Docker-API recreate would get wrong.

* Image: `docker:29-cli` (it ships the compose plugin) plus a ~40-line HTTP listener (`socat`/busybox `httpd` CGI or a small Dart/Go binary).
* Mounts: `/var/run/docker.sock` (rw, this container is privileged by nature), `/opt/yams:/opt/yams:ro` (compose files + `.env`, same path,
  so relative paths and `${MEDIA_DIRECTORY}` resolve).
* Network: `yams_network` only, **no published port**. Auth: shared bearer token with the gateway.
* API (gateway-facing; defined by us):
  * `POST /update/{service}` with `{"service":"sonarr"}` is accepted only if `service` is in the allow-list produced by
    `docker compose -f docker-compose.yaml -f docker-compose.custom.yaml config --services` and is not in the deny-list `[yams-hub-updater]`.
    It runs:
    ```sh
    cd /opt/yams
    docker compose -f docker-compose.yaml -f docker-compose.custom.yaml pull "$svc"
    docker compose -f docker-compose.yaml -f docker-compose.custom.yaml up -d --no-deps "$svc"
    # gluetun: also recreate the netns dependant
    [ "$svc" = gluetun ] && docker compose ... up -d --no-deps --force-recreate qbittorrent
    docker image prune -f   # optional, mirrors WATCHTOWER_CLEANUP (a label=com.docker.compose.project filter matches
                            # nothing: compose labels containers, not images; design review)
    ```
    It returns 202 `{"jobId":"..."}`. `GET /jobs/{id}` returns `{state: queued|running|succeeded|failed, log:[...], startedAt, finishedAt}`.
    Run one job at a time (mutex).
  * Updating `yams-hub` itself: `up -d --no-deps yams-hub` from inside the updater works because the updater is a different container.
    Updating the updater itself should be refused; leave it to watchtower (`monitor-only=false`).
* After a successful update, the gateway re-calls `POST /v1/check?container=<svc>` to clear the "update available" badge.

Alternative, if a sidecar is unwanted: only expose "Update now" for the 7 `monitor-only=false` containers via watchtower
`POST /v1/update?container=<name>&async=true` (needs `update` in `HTTP_API_ENDPOINTS` **and** `WATCHTOWER_HTTP_API_PERIODIC_POLLS=true`),
and show "update available, run `yams update-containers`" for the rest. Note `yams update-containers` updates **all** containers and is interactive.

---

## 4. Host metrics (from inside the gateway container)

Fixture: `host_proc_sys_snapshot.json` (raw text of each file, read inside the `homepage` container except where noted).
Homepage's `resources` widget does exactly this via the `systeminformation` npm library: `cpu`/`memory`/`uptime` from `/proc`,
`cputemp` from hwmon `coretemp`, and `disk: /mnt/media` = statvfs of a bind mount of `/volume1/mediashare`.

| Metric | Source inside a normal container | Notes |
|---|---|---|
| CPU % | `/proc/stat` first line `cpu user nice system idle iowait irq softirq steal guest guest_nice` (jiffies) | **Host-wide** (procfs isn't namespaced). busy = (user+nice+system+irq+softirq+steal); total = busy+idle+iowait; % = Δbusy/Δtotal. Sample every 2 to 5 s. Per-core lines `cpu0..cpu3`. |
| Memory | `/proc/meminfo` `MemTotal`, `MemAvailable`, `SwapTotal`, `SwapFree` (kB) | Host-wide. used = MemTotal - MemAvailable (7,870,168 kB total, about 2.9 GB available at capture). Note zram swap (4×960 MB) is in use. |
| Load | `/proc/loadavg` → `0.57 0.89 1.04 1/1760 8313` | Host-wide. 4 cores. |
| Uptime | `/proc/uptime` → `10289.12 28908.22` (seconds, idle-seconds) | Host uptime. |
| CPU model | `/proc/cpuinfo` `model name : Intel(R) N100` | |
| CPU temp | `/sys/class/hwmon/hwmon*/name == "coretemp"`, then `temp1_input` (Package id 0, m°C), `temp2..5_input` = Core 0-3, `tempN_max`/`_crit` = 105000 | **Select by `name`, not by index.** `/sys/class/thermal/thermal_zone1` (`x86_pkg_temp`) gives the same package temp; `thermal_zone0` `acpitz` (about 28 °C) is a useless board sensor. /sys is readable inside containers. |
| Disk usage /volume1 | `statvfs()` on any path inside a bind mount of `/volume1/...` | Total 7.19 TiB (7,719,270,092 KiB), 49 % used. Device `/dev/mapper/ug_..._pool1-volume1`. Mount `/volume1` read-only at `/host/volume1` and call statvfs (Dart: `Process.run('df','-Pk',...)` or FFI `statvfs`). |
| RAID | `/proc/mdstat` → `md1 : active raid0 sda2[0] sdb2[1]` | **RAID0 over 2× Seagate ST4000DM004 (no redundancy).** Show this, and alert if the md state is not `active`. |
| Disk I/O | `/proc/diskstats` (host-wide) | `dm-0` = volume1, `sda`/`sdb` = HDDs, `mmcblk0` = eMMC system. sectors × 512 = bytes. |
| Disk temps / SMART | not available | No `drivetemp` hwmon, and SMART needs raw device access (root). Out of scope. |
| Network throughput | **NOT visible by default** | `/proc/net/dev` inside a container shows only the container's own `eth0`. The host's real NIC is `eth0` (192.168.10.183), plus `tailscale0`, `br-c2d51ddeb5f4` (yams_network), `docker0` and the veths. |

Network throughput fix (recommended): bind-mount the host procfs read-only, `- /proc:/host/proc:ro`, and read
**`/host/proc/1/net/dev`**. PID 1 of the host procfs is in the host netns. This was verified on the host:
`/proc/1/net/dev` is world-readable and lists `eth0`/`tailscale0`. Inside a container with that mount, `/host/proc/1/...` refers to host PID 1.
That is the same approach node-exporter uses. Rates come from deltas of `eth0` rx/tx bytes (cols 1 and 9).
`tailscale0` bytes indicate remote use. Avoid `network_mode: host` for the gateway.
Not tested inside a container yet (it would have required creating one), so verify on first deploy.

Suggested compose for the gateway (read-only mounts):
```yaml
    volumes:
      - /proc:/host/proc:ro
      # NOT /sys/class/hwmon: its entries are relative symlinks that dangle when mounted alone (verified in the
      # design review). The container's own /sys already shows the host hwmon; ARCHITECTURE uses HOST_SYS=/sys.
      - /volume1:/host/volume1:ro                         # statvfs only (or narrower: /volume1/mediashare)
      - /volume1/mediashare/config/recyclarr/logs:/host/recyclarr-logs:ro
```

---

## 5. Uptime Kuma 2.5.9: public status page `zenith` (no auth)

Base `http://uptime-kuma:3001`. Both calls take about 110 ms. The page `autoRefreshInterval` is 60 s and monitors beat every 60 s,
so poll at most every 30 to 60 s.

### 5.1 `GET /api/status-page/zenith` (fixture `uptimekuma_status_page.json`)

```json
{"config":{"slug":"zenith","title":"Zenith","description":"Media server status","icon":"/icon.svg","autoRefreshInterval":60,
           "theme":"dark","published":true,"showTags":false,...,"showCertificateExpiry":false,"showOnlyLastHeartbeat":false},
 "incident":null,
 "publicGroupList":[{"id":5,"name":"Media","weight":1,
     "monitorList":[{"id":2,"name":"jellyfin","sendUrl":0,"type":"docker"}, ...]}, ...],
 "maintenanceList":[]}
```
Groups (by `weight`): Media (jellyfin 2, seerr 3, shelfmark 4, **jellyfin web 5 (type `http`)**, audiobookshelf 24, kavita 25,
jellystat 26, jellystat-db 27), Automation (sonarr 7, radarr 8, bazarr 10, prowlarr 11, flaresolverr 12, recyclarr 28, decluttarr 29),
Downloads (gluetun (VPN) 14, qbittorrent 15), System (homepage 18, portainer 19, watchtower 20, socket-proxy 21).
Monitor objects contain only `id,name,sendUrl,type` (plus `url` when `sendUrl=1`, and `tags` when `showTags`).
Monitor `name` equals the docker container name except for "jellyfin web" and "gluetun (VPN)". Map by id, not by name.
`incident`: null or `{id,style,title,content,pin,createdDate,lastUpdatedDate}`.
Unknown slug: **404** `{"status":"fail","msg":"Status Page Not Found"}`.

### 5.2 `GET /api/status-page/heartbeat/zenith` (fixture `uptimekuma_status_page_heartbeat.json`)

```json
{"heartbeatList":{"14":[{"status":2,"time":"2026-11-08 07:55:14.629","msg":"","ping":null}, ...,
                        {"status":1,"time":"2026-11-08 08:58:14.666","msg":"","ping":null}]},
 "uptimeList":{"14_24":0.8956521739130435, "5_24":1, ...}}
```
* Keys are monitor ids **as strings**. The list is ordered **oldest to newest** (the last element is the current state), with up to **100** entries
  (newer monitors have fewer; 31 seen).
* `status`: 0 = DOWN, 1 = UP, 2 = PENDING, 3 = MAINTENANCE.
* `time`: `"YYYY-MM-DD HH:MM:SS.mmm"` in **UTC with no zone marker**. Parse as UTC.
* `msg` is always `""` on the public API (error text hidden). `ping` (ms) is null for docker monitors and an int for the http monitor.
* `uptimeList["<id>_24"]` = 24 h uptime ratio 0..1.
* Unknown slug returns 200 `{"heartbeatList":{},"uptimeList":{}}` (not 404).
* Observed: gluetun had DOWN/PENDING beats 07:55 to 08:00 UTC (the VPN switch), giving a 24 h uptime of 0.8957.

Extras (no auth): `GET /api/badge/{id}/status` and `/api/badge/{id}/uptime/24` return SVG (200). Not needed.
Adding or pausing monitors needs Kuma's Socket.IO API with a login. Out of scope (leave that in Kuma's UI).

---

## 6. Audiobookshelf 2.37.2

Base `http://audiobookshelf:80` (host `:13378`). Auth `Authorization: Bearer <HOMEPAGE_VAR_ABS_KEY>`. This is an ABS API key that maps
to user **Zenith, type `root`**. Missing or bad auth gives **401** (text body). JSON keys are camelCase. Times are **epoch ms**, durations are **seconds**, sizes are **bytes**.
`/audiobookshelf/...` is an alias prefix for every route (both work).

| Feature | Request | Latency | Fixture |
|---|---|---|---|
| Server version/health (no auth) | `GET /status` returns `{"app":"audiobookshelf","serverVersion":"2.37.2","isInit":true,...}`, `GET /ping` returns `{"success":true}` | <5 ms | `audiobookshelf_status.json` |
| Libraries | `GET /api/libraries` returns `{"libraries":[{id,name,folders[{id,fullPath,libraryId}],displayOrder,icon,mediaType:"book"\|"podcast",provider,settings{...},lastScan,createdAt,lastUpdate}]}` | ~5 ms | `audiobookshelf_libraries.json` |
| Library stats | `GET /api/libraries/{id}/stats` returns `{totalItems:247,totalAuthors:83,totalGenres:4,totalSize:116852142646,totalDuration:7392920.5,numAudioTracks:284,largestItems[{id,title,size}],longestItems[{id,title,duration}],authorsWithCount[{id,name,count}],genresWithCount[{genre,count}]}` | ~2 ms | `audiobookshelf_library_stats.json` |
| Continue listening | `GET /api/me/items-in-progress?limit=10` returns `{"libraryItems":[<libraryItem minified> + progressLastUpdate]}` | ~5 ms | `audiobookshelf_me_items_in_progress.json` |
| Progress values | `GET /api/me` → `mediaProgress[]` `{libraryItemId,episodeId,duration,progress(0..1),currentTime(s),isFinished,hideFromContinueListening,lastUpdate,startedAt,finishedAt}` | ~5 ms | `audiobookshelf_me.json` |
| Home shelves | `GET /api/libraries/{id}/personalized?limit=10` returns an array of shelves `{id,label,labelStringKey,type:"book"\|"series"\|"authors",entities[],total,category}`. Ids: `continue-listening`, `recently-added`, `recent-series`, `discover` (random), `newest-authors`, and also `continue-series`/`listen-again` when they apply | **~200 ms** (heaviest) | `audiobookshelf_library_personalized.json` |
| Recently added (paged) | `GET /api/libraries/{id}/items?sort=addedAt&desc=1&limit=20&page=0&minified=1` returns `{results[],total,limit,page,sortBy,sortDesc,minified,collapseseries,offset,include}` | ~10 ms | `audiobookshelf_library_items_recent.json` |
| Item detail + progress | `GET /api/items/{id}?expanded=1&include=progress` (adds `userMediaProgress`, `media.chapters`, `audioFiles`, `tracks`) | | (not stored) |
| Listening stats | `GET /api/me/listening-stats` returns `{totalTime(s),items{<itemId>:{id,timeListening,mediaMetadata}},days{"2026-11-08":secs},dayOfWeek{"Sunday":secs},today(s),recentSessions[]}` | | `audiobookshelf_me_listening_stats.json` |
| Sessions | `GET /api/me/listening-sessions?itemsPerPage=10&page=0` returns `{total,numPages,page,itemsPerPage,sessions[{id,libraryItemId,displayTitle,displayAuthor,duration,timeListening,currentTime,startedAt,updatedAt,mediaPlayer,deviceInfo{clientName,osName,model,...}}]}` | | `audiobookshelf_me_listening_sessions.json` |
| Cover | `GET /api/items/{id}/cover[?width=400&format=webp]` returns `image/webp` | | |

Item fields to map (minified `libraryItem`): `id`, `libraryId`, `addedAt`, `updatedAt`, `isMissing`, `isInvalid`,
`media.metadata.{title,subtitle,authorName,narratorName,seriesName,genres[],publishedYear,publisher,description,asin,isbn,language,explicit}`,
`media.{duration,size,numTracks,numChapters,numAudioFiles,coverPath}`, `numFiles`, `size`.

Gotchas:

* **Covers don't need auth** (verified: 200 `image/webp` with no Authorization header). The gateway can still proxy them, which gives one
  origin and works over Tailscale. Cache-Control is fine. Item ids are UUIDs.
* `items-in-progress` does **not** contain the progress number. Join it with `/api/me` `mediaProgress[]` on `libraryItemId`.
* `/api/me` contains **`token`** (the user's legacy JWT) and `email`. Strip both. Fixture redacted.
* Library data quality: author and narrator are **swapped** for many items, because the folder naming `(<Author>)/<Title> {<Narrator>}` is parsed as
  `(Narrator)/Title {Author}`. Examples: "Lonely Castle in the Mirror" has authorName "Sarah Skaer" (the narrator) and narratorName "Mizuki Tsujimura" (the author).
  The genres list has a typo, "Audiobbook" (7). Display data as-is, and maybe flag this to the user.
* `discover` shelf content is random on every call, so don't diff or cache it.
* The library scans every 6 h (`settings.autoScanCronExpression: "0 */6 * * *"`) plus the folder watcher.
* Rescan (write; not called; from ABS API docs, not checked against 2.37 source): `POST /api/libraries/{id}/scan` (admin, empty body,
  optional `?force=1`), returning 200. Optional for the app.
* 401 body is `text/plain` `Unauthorized`.

Deep links:

* The user's actual iOS client is **"AudioBooth iOS"** (`deviceInfo.clientName` in the sessions fixture), not the official app.
  I don't know of a documented per-item URL scheme for AudioBooth or for the official app (the official app registers `audiobookshelf://`,
  which is used for its OAuth callback `audiobookshelf://oauth`; it only opens the app, with no item routing).
* Reliable fallback: web UI URLs, `http(s)://<abs-host>/item/{libraryItemId}`, `/library/{libraryId}`, `/library/{libraryId}/series/{seriesId}`,
  `/author/{authorId}` (all verified 200 text/html; the SPA routes them). Make the ABS external base URL configurable
  (LAN `http://192.168.10.183:13378` vs Tailscale).

---

## 7. Kavita v0.9.1.4

Base `http://kavita:5000`. JSON is camelCase. Enums serialize as **integers**. Times are ISO-8601 without zone (local, `+02:00` server TZ)
plus `*Utc` variants.

### 7.1 Auth (from source at rev d77d956b; important)

* **The `HOMEPAGE_VAR_KAVITA_USER/PASS` credentials currently fail.** `POST /api/Account/login` returns 401 text
  `Your credentials are not correct`. Kavita's log shows homepage (172.28.0.41) logged in successfully at 10:27, and a browser at 10:34 from 192.168.10.90,
  but at 11:00 the same stored values were rejected. Most likely the password was changed in the UI after the env file was written.
  The Homepage Kavita widget is therefore broken too. I stopped after 2 attempts, because `CheckPasswordSignInAsync(..., lockoutOnFailure: true)`
  will lock the account after repeated failures (ASP.NET Identity lockout), and homepage keeps retrying.
* **Preferred for the gateway: Kavita "Auth Keys"** (new in 0.9.x). Any `/api/*` endpoint accepts the header **`x-api-key: <authKey>`**
  (or the query `?apiKey=`) through the `AuthKey` scheme (`Kavita.Server/Middleware/AuthKeyAuthenticationHandler.cs`). There's no JWT juggling and
  no password. The user creates a key in Kavita, **User settings → Auth Keys** (admin user, so `/api/Stats/server/stats` works).
  Keys are 8 to 32 chars `[A-Za-z0-9]`. Legacy GUID keys are also accepted (`AuthKeyHelper.IsValidAuthKey`). Successful key auth results
  are cached server-side for 15 min.
* JWT route (fallback): `POST /api/Account/login` with body `{"username":"zenith","password":"...","apiKey":null}` (LoginDto). It can instead be called
  as `{"username":"","password":"","apiKey":"<authKey>"}`. The response is `UserDto` `{id,username,email,roles[],token(JWT),refreshToken,apiKey,preferences,ageRestriction,kavitaVersion,authKeys[],...}`.
  Then send `Authorization: Bearer <token>`. Refresh via `POST /api/Account/refresh-token` `{"token","refreshToken"}`. Strip `token/refreshToken/apiKey/email/authKeys`.
* Plugin route: `POST /api/Plugin/authenticate?apiKey=<key>&pluginName=YAMSHub` returns UserDto with JWT (anonymous endpoint).
* Unauthenticated: `GET /api/health` returns `Ok` (text/plain, 200). Everything else returns 401 with an empty body. No swagger in production (`/swagger/v1/swagger.json` is 404).

### 7.2 Endpoints (routes and DTOs from source; not executed because of the auth issue)

| Feature | Request | Response |
|---|---|---|
| Version | `GET /api/Server/server-info-slim` | `{installId,isDocker,kavitaVersion,firstInstallDate,firstInstallVersion}` |
| Libraries | `GET /api/Library/libraries` | `LibraryDto[]` `{id,name,type,lastScanned,coverImage,folders[],folderWatching,includeInDashboard,...}`. `type`: 0 Manga, 1 Comic, **2 Book**, 3 Image, 4 LightNovel, 5 ComicVine |
| Server stats (admin) | `GET /api/Stats/server/stats` (response-cached 10 min) | `{chapterCount,volumeCount,seriesCount,totalFiles,totalSize(bytes),totalGenres,totalTags,totalPeople,totalReadingTime}` |
| Recently added series | `POST /api/Series/recently-added-v2?PageNumber=1&PageSize=10` body **required** `{"id":0,"name":null,"statements":[],"combination":1,"sortOptions":null,"limitTo":0}` (read-only despite POST) | `SeriesDto[]` `{id,name,localizedName,sortName,pages,format,created,lastChapterAdded,libraryId,libraryName,pagesRead,wordCount,avgHoursToRead,coverImage,primaryColor,...}`. `format`: 0 Image, 1 Archive, 2 Unknown, **3 Epub**, 4 Pdf. Pagination in response header `Pagination: {"currentPage","itemsPerPage","totalItems","totalPages"}` |
| Recently updated (chapters) | `POST /api/Series/recently-updated-series?PageNumber=1&PageSize=10` (no body) | `GroupedSeriesDto[]` `{seriesName,seriesId,libraryId,libraryType,created,chapterId,volumeId,id,format,count}` |
| On deck (continue reading) | `POST /api/Series/on-deck?PageNumber=1&PageSize=10&libraryId=0` | `SeriesDto[]` + Pagination header |
| Currently reading (per user) | `GET /api/Series/currently-reading?userId=<id>&PageNumber=1&PageSize=10` | `SeriesDto[]` + Pagination header |
| Series cover | `GET /api/Image/series-cover?seriesId={id}&apiKey=<authKey>` | image (the gateway should proxy it and never put the key in app-visible URLs) |
| Library scan (write, not called) | `POST /api/Library/scan?libraryId={id}&force=false` | 200 |

`PageSize` 0 or omitted means **int.MaxValue** (`UserParams`), so always send `PageSize`.

### 7.3 Current data (read from a copy of `kavita.db`, read-only)

One library, `Books` (id 1, type 2 Book, last scanned 2026-11-08 10:25). **0 series, 0 volumes, 0 chapters, 0 files.**
Nothing was picked up, which matches the README note: Kavita needs one folder per series (`books/lightnovels/<Series>/<file>.epub`).
The app should show an empty state ("No series found. Kavita needs one folder per series.").

Deep links: there is no official Kavita mobile app. Use the web UI `http(s)://<kavita-host>/library/{libraryId}/series/{seriesId}`
(Kavita base URL `/`, configurable external URL). Also offer the OPDS URL (`/api/opds/{authKey}`) for third-party readers (Panels, Chunky, KyBook, Readest).
Get it with `GET /api/Account/opds-url[?authKeyName=<name>]`. It contains the key, so show it only once, on explicit request.

---

## 8. Decluttarr v2.2.0 (no API): container logs

Config (`config/decluttarr/config.yaml`, secrets redacted): `log_level: INFO`, `test_run: false`, `timer: 10` (minutes),
`max_strikes: 3`, `protected_tag: Keep`, `private_tracker_handling: obsolete_tag`, `public_tracker_handling: remove`. Jobs enabled:
`remove_bad_files`, `remove_failed_downloads`, `remove_failed_imports` (3 message patterns), `remove_metadata_missing`,
`remove_missing_files`, `remove_stalled`. Instances: sonarr, radarr, qbittorrent (172.28.0.18:8081).
Healthcheck `pgrep -f main.py` every 30 s.

Source: `GET /containers/decluttarr/logs?stdout=1&stderr=1&timestamps=1&since=<unix now-24h>` on the hub proxy (needs `ALLOW_LOGS=1`).
**All output is on stderr.** In Docker the logger uses the short format `"%(levelname)-7s | %(message)s"` (no time), so **always request `timestamps=1`**.

Line grammar after removing the Docker timestamp (from `src/jobs/*.py`, `src/job_manager.py`; regexes for the gateway parser):

| Meaning | Regex (Dart `RegExp`) |
|---|---|
| Level and message | `^(INFO|WARNING|ERROR|DEBUG|VERBOSE|CRITICAL)\s*\| (.*)$` |
| Run start (per arr) | `^\*\*\* Running jobs on (\w+) \((.+)\) \*\*\*$` (one run = a `-----` separator followed by one line per instance, every `timer` min) |
| Instance check | `^OK \| (\S+) \((.+)\)$` (only at startup, after `*** Checking Instances ***`) |
| Strike | `^>>> Job '(.+?)' flagged download \((\d+)/(\d+) strikes( -> too many)?\): (.+)$` |
| **Removal** | `^Job '(.+?)' triggered (removal\|queue removal \(torrent kept\)): (.+)$` |
| Obsolete tag | `^Job '(.+?)' triggered obsolete-tagging: (.+)$` |
| Search triggered | `^Job '(.+?)' triggered a search for (\d+) (\w+)s$` |
| Recovered | `^>>> Job '(.+?)' no longer flagging download \(download (.+?)\): (.+)$`. Upstream bug: the job name prints as a **tuple**, e.g. `Job '('remove_stalled',)'`. Strip `('` and `',)`. |
| Client down | `^>>> (.+) is disconnected\. Skipping queue cleaning on (\w+)\.$` (WARNING; seen at 10:17 during the qBittorrent upgrade) |
| Degraded client skip | `^>>> (\w+): skipped (\d+) download\(s\) on (\w+) whose download client is degraded` |
| Errors | `^(.+): (request\|unexpected) error on (\w+) \((.+)\): (.*)$` and `^Download-client job '(.+?)' failed on ...` |
| Test mode banner | line containing `TEST MODE IS ACTIVE` (seen in the previous run; the current run is live) |
| Restart | `Termination signal received at ...` then `Application Started!` |

App feature: "Decluttarr: last run 08:57 · next about 09:07 · 24 h: N removed / M strikes", with a list of removed titles and job names.
In the captured period there were **no removals or strikes**: queues are clean, so only the run headers appear (fixture `docker_container_logs_decluttarr.json`).
Container state comes from the Docker list (healthy/unhealthy).

---

## 9. Recyclarr v8.8.1 (no API): log files

* Schedule: `CRON_SCHEDULE=0 4 * * 0` (Sundays 04:00 SAST, via supercronic). Two configs: Radarr `hd-bluray-web`, Sonarr `web-1080p`.
* **The container log has no sync output yet.** It contains only supercronic lines (`Starting cron schedule using: 0 4 * * 0`, `level=info msg="read crontab: /tmp/crontab"`).
  After a cron run, supercronic relays the job output to stdout as `time="..." level=info msg="<line>" channel=stdout job.command="..." ...`.
* Best source: **per-run log files** under `/volume1/mediashare/config/recyclarr/logs/cli/` (mount read-only):
  `recyclarr_YYYY-MM-DD_HH-MM-SS.debug.log` and `.verbose.log`. The filename timestamp is **UTC**. The newest `*.debug.log` is the last run
  (the last manual run was 07:45:43 UTC = 09:45 SAST). Lines look like `[07:45:48 INF] hd-bluray-web: Created 41 New Custom Formats`
  (time `HH:mm:ss` UTC, level `DBG|INF|WRN|ERR|FTL`). Fixture `recyclarr_cli_debug_log_infolines.txt` holds the INF/WRN lines of the latest run.
* Parse only `INF|WRN|ERR|FTL` lines (`^\[(\d\d:\d\d:\d\d) (INF|WRN|ERR|FTL)\] (?:([\w-]+): )?(.*)$`). Useful summaries:
  * `^Processing (Radarr|Sonarr) server (.+)$` marks an instance start.
  * `^Created (\d+) New Custom Formats$`, `^Updated (\d+) Existing Custom Formats$`, `^Skipped (\d+) Custom Formats that did not change$`, `^Total of (\d+) custom formats were synced$`
  * `^Total of (\d+) sizes were synced for quality definition (\w+)$` or `^All sizes for quality definition (\w+) are already up to date!$`
  * `^Created (\d+) Profiles: \[(.*)\]$`, `^A total of (\d+) profiles were synced\. (\d+) contain quality changes and (\d+) contain updated scores$`
  * `^Completed at (.+)$` marks success. This line is US-format UTC, `11/08/2026 07:46:06`.
  * WRN example: `7 custom format(s) already existed in the service and were replaced by Recyclarr: WEB Tier 01, ...`
* A run with any `ERR|FTL` line or without `Completed at` per instance counts as failed. Next run: compute from the cron expression (next Sunday 04:00 Africa/Johannesburg).
* "Sync now" would need `docker exec recyclarr recyclarr sync`, which is EXEC (= arbitrary code execution, so **don't enable EXEC**). Delegate it to the
  updater sidecar instead (`POST /exec/recyclarr-sync` running `docker exec recyclarr recyclarr sync`) if wanted.

---

## 10. Fixture index (`fixtures/system/`)

| File | Upstream call | Notes |
|---|---|---|
| `docker_containers_json.json` | `GET /containers/json?all=true` | 5 of 21: homepage (healthy, monitor-only=false), qbittorrent (`container:` netns), sonarr (no healthcheck), decluttarr, jellystat-db |
| `docker_container_inspect.json` | `GET /containers/sonarr/json` | Env values with KEY/TOKEN/PASS/URL/USER redacted |
| `docker_container_stats.json` | `GET /containers/sonarr/stats?stream=false` | Has precpu; expected 3.04 % CPU, 231,051,264 B mem |
| `docker_container_stats_oneshot.json` | `...&one-shot=true` | precpu zero |
| `docker_container_stats_qbittorrent.json` | `GET /containers/qbittorrent/stats?stream=false` | Shared netns counters |
| `docker_info.json`, `docker_version.json` | `GET /info`, `/version` | |
| `docker_events.json` | `GET /events?since&until` | NDJSON lines as an array |
| `docker_container_logs_decluttarr.json` | `GET /containers/decluttarr/logs?...timestamps=1&tail=40` | Raw multiplexed body (base64) + expected frames (all stderr) |
| `docker_container_logs_recyclarr.json` | `GET /containers/recyclarr/logs?...&tail=20` | Mixed stdout/stderr frames |
| `host_proc_sys_snapshot.json` | `/proc/{stat×2 1 s apart,meminfo,loadavg,uptime,mdstat,net/dev}`, hwmon, thermal, `df -P` | Raw text strings |
| `watchtower_v1_metrics.txt` | `GET /v1/metrics` | Prometheus text (no scan yet, all zeros) |
| `uptimekuma_status_page.json` | `GET /api/status-page/zenith` | monitorList trimmed to 5 per group |
| `uptimekuma_status_page_heartbeat.json` | `GET /api/status-page/heartbeat/zenith` | 5 monitors × 5 beats; monitor 14 includes DOWN/PENDING |
| `audiobookshelf_status.json` | `GET /status` | |
| `audiobookshelf_libraries.json` | `GET /api/libraries` | |
| `audiobookshelf_library_stats.json` | `GET /api/libraries/{id}/stats` | Lists trimmed to 5 |
| `audiobookshelf_me_items_in_progress.json` | `GET /api/me/items-in-progress?limit=10` | |
| `audiobookshelf_me.json` | `GET /api/me` | `token`/`email` redacted |
| `audiobookshelf_library_personalized.json` | `GET /api/libraries/{id}/personalized?limit=5` | |
| `audiobookshelf_library_items_recent.json` | `GET /api/libraries/{id}/items?sort=addedAt&desc=1&limit=5&page=0&minified=1` | |
| `audiobookshelf_me_listening_stats.json` | `GET /api/me/listening-stats` | |
| `audiobookshelf_me_listening_sessions.json` | `GET /api/me/listening-sessions?itemsPerPage=3&page=0` | |
| `recyclarr_cli_debug_log_infolines.txt` | file `logs/cli/recyclarr_2026-11-08_07-45-43.debug.log` (INF/WRN lines) | |
| `shelfmark_health.json` | `GET http://shelfmark:8084/api/health` | added in the design review |
| `shelfmark_stats.json` | `GET http://shelfmark:8084/api/stats` | added in the design review; all counters 0 |

There are **no Kavita fixtures**, because authenticated calls were impossible (section 7.1). Capture them once an auth key exists.
Watchtower `/v1/check`, `/v1/status` (200) and `/v1/containers/details` fixtures need the config change in section 3.2 and one scan.

All fixtures were checked against every value in `homepage.env` and the *arr API keys. No secret strings are present.
The only match was the Kavita username "zenith", which equals the public status-page slug.

---

## 11. Gateway REST surface suggested by this probe (for the app)

```
GET  /api/system/host                -> {cpu%, perCore[], mem{total,used,available,swapUsed}, load[3], uptimeS, cpuTempC, cores[]°C,
                                         volume1{total,used,free}, raid{level:"raid0",state,devices[]}, net{eth0{rxBps,txBps}, tailscale0{...}}}
GET  /api/containers                 -> [{name, service, image, imageVersion, state, status, health, startedAt, restartCount,
                                         cpu%, memBytes, mem%, netRxBps, netTxBps, autoUpdate(bool from label), updateAvailable?, pinnedTag?}]
GET  /api/containers/{name}          -> detail (no Env!), healthLog[], recent events[]
GET  /api/containers/{name}/logs?tail=200&since=   -> [{ts, stream, line}]
POST /api/containers/{name}/{restart|stop|start}   -> 202 {jobId}   (guardrails: section 2.3)
GET  /api/updates                    -> cached watchtower /v1/check result + checkedAt
POST /api/updates/check              -> triggers /v1/check (rate-limited, e.g. once per 5 min)
POST /api/updates/{service}          -> updater sidecar job (section 3.3)
GET  /api/uptime                     -> groups[{name, monitors[{id,name,type,status,lastBeatAt,uptime24h, beats[last 30]}]}], incident
GET  /api/audiobooks/summary         -> stats, continueListening[{item, progress}], recentlyAdded[], listeningToday/7d
GET  /api/books/summary              -> kavita stats, recentlyAdded[], onDeck[] (empty-state aware)
GET  /api/maintenance/decluttarr     -> {state, health, lastRunAt, intervalMin, testMode, last24h{removed[], strikes[], searches}, warnings[]}
GET  /api/maintenance/recyclarr      -> {state, schedule, lastRun{at, ok, instances[{name, type, cfCreated, cfUpdated, profiles[], completedAt}], warnings[]}, nextRunAt}
GET  /api/media/cover/{abs|kavita}/{id}?w=400      -> proxied image (no upstream keys in URLs)
```

---

## 12. Shelfmark 1.6.1 (book and audiobook downloads; added in the design review)

Image `ghcr.io/calibrain/shelfmark:latest`, labels `org.opencontainers.image.version=1.6.1`,
`org.opencontainers.image.revision=ed0777a2e0614dcb3104b123bc13ebdf41caf463`. Flask app on `shelfmark:8084` (host port
8084), on `yams_network`. Routes were read from the source inside the container (`/app/shelfmark/core/*_routes.py`) at
that revision; only the two GETs below were called.

**Auth:** `GET /api/auth/check` → `{"auth_mode":"none","auth_required":false,"authenticated":true,"is_admin":true}`.
With `auth_mode: none`, **every client on the LAN/tailnet is a Shelfmark admin**, including for `admin_required`
routes. An optional `SHELFMARK_API_KEY` / `SHELFMARK_API_KEY_READONLY` exists (`X-Api-Key` or Bearer), but the
middleware ignores keys while `auth_mode` is `none`. The hub therefore sends no credentials.

**Safe reads used by the hub:**
| Route | Auth | Body | Notes |
|---|---|---|---|
| `GET /api/health` | none (exempt) | `{"status":"ok","coordinator":"running"}`; 503 `{"status":"error","coordinator":"stopped"}` when the download coordinator is down; optional `degraded: {websocket: "..."}` | Health probe. Fixture `shelfmark_health.json`. |
| `GET /api/stats` | admin or read-only key (open with `auth_mode: none`) | `{"added":{"audiobook_7d","audiobook_30d","ebook_7d","ebook_30d","total_7d","total_30d"},"errors":{"failed_7d"},"generated_at":"<ISO with +00:00>","queue":{"active","awaiting_pickup","queued"},"requests":{"pending","delivered","failed","cancelled","rejected"}}` | Pure read: opens the SQLite DB with `mode=ro`. Designed for dashboards. Fixture `shelfmark_stats.json` (all zeros on 2026-11-08). |

**GETs with side effects (never call):**
- `GET /api/status` (`@login_required`): returns `{queued, downloading, complete, error, ...}` but also runs
  `sync_delivery_states_from_queue_status` (writes request delivery states) and emits socket events.
- `GET /api/restart` (admin, only when debug is enabled): `os._exit(0)`, restarts the app.
- `GET /api/debug` (admin, debug only): runs `/app/genDebug.sh`, stops the GUI bypasser, returns a zip.
- `GET /api/localdownload`: streams a downloaded book file (large; no state change, but not needed).
- `GET /api/releases?provider&book_id[&source]` and `GET /api/metadata/search?query&...`: live searches against
  external sources (Anna's Archive, Libgen, metadata providers); no local state change, but they hit third parties.
  (In the older cwa-book-downloader lineage the download itself was a GET; in Shelfmark 1.6.1 it is a POST.)

**Writes (shapes only; for the v1.1 request flow):**
- Book search: `GET /api/metadata/search?query=&content_type=ebook|audiobook&limit<=100&page&sort=relevance|popularity|rating|newest|oldest[&provider]`.
- Releases for a book: `GET /api/releases?provider=<p>&book_id=<id>[&source=<s>]`.
- Queue a download: `POST /api/releases/download` JSON `{source, source_id, title, format?, size?, extra?, priority?, content_type?, on_behalf_of_user_id?}`
  → `{"status":"queued","priority":0}`; 400 when `source`/`source_id` missing; policy blocks return the policy
  response.
- Requests workflow: `POST /api/requests`, `GET /api/requests`, `DELETE /api/requests/{id}`, admin
  `POST /api/admin/requests/{id}/fulfil|reject|reopen`, `GET /api/admin/requests/count`.
- Queue control: `DELETE /api/download/{id}/cancel`, `POST /api/download/{id}/retry`, `PUT /api/queue/{id}/priority`,
  `POST /api/queue/reorder`.

Downloads that go through qBittorrent probably land in the read-only `books` category (API.md §8.5 marks it
read-only in the hub).
