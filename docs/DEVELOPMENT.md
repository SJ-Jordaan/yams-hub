# YAMS Hub: development

All-in-one mobile/web companion for a YAMS media server: monitoring, requests (Seerr), library management
(Sonarr/Radarr), downloads (qBittorrent + *arr queues), indexers (Prowlarr), subtitles (Bazarr), container control and
updates, watch stats, and a launcher for every service's own web UI.

The design lives in this folder: [ARCHITECTURE.md](ARCHITECTURE.md) (how it is built),
[API.md](API.md) (the gateway REST contract), [APP.md](APP.md) (screens) and
[`integrations/`](integrations/) (what each upstream service really does). Captured upstream responses used
by the tests are in [`fixtures/`](../fixtures/).

## Repository layout

| Path | Package | What it is |
|---|---|---|
| `packages/yams_models/` | `yams_models` | Pure Dart DTOs shared by gateway and app (hand-written `fromJson`/`toJson`) |
| `gateway/` | `yams_hub_gateway` | Dart (shelf) HTTP server: holds every API key, exposes `/api/v1`, serves the web build |
| `updater/` | `yams_hub_updater` | Tiny privileged sidecar that runs `docker compose pull` + `up -d --no-deps` for one service |
| `app/` | `yams_hub` | Flutter app (Android, iOS, web); talks only to the gateway |
| `build.sh` | – | Builds the web app (and `--apk` the Android APKs); downloads the pinned Flutter SDK when none is installed |
| `install.sh`, `install/` | – | Installs the hub next to a stock YAMS install (compose template, tests with a fake docker) |
| `deploy/` | – | The maintainer's own NAS deployment: compose snippet, env builder, verification and deploy scripts |
| `tool/check_all.sh` | – | Analyze + test every package, then smoke-build the Docker images |
| `tool/sandbox/` | – | Disposable stock-YAMS stack for end-to-end tests of `install.sh` and the hub (`run.sh`) |

There is no pub workspace: each package resolves on its own with `path:` dependencies, so the gateway image never needs
the Flutter SDK.

## Toolchain

Flutter 3.47.9 / Dart 3.13.7 (plus JDK 21 and the Android SDK for Android builds), installed under
`~/development`. Every shell needs:

```sh
source ~/development/env.sh
```

Dependencies are pinned by the committed `pubspec.lock` files. Use `dart pub get` / `flutter pub get`; never run
`pub upgrade` outside a deliberate dependency update.

## Checks

```sh
tool/check_all.sh            # everything
tool/check_all.sh --skip-docker
bash install/test/install_test.sh
bash deploy/test/deploy_test.sh
tool/sandbox/run.sh          # end to end against a disposable YAMS (see "Testing changes")
```

The script analyzes `packages/yams_models` first (a duplicate public model name breaks every package), then runs
analyze and tests for `yams_models`, `gateway`, `updater` and `app` (packages that do not exist yet are skipped), and
ends with `docker build` of `gateway/Dockerfile` and `updater/Dockerfile`. When no web build exists it creates a
placeholder `app/build/web/index.html` for the smoke build and removes it afterwards. Without docker the smoke build is
skipped with a warning.

Per package:

```sh
(cd packages/yams_models && dart analyze --fatal-infos && dart test)
(cd gateway && dart analyze --fatal-infos && dart test)
(cd updater && dart analyze --fatal-infos && dart test)
(cd app && flutter analyze && flutter test)
```

Tests never call live services; they use fakes and the fixtures.

## Testing changes

Unit tests (above) use fakes. To see a change work against real services, use the sandbox: a disposable stock-YAMS
server on this machine that the real `./install.sh` and hub run against (needs Docker with compose v2, Python 3 and
internet for the images and the Sonarr/Radarr lookups).

```sh
./build.sh                                   # the web build install.sh needs
tool/sandbox/run.sh                          # all: down, up, seed, install, test, screens, logs, down (~10 min)
tool/sandbox/run.sh --variant vpn-on         # qBittorrent behind gluetun (network_mode: service:gluetun)
KEEP=1 tool/sandbox/run.sh                   # leave it running: hub on http://127.0.0.1:28090 (admin)
tool/sandbox/run.sh up seed install          # or step by step; each step is idempotent
tool/sandbox/run.sh test                     # re-run the smoke test only
tool/sandbox/run.sh down                     # remove it
```

- **What it is** (`tool/sandbox/compose.yaml`): the stock YAMS layout under compose project `sbx-yams`: the linuxserver
  images at `:latest`, `yams_network` with fixed addresses (subnet `172.29.213.0/24`, `SANDBOX_SUBNET` to move it),
  jellyfin and VPN-off qBittorrent on `sbx-yams_default`, a busybox stand-in for gluetun (VPN off it restarts
  forever like an unconfigured stock gluetun; VPN on it serves the two control routes the hub reads), plus Seerr. Its
  INSTALL_DIRECTORY and MEDIA_DIRECTORY live under `${SANDBOX_DIR:-~/.cache/yams-hub-sandbox}`; the apps listen on
  `127.0.0.1:2xxxx` only. It uses the real container names (`sonarr`, `yams-hub`, ...) and the hub's control network
  `172.30.250.0/29`, so `up` refuses to run where those belong to something else.
