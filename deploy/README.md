# Deploying YAMS Hub to Zenith

Everything in this folder runs either on the dev machine (`deploy.sh`) or on the NAS (`make_hub_env.sh`,
`verify.sh`). The design is in [ARCHITECTURE §6, §8, §9 and §10](../docs/ARCHITECTURE.md).

| File | Runs on | What it does |
|---|---|---|
| `docker-compose.hub.yaml` | – | The three services and the `yams_hub_ctl` network, to merge into `/opt/yams/docker-compose.custom.yaml` |
| `deploy.sh` | dev machine | Builds the web app, ships the build context over ssh, builds both images **on the NAS**, restarts only the hub services, proves nothing else was recreated |
| `make_hub_env.sh` | NAS | Writes `/opt/yams/monitoring/secrets/yams-hub.env` and `yams-hub-updater.env` from the existing secrets; creates the data dir |
| `verify.sh` | NAS | The 7 post-deploy checks of ARCHITECTURE §6 (PASS/FAIL) |
| `yams-hub.example.yaml` | – | Optional policy file (ARCHITECTURE §5.2.1) |
| `tailscale-acl.example.hujson` | – | ACL snippet for the Tailscale admin console (ARCHITECTURE §8) |

What the hub adds on the NAS, and nothing else:

| Container | Image | Networks | Published |
|---|---|---|---|
| `yams-hub` | `yams-hub:latest` (built on the NAS) | `yams_network` (172.28.0.49) + `yams_hub_ctl` | `0.0.0.0:8090` (IPv4 only) |
| `socket-proxy-hub` | `lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105` (pinned) | `yams_hub_ctl` only | nothing |
| `yams-hub-updater` | `yams-hub-updater:latest` (built on the NAS) | `yams_hub_ctl` only | nothing |

Files: `/opt/yams/monitoring/secrets/yams-hub.env` (uid 64090, 0400), `/opt/yams/monitoring/secrets/yams-hub-updater.env`
(root, 0400), data dir `/volume1/mediashare/config/yams-hub` (uid 64090, 0700). The core
`/opt/yams/docker-compose.yaml` is never edited, and no running service is restarted.

Conventions used below: `ssh nas` means `ssh -o BatchMode=yes -o WarnWeakCrypto=no nas` (scp/sftp do not work on
this NAS, so files travel through `ssh nas 'cat > file' < file`). `COMPOSE` stands for
`docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml`, run in `/opt/yams`. Commands quoted
for the NAS assume its login shell is bash (the UGOS default); the local parts work in bash, zsh and fish.

---

## Before you start

1. **Commit.** `deploy.sh` ships `git archive HEAD` (plus `app/build/web`), not your working tree. It refuses to run
   while the working tree has any uncommitted or untracked change (anywhere in the repo, since the web app is built
   from `app/` as it is on disk) and says so; `--allow-dirty` deploys HEAD anyway (`--dry-run` only warns).
2. **The address 172.28.0.49 and port 8090 are free** (both were on 2026-11-08; check again):

   ```sh
   ssh nas "docker network inspect \$(docker network ls -q --filter name=yams_network) \
     -f '{{range .Containers}}{{.IPv4Address}} {{.Name}}{{\"\n\"}}{{end}}' | sort -V"
   ssh nas "grep -n '172\.28\.0\.49\|8090' /opt/yams/docker-compose.yaml /opt/yams/docker-compose.custom.yaml || echo free"
   ssh nas "ss -ltn 'sport = :8090'"     # header line only = free
   ```

   If .49 is taken, pick another free address in 172.28.0.0/24 and change it in the merged file **and** in
   `HUB_IP` at the top of `deploy.sh`.
3. **Your go-ahead** for the compose additions (ARCHITECTURE §11, "still needs the user"). Nothing below touches the
   running stack until step 4 of the first deploy.

## First deploy

### 1. Back up the custom compose file

```sh
ssh nas 'cp -p /opt/yams/docker-compose.custom.yaml /opt/yams/docker-compose.custom.yaml.bak-$(date +%Y%m%d-%H%M)'
```

