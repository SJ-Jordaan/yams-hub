# YAMS Hub

A phone and web app for a [YAMS](https://yams.media) media server: requests, downloads, the Sonarr/Radarr library,
subtitles, indexers, container restarts and updates, and server health in one place. It runs as three small
containers next to YAMS and does not change YAMS's own setup.

## What you need

- A YAMS server set up with the standard YAMS installer (Linux, Docker with compose v2).
- `git` on the server.
- To build: an x64 Linux or macOS machine. The server itself works. `./build.sh` downloads Flutter (about 1 GB, once)
  if it is not already installed; that needs `curl`, `unzip` and `xz` (Debian/Ubuntu:
  `apt install git curl unzip xz-utils`).

## Install

On the server, as root or as a user in the `docker` group:

```sh
git clone https://github.com/SJ-Jordaan/yams-hub.git
cd yams-hub
./build.sh
./install.sh
```

`install.sh` finds YAMS and reads the Sonarr, Radarr, Prowlarr, Bazarr and Seerr API keys by itself. Then it asks
for:

- the Jellyfin API key and the qBittorrent login (press Enter to skip a service),
- the port (default 8090),
- an admin password.

When it finishes, open `http://<server-ip>:8090` and sign in as `admin`.

Unattended: `./install.sh --answers FILE` takes the answers from a `KEY=value` file instead (see `./install.sh -h`).

To build somewhere else, run `./build.sh` there, then copy `app/build/web` into the server's checkout before you run
`./install.sh`.

## Phone

- **Android:** on the phone, download
  [yams-hub-arm64.apk](https://github.com/SJ-Jordaan/yams-hub/releases/latest/download/yams-hub-arm64.apk)
  (older 32-bit phones: [yams-hub-armv7.apk](https://github.com/SJ-Jordaan/yams-hub/releases/latest/download/yams-hub-armv7.apk);
  all builds: [Releases](https://github.com/SJ-Jordaan/yams-hub/releases)), open it and allow the install. On first
  start, enter `http://<server-ip>:8090`. To update, install the newer APK over it. To build it yourself:
  `./build.sh --apk` (needs the Android SDK and a JDK).
- **iPhone:** open `http://<server-ip>:8090` in Safari, then tap Share > Add to Home Screen.

Away from home, use a VPN such as Tailscale. Do not open the port on your router.

## Update

```sh
cd yams-hub
git pull
./build.sh
./install.sh --update
```

## Uninstall

```sh
./install.sh --uninstall           # removes the containers, keeps users and settings
./install.sh --uninstall --purge   # also deletes all hub data
```

## Troubleshooting

- **Logs:** `docker logs yams-hub` (also `yams-hub-updater` and `socket-proxy-hub`). The hub's files are in
  `<YAMS dir>/yams-hub/` (usually `/opt/yams/yams-hub/`), and its data is in `<media dir>/config/yams-hub/`.
- **A service shows as not configured:** its key was skipped or not found. Run `./install.sh --reconfigure`.
- **"172.30.250.0/29 overlaps ...":** another Docker network or VPN uses the hub's control network range. Move or
  remove it, then run `./install.sh` again.
- **"port 8090 is already in use":** run `./install.sh` again and choose another port.
- **Try first:** `./install.sh --dry-run` shows what it found and what it would do, without changing anything.

Developer notes (layout, toolchain, checks) are in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
