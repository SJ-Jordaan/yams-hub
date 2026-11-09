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