(If `/opt/yams` is not writable by Zenith, do every write in this section through
`docker run --rm -v /opt/yams:/y alpine:3.22 ...` instead, as `make_hub_env.sh` does for the secrets.)

### 2. Pin the socket proxy by digest

```sh
ssh nas 'docker pull -q lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105 &&
  docker image inspect -f "{{index .RepoDigests 0}}" lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105'
```

Use the printed `lscr.io/linuxserver/socket-proxy@sha256:...` digest in the merged file as
`image: lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105@sha256:<digest>`. (Pulling an image does not touch any
container.) Every later bump of this image repeats the `haproxy.cfg` review of integrations/system.md §2.1.

### 3. Merge `docker-compose.hub.yaml` into the custom file

Edit a copy on the dev machine, validate it on the NAS, and only then swap it in:

```sh
ssh nas 'cat /opt/yams/docker-compose.custom.yaml' > /tmp/custom.yaml
$EDITOR /tmp/custom.yaml deploy/docker-compose.hub.yaml
```

The existing file already has a top-level `services:` key whose services sit on `yams_network` with fixed
`ipv4_address`es in 172.28.0.0/24. Merge like this (keep the existing file's indentation, two spaces):

- Copy the three service blocks (`yams-hub`, `socket-proxy-hub`, `yams-hub-updater`) **under the existing
  `services:` key**, after the last service. Do not add a second `services:` key.
- Add the network at the top level. If the file **already has a top-level `networks:` key**, add only the
  `yams_hub_ctl:` entry (two lines) under it; otherwise add the whole block:

  ```yaml
  networks:
    yams_hub_ctl:
      internal: true            # no outside access, no other container
  ```

  `yams_network` itself is already defined by the stack; do not redefine it.
- `yams-hub` keeps its long-form `networks:` with `ipv4_address: 172.28.0.49` on `yams_network` and an empty
  `yams_hub_ctl: {}` entry; the proxy and the updater keep `networks: [yams_hub_ctl]` and **no** address on
  `yams_network`.
- Replace the socket-proxy `image:` with the digest-pinned one from step 2.

Before editing, you can check that the snippet merges cleanly as a third file (nothing is started by `config`):

```sh
ssh nas 'cat > /tmp/docker-compose.hub.yaml' < deploy/docker-compose.hub.yaml
ssh nas 'cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml \
  -f /tmp/docker-compose.hub.yaml config -q && echo snippet OK'
```

Then validate the edited file. The second command must print **nothing**: every existing service's merged
configuration is unchanged (only additions).

```sh
ssh nas 'cat > /opt/yams/docker-compose.custom.yaml.new' < /tmp/custom.yaml
ssh nas 'cd /opt/yams &&
  docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml.new config -q &&
  docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml.new config --services | grep -E "^(yams-hub|socket-proxy-hub|yams-hub-updater)$"'
ssh nas 'cd /opt/yams && diff <(docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml config) \
  <(docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml.new config) | grep "^<"'
```

Swap it in (no container is touched by this):

```sh
ssh nas 'cd /opt/yams && mv docker-compose.custom.yaml.new docker-compose.custom.yaml'
```

### 4. Build, configure and start (one command)

```sh
deploy/deploy.sh --dry-run        # prints every command; nothing runs
deploy/deploy.sh --first-run
```

`--first-run` does, in order:

1. NAS preflight: the three services are in the merged compose config and 172.28.0.49 is free.
2. `flutter build web --release --no-web-resources-cdn` locally, `*.symbols` deleted.
3. Streams `git archive HEAD` (`packages/yams_models`, `gateway`, `updater`, `deploy`, `.dockerignore`) plus
   `app/build/web` as one tar over ssh into a `mktemp -d /tmp/yams-hub-deploy.XXXXXX` on the NAS.
4. `docker build` of `gateway/Dockerfile` (context = the repo root) and `updater/Dockerfile` (context = `updater/`)
   on the NAS, tagged `:latest` (the image the running container uses becomes `:previous`, the rollback image) with
   the git revision as the `org.opencontainers.image.revision` label. The updater image also carries
   `yams-hub.updater-tree`, the git tree id of `updater/`, so later deploys can tell whether it changed.
5. **`make_hub_env.sh`** on the NAS, over `ssh -t`: creates the data dir (uid 64090, 0700), writes both secrets files
   and **asks for the hub admin password** (at least 10 characters; it is hashed by `yams-hub hash-password` inside
   the image and only the hash is stored). It ends with `yams-hub check-config`; check that every service you expect
   says `configured`.
6. Snapshot of `docker ps -a` ids, then `COMPOSE up -d --no-deps yams-hub socket-proxy-hub yams-hub-updater`, then a
   second snapshot. **If any other container changed id, appeared or disappeared, the deploy fails loudly** and
   lists them.
7. Waits until `yams-hub` and `yams-hub-updater` report `healthy`, pings `http://127.0.0.1:8090/api/v1/ping`.

`deploy.sh` itself is tested without a NAS by `bash deploy/test/deploy_test.sh` (fake `ssh` and `docker`).
8. **`verify.sh`** on the NAS (it asks for the admin password once for the `/health` check). All 7 checks must say
   PASS; check 7 says SKIP for the Tailscale URL until Tailscale is logged in (re-run it then, see below).

Then open **http://192.168.10.183:8090**, log in as `admin`, and change nothing else yet.

### 5. Drop the bootstrap hash

After the first successful login (the hub has written `users.json`), remove the bootstrap hash from the secrets file.
The gateway ignores it from now on anyway; removing it means a leaked file cannot be replayed into a fresh data dir.

```sh
ssh nas 'cat > /tmp/make_hub_env.sh' < deploy/make_hub_env.sh
ssh -t nas 'bash /tmp/make_hub_env.sh --drop-bootstrap; rm -f /tmp/make_hub_env.sh'
```

No restart is needed. (`--drop-bootstrap` refuses to run while `users.json` does not exist.)

### 6. Uptime Kuma monitor (phase 1, ARCHITECTURE §10)

In Uptime Kuma (http://192.168.10.183:3001):

1. **Add New Monitor**
   - Monitor Type: **HTTP(s) - Keyword**
   - Friendly Name: `YAMS Hub`
   - URL: `http://yams-hub:8080/api/v1/ping` (Kuma is on `yams_network`, so the container name resolves; `/ping` is
     exempt from the hub's Host check)
   - Keyword: `"name":"yams-hub"`
   - Heartbeat Interval: `60`, Retries: `2`, Heartbeat Retry Interval: `60`
   - Accepted Status Codes: `200-299`
   - Notifications: tick the existing Discord notification (`#alerts`), like the other monitors
   - Save.
2. **Status Pages > zenith > Edit Status Page**: in the **System** group, add `YAMS Hub` from the monitor list, then
   **Save**. The hub's own System screen and dashboard then show it like every other monitor.

### 7. Optional follow-ups

- **Tailscale** (ARCHITECTURE §8): log the NAS in from UGOS > Tailscale, enable MagicDNS, merge
  `tailscale-acl.example.hujson` into the tailnet policy, tag the NAS `tag:nas`. Then re-run the verification so the
  Tailscale checks (4 and 7) run too:

  ```sh
  ssh nas 'cat > /tmp/verify.sh' < deploy/verify.sh
  ssh -t nas 'bash /tmp/verify.sh --tailscale-url http://zenith.<tailnet>.ts.net:8090; rm -f /tmp/verify.sh'
  ```

  Add the Tailscale URL to `publicUrls` in the policy file (next item) so Settings > About shows it.
- **Policy file**: copy `yams-hub.example.yaml`, adjust `publicUrls`, install it as described in its header, then
  `deploy/deploy.sh --skip-web --only yams-hub` (or just restart `yams-hub` with `COMPOSE up -d --no-deps --force-recreate yams-hub`).
- **Kavita**: create an Auth Key in Kavita (User settings > Auth Keys), then
  `ssh -t nas 'bash /tmp/make_hub_env.sh --set-kavita-key'` (copy the script first, as in step 5) and recreate
  `yams-hub` (`COMPOSE up -d --no-deps --force-recreate yams-hub`).
- **Watchtower per-container checks** (ARCHITECTURE §5.17): in `/opt/yams/monitoring/secrets/watchtower.env`,
  set `WATCHTOWER_HTTP_API_ENDPOINTS=metrics,check,containers,history` and remove `WATCHTOWER_HTTP_API_METRICS=true`;
  then `COMPOSE up -d --no-deps watchtower`. This is a change to Watchtower, so it needs its own go-ahead.

---

## Regular deploys

```sh
deploy/deploy.sh                       # web + hub image; the updater only if updater/ changed since its running image
deploy/deploy.sh --skip-web            # gateway/updater change only
deploy/deploy.sh --only yams-hub       # never builds, retags or touches the updater
deploy/deploy.sh --only yams-hub-updater  # rebuild and recreate the updater (e.g. after editing its compose entry)
deploy/deploy.sh --pull                # also refresh the dart:3.13 / distroless base images (rebuilds both)
```

Only the images of the services being deployed are built and retagged, so `:latest` and `:previous` always name
images that ran. Compose only recreates a service whose image or configuration changed, so an unchanged
`socket-proxy-hub` keeps running. Restarting `yams-hub` takes a few seconds of hub downtime and no downtime for any
other service.

Recreating the updater stops it, and it may be in the middle of a job (an admin's "Update sonarr"). Two guards keep
that from leaving a stack service stopped half way through `compose up`:

- `deploy.sh` waits (up to `UPDATER_IDLE_WAIT` seconds, default 900) while the updater runs a `docker` command, and
  stops without restarting anything if it is still busy.
- On SIGTERM the updater accepts no new job (503) and lets the running one reach a safe point: the current step
  always finishes; a job that has only pulled stops there; once a recreate has started, its required follow-ups
  (gluetun's `qbittorrent`) still run. `stop_grace_period: 17m` in the compose entry keeps Docker from killing it
  earlier. **If your merged `docker-compose.custom.yaml` predates that line, add it to `yams-hub-updater` and run
  `deploy/deploy.sh --skip-web --only yams-hub-updater`.**

The hub never updates itself or its two helpers through Watchtower (`watchtower.enable=false` /
`monitor-only=true`) or through the updater (deny-list); `deploy.sh` is the only way they change.

## Re-running `make_hub_env.sh`

Re-run it whenever a key in `homepage.env` or an *arr `config.xml` changes. It keeps `UPDATER_TOKEN`,
`JELLYFIN_ADMIN_USER_ID`, `KAVITA_API_KEY`, `YAMS_HUB_ADMIN_*` and any key it does not manage, and prints only key
names and where each came from:

```sh
ssh nas 'cat > /tmp/make_hub_env.sh' < deploy/make_hub_env.sh
ssh -t nas 'bash /tmp/make_hub_env.sh; rm -f /tmp/make_hub_env.sh'
ssh nas 'cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml up -d --no-deps --force-recreate yams-hub'
```

Options: `--set-admin-password`, `--set-kavita-key`, `--drop-bootstrap`, `--rotate-updater-token` (then recreate
both `yams-hub` and `yams-hub-updater`), `--no-check`. The gateway reads the secrets file at start-up only.

Forgotten admin password: run `--set-admin-password`, then stop the hub and run `reset-admin` in a throwaway
container with the gateway's data dir and secrets file (no network, so it cannot clash with the hub's fixed
address; `reset-admin` refuses while a gateway still answers):

```sh
ssh nas 'cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml stop yams-hub &&
  docker run --rm --network none --user 64090:64090 --read-only \
    -v /volume1/mediashare/config/yams-hub:/data \
    -v /opt/yams/monitoring/secrets/yams-hub.env:/run/secrets/yams-hub.env:ro \
    --entrypoint /app/yams-hub yams-hub:latest reset-admin &&
  docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml up -d --no-deps yams-hub'
```

After the reset, run `--drop-bootstrap` again.

---

## Rollback

### The last deploy broke the hub

`deploy.sh` keeps the image the container ran before the deploy as `:previous` (it only retags the images it
deploys, so `--only yams-hub` leaves the updater's tags alone):

```sh
ssh nas 'docker image tag yams-hub:previous yams-hub:latest &&
  cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml up -d --no-deps yams-hub'
# the same for the updater, if needed:
ssh nas 'docker image tag yams-hub-updater:previous yams-hub-updater:latest &&
  cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml up -d --no-deps yams-hub-updater'
```

The previous build reads the same data dir; data files are only ever extended, so going back one version is safe.
To go back further, check out the older commit and run `deploy/deploy.sh` from it.

### Remove the hub completely

Nothing else depends on the hub; Homepage keeps running the whole time (it is only replaced in phase 3).

```sh
# 1. stop and remove only the three hub containers (while they are still in the compose file)
ssh nas 'cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml \
  rm -s -f yams-hub yams-hub-updater socket-proxy-hub'
# 2. restore the custom file from the backup of first-deploy step 1 (use the right timestamp)
ssh nas 'cd /opt/yams && ls docker-compose.custom.yaml.bak-* &&
  cp -p docker-compose.custom.yaml.bak-YYYYMMDD-HHMM docker-compose.custom.yaml'
# 3. remove the internal network and the images
ssh nas 'docker network rm yams_yams_hub_ctl; docker image rm yams-hub:latest yams-hub:previous yams-hub-updater:latest yams-hub-updater:previous'
# 4. optional: delete the hub's secrets and data (users, sessions, audit log, image cache)
ssh nas 'docker run --rm --network none -v /opt/yams/monitoring/secrets:/s -v /volume1/mediashare/config:/c alpine:3.22 \
  rm -rf /s/yams-hub.env /s/yams-hub-updater.env /c/yams-hub'
```

Also delete the `YAMS Hub` monitor in Uptime Kuma (or it alerts in Discord), and undo the Tailscale ACL if you
applied it. Snapshot `docker ps --format '{{.ID}} {{.Names}}'` before and after step 1 if you want the same proof
`deploy.sh` gives: only the three hub containers may disappear.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `deploy.sh`: "... is not in docker-compose.custom.yaml yet" | Step 3 of the first deploy is missing or the merged file has a typo (`COMPOSE config -q`). |
| `deploy.sh`: "... is missing (or a directory)" | Secrets file not created yet: run `deploy.sh --first-run` (or `make_hub_env.sh`). If Docker created a directory at the bind source, `make_hub_env.sh` removes the empty directory and writes the file. |
| `deploy.sh`: "containers outside the hub changed id" | Something else was recreated during `up` (e.g. a dependency or a concurrent Watchtower run). Inspect with `docker ps -a`; the hub services were deployed with `--no-deps`, so this should never be caused by the hub itself. |
| `yams-hub` stays `unhealthy` | `docker logs --tail 50 yams-hub`; typical: data dir not owned by 64090 (re-run `make_hub_env.sh`, it fixes the owner), invalid policy file (`check-config` names the key). |
| Updates screen says the updater is unavailable | `docker logs yams-hub-updater`: "refusing to start" means the token file is missing or shorter than 32 bytes; re-run `make_hub_env.sh` and recreate both containers. |
| `verify.sh` check 4 fails on `/host/proc/1/net/dev` | The single-file bind does not track the host netns on this UGOS build: change that volume to `/proc:/host/proc:ro` (keep `HOST_NET_DEV=/host/proc/1/net/dev`), recreate `yams-hub`, and note it in `/opt/yams/monitoring/README.md`. |
| `verify.sh` check 6 lists a container | A container with `stdin_open: true`; the attach residual of ARCHITECTURE §5.16 applies to it. Remove `stdin_open` from its compose entry unless it needs it. |

## The updater sidecar

`yams-hub-updater` (source in [`../updater`](../updater)) is the only container with a writable Docker socket. It
answers only on `yams_hub_ctl`, requires `Authorization: Bearer <UPDATER_TOKEN>` on every path (401 otherwise, even for
unknown paths), and can only run, for one compose service from `COMPOSE config --services` that is not in
`UPDATER_DENY` (default `yams-hub,yams-hub-updater,socket-proxy-hub`; it never updates itself):
`compose pull -- <svc>`, `compose up -d --no-deps -- <svc>` (gluetun also force-recreates `qbittorrent`) and
`docker image prune -f`, plus the fixed `docker exec recyclarr recyclarr sync`. One job at a time, 15 minutes per step.