- **seed** (`seed.py`) configures the apps through their APIs only: Jellyfin wizard, API key and libraries, the
  qBittorrent password, root folders and three real shows and movies, Prowlarr apps, Bazarr, Seerr.
- **install** runs `./install.sh --answers <file>` (the unattended mode; passwords are throwaway values generated into
  `$SANDBOX_DIR/secrets.env`), then runs it again to prove a re-run changes nothing outside the hub.
- **test** (`smoke.py`, stdlib only) logs in (bearer and cookie flows), calls every page's API and fails on upstream
  errors, missing or unhealthy services, an empty calendar or library. It also restricts Sonarr's Allowed Hosts
  (issue #2): the hub must notice (health or calendar) and recover after the restore; whether it names the cause is
  only recorded.
- **screens** (`screens.py`) needs Playwright: it uses `~/development/perf-venv` and `~/development/ms-playwright` when
  present (`SANDBOX_PYTHON` to choose another); without it the step is skipped with a warning.
- **down** removes only what carries the sandbox's compose labels (and the hub install inside `$SANDBOX_DIR`), plus
  the files `up` created in `$SANDBOX_DIR`. `up` only uses a new or empty `SANDBOX_DIR`. Pulled and built images stay
  cached.

CI (`.github/workflows/sandbox.yml`) runs the install unit tests, `./build.sh` and `run.sh all` for both variants on
pull requests, on pushes to main that touch the hub, weekly (the upstream images are `:latest`) and on demand. No
secrets are used.

Debugging a failure: the artifacts (CI: the `sandbox-<variant>` artifact; locally `$SANDBOX_DIR-artifacts`) hold the
install logs, `smoke-<variant>.json`, every container's log (`logs-<variant>/`) and the screenshots. Locally, re-run
with `KEEP=1`, then poke at the hub (`http://127.0.0.1:28090`, admin password in `$SANDBOX_DIR/secrets.env`), the
apps (`127.0.0.1:28989` Sonarr, `27878` Radarr, `29696` Prowlarr, `26767` Bazarr, `28096` Jellyfin, `28081`
qBittorrent, `25055` Seerr) and `docker logs yams-hub`; `run.sh test` re-runs only the checks.

## Run locally

Gateway (dev; secrets come from a local secrets file, never from the command line):

```sh
cd gateway
dart run bin/server.dart hash-password            # prints a pbkdf2-sha256$... hash (password read from stdin)
YAMS_HUB_DATA_DIR=/tmp/yams-hub-data \
YAMS_HUB_SECRETS_FILE=$PWD/dev-secrets.env \
YAMS_HUB_CORS_ORIGINS=http://localhost:5173 \
  dart run bin/server.dart serve
dart run bin/server.dart check-config             # what is configured, from which source (no values printed)
```

`dev-secrets.env` holds `KEY='value'` lines such as `YAMS_HUB_ADMIN_PASSWORD_HASH='...'` and the service keys (see
ARCHITECTURE §5.2 for every variable). It is git-ignored (`*.env`).

App:

```sh
cd app
flutter run -d chrome --web-port 5173             # dev web against a local or LAN gateway
flutter run                                       # attached Android device
```

## Build and deploy (maintainer's NAS)

Everyone else uses `./build.sh` and `./install.sh` (see the [README](../README.md)).

On the dev machine (`deploy/deploy.sh` does all of this; images go to the NAS over `ssh` stdin because `scp` to the
NAS is broken):

```sh
source ~/development/env.sh
(cd app && flutter build web --release --no-web-resources-cdn)
find app/build/web -name '*.symbols' -delete
docker build -f gateway/Dockerfile -t yams-hub:latest .                 # context = repo root
docker build -f updater/Dockerfile -t yams-hub-updater:latest updater
docker save yams-hub:latest yams-hub-updater:latest | gzip | ssh nas 'gunzip | docker load'
ssh nas 'cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml \
  up -d --no-deps yams-hub socket-proxy-hub yams-hub-updater'
```

`--no-deps` restarts only the hub containers; no other service sees downtime. On the NAS, `deploy/make_hub_env.sh`
builds `/opt/yams/monitoring/secrets/yams-hub.env` (and the updater's env) from the existing secrets without printing
them, and `deploy/verify.sh` checks the topology after the first deploy (ARCHITECTURE §6, §9).

The hub listens on host port **8090, IPv4 only**: `http://<server-ip>:8090` on the LAN and
`http://<server>.<tailnet>.ts.net:8090` over Tailscale (no router ports are opened; ARCHITECTURE §8). On untrusted Wi-Fi
use the Tailscale URL.

Mobile: `flutter build apk --release` for Android (sideload). On iOS the supported default is the gateway-served web
app added to the Home Screen from Safari; TestFlight or a 7-day personal-team build are the alternatives
(ARCHITECTURE §9).
