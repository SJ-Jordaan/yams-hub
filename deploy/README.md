> This folder is the maintainer's own NAS deployment. To run YAMS Hub on your own YAMS server, use `./install.sh` (see the [README](../README.md)).

# Deploying YAMS Hub to Zenith

Everything in this folder runs either on the dev machine (`deploy.sh`) or on the NAS (`make_hub_env.sh`,
`verify.sh`). The design is in [ARCHITECTURE §6, §8, §9 and §10](../docs/ARCHITECTURE.md).

| File | Runs on | What it does |
|---|---|---|
| `docker-compose.hub.yaml` | – | The three services and the `yams_hub_ctl` network, to merge into `/opt/yams/docker-compose.custom.yaml` |
| `socket-proxy-hub/haproxy.cfg` | – | The socket proxy image's haproxy template plus a source ACL (only the gateway may connect); `deploy.sh` installs it on the NAS |
| `deploy.sh` | dev machine | Builds the web app, ships the build context over ssh, builds both images **on the NAS**, installs the proxy template, restarts only the hub services, proves nothing else was recreated |
| `make_hub_env.sh` | NAS | Writes `/opt/yams/monitoring/secrets/yams-hub.env` and `yams-hub-updater.env` from the existing secrets; creates the data dir |
| `verify.sh` | NAS | The 7 post-deploy checks of ARCHITECTURE §6 (PASS/FAIL) |
| `yams-hub.example.yaml` | – | Optional policy file (ARCHITECTURE §5.2.1) |
| `tailscale-acl.example.hujson` | – | ACL snippet for the Tailscale admin console (ARCHITECTURE §8) |

What the hub adds on the NAS, and nothing else:

| Container | Image | Networks | Published |
|---|---|---|---|
| `yams-hub` | `yams-hub:latest` (built on the NAS) | `yams_network` (172.28.0.49) + `yams_hub_ctl` (172.30.250.2) | `0.0.0.0:8090` (IPv4 only) |
| `socket-proxy-hub` | `lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105` (pinned) | `yams_hub_ctl` only (172.30.250.3) | nothing |
| `yams-hub-updater` | `yams-hub-updater:latest` (built on the NAS) | `yams_hub_ctl` only (172.30.250.4) | nothing |

The network `yams_yams_hub_ctl` is 172.30.250.0/29 (gateway .1). Files: `/opt/yams/monitoring/secrets/yams-hub.env`
(uid 64090, 0400), `/opt/yams/monitoring/secrets/yams-hub-updater.env` (root, 0400),
`/opt/yams/monitoring/yams-hub/socket-proxy-hub.haproxy.cfg` (0644, no secret; written by `deploy.sh`), data dir
`/volume1/mediashare/config/yams-hub` (uid 64090, 0700). The core `/opt/yams/docker-compose.yaml` is never edited,
and no running service is restarted.

### How the control plane is protected (and what UGOS breaks)

`socket-proxy-hub` (restart/start/stop/kill any container) and `yams-hub-updater` (compose pull/up) must only ever be
reachable by the gateway. Docker's `internal: true` on `yams_hub_ctl` does **not** achieve that on Zenith: UGOS
installs, in the filter table,

```
-A DOCKER-USER -j UG_FORWARD
-A DOCKER-USER ! -i docker0 ! -o docker0 -j ACCEPT
```

and `DOCKER-USER` runs before Docker's own `DOCKER-FORWARD`, so its inter-bridge isolation and `DOCKER-INTERNAL` rules
never apply. Found on the first deploy (2026-11-08, Docker 29.4.3, iptables-nft): prowlarr on `yams_network` got
HTTP 200 from `GET /containers/json` on socket-proxy-hub by IP, and the "internal" network has internet egress.
The host firewall belongs to UGOS and is **not** modified (fragile, and it could break the live stack). Instead:

1. **Fixed addresses.** `yams_hub_ctl` has the subnet 172.30.250.0/29 and every hub container a static address.
   A peer on another bridge arrives with its own container address or, when Docker's per-bridge `MASQUERADE` rule
   rewrites it (likely for `yams_network`), with the control bridge's gateway address 172.30.250.1. Neither is ever
   172.30.250.2, so both are refused (the updater's refusal warnings may therefore name .1, not the real sender).
   `yams-hub`, the only container on both networks, has `net.ipv4.ip_forward=0`, so it never routes between them.
2. **Proxy source ACL.** `socket-proxy-hub` runs our copy of the image's template with
   `acl from_hub src 172.30.250.2 127.0.0.1` + `tcp-request connection reject if !from_hub`: every other peer is
   dropped before haproxy reads a byte of HTTP (127.0.0.1 is only reachable from inside the proxy's own network
   namespace; it keeps a localhost `HEALTHCHECK` of a future image working). `DISABLE_IPV6=1` makes it bind IPv4
   only, so `src` is a plain IPv4 address.
3. **Updater source allow-list.** `UPDATER_ALLOWED_SOURCES=172.30.250.2`: every other peer gets a bare 403 before
   the token is even looked at (loopback is always allowed, for the in-container `HEALTHCHECK`).
4. **Updater token**, as before (≥ 32 bytes, constant-time, 401 on every path without it).

Not relied upon: `internal: true` (kept, it documents the intent) and the absence of egress (the updater and the
proxy can reach the internet on Zenith; neither needs it). Every deploy that includes `socket-proxy-hub` proves the
ACL is in effect afterwards (the rendered config is HEAD's template, and the host gets no HTTP answer from
172.30.250.3:2375); if it is not, `deploy.sh` **stops the proxy** and fails (the hub then shows docker as down,
which beats every container being able to restart every other). `verify.sh` check 1 tests what actually answers,
from prowlarr and from the host, and checks the rendered config, the addresses, the members and that no container
shares a hub container's network namespace.

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
   `HUB_IP` at the top of `deploy.sh`. The control subnet 172.30.250.0/29 must not overlap any Docker network
   (`deploy.sh` checks it; by hand:
   `ssh nas "docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' \$(docker network ls -q)"`).
   Changing it means changing `HUB_CTL_*` in `deploy.sh` and `verify.sh`, the addresses in the compose file,
   `UPDATER_ALLOWED_SOURCES` and the ACL in `socket-proxy-hub/haproxy.cfg` together (`deploy/test/deploy_test.sh`
   fails when they disagree).
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
container.) Every later bump of this image repeats the `haproxy.cfg` review of integrations/system.md §2.1 **and** a
re-diff of `socket-proxy-hub/haproxy.cfg` against the new image's `/templates/haproxy.cfg` (commands in that file's
header): our copy replaces the image's template, so upstream changes are not picked up by themselves.

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
  `yams_hub_ctl:` entry under it; otherwise add the whole block:

  ```yaml
  networks:
    yams_hub_ctl:
      internal: true            # intent only: UGOS's DOCKER-USER ACCEPT defeats it; not relied upon
      ipam:
        config:
          - subnet: 172.30.250.0/29     # .1 bridge gateway, .2 yams-hub, .3 socket-proxy-hub, .4 yams-hub-updater
            gateway: 172.30.250.1
  ```

  `yams_network` itself is already defined by the stack; do not redefine it.
- All three services use long-form `networks:` with a fixed `ipv4_address`: `yams-hub` 172.28.0.49 on
  `yams_network` and 172.30.250.2 on `yams_hub_ctl`; the proxy 172.30.250.3 and the updater 172.30.250.4, both on
  `yams_hub_ctl` only and **not** on `yams_network`. Keep the proxy's `DISABLE_IPV6=1` and template volume and the
  updater's `UPDATER_ALLOWED_SOURCES` exactly as in the snippet (`deploy.sh` refuses to deploy without them).
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

1. NAS preflight: the three services are in the merged compose config with the fixed control network (subnet,
   addresses, proxy template mount and `DISABLE_IPV6`, `UPDATER_ALLOWED_SOURCES`), 172.28.0.49 is free, no other
   network or host route overlaps 172.30.250.0/29, and an existing `yams_yams_hub_ctl` already has that subnet
   and gateway. The settings are checked per service, so a line in the wrong service block does not count.
2. `flutter build web --release --no-web-resources-cdn` locally, `*.symbols` deleted.
3. Streams `git archive HEAD` (`packages/yams_models`, `gateway`, `updater`, `deploy`, `.dockerignore`) plus
   `app/build/web` as one tar over ssh into a `mktemp -d /tmp/yams-hub-deploy.XXXXXX` on the NAS.
4. `docker build` of `gateway/Dockerfile` (context = the repo root) and `updater/Dockerfile` (context = `updater/`)
   on the NAS, tagged `:latest` (the image the running container uses becomes `:previous`, the rollback image) with
   the git revision as the `org.opencontainers.image.revision` label. The updater image also carries
   `yams-hub.updater-tree`, the git tree id of `updater/`, so later deploys can tell whether it changed.
   Then it installs `socket-proxy-hub/haproxy.cfg` as `/opt/yams/monitoring/yams-hub/socket-proxy-hub.haproxy.cfg`
   (temp file + rename, 0644, only when the content changed; if the directory is not writable by Zenith, through
   a throwaway `--network none` root container of the digest-pinned socket-proxy image from the merged file, or
   `CFG_HELPER_IMAGE`). The image renders the template only at start and a single-file bind mount keeps showing
   the old file, so `deploy.sh` compares what the running proxy serves (`/run/haproxy/haproxy.cfg`) with HEAD's
   template and force-recreates `socket-proxy-hub` first when they differ. That also catches a template that an
   earlier, interrupted deploy installed but never got rendered.
5. **`make_hub_env.sh`** on the NAS, over `ssh -t`: creates the data dir (uid 64090, 0700), writes both secrets files
   and **asks for the hub admin password** (at least 10 characters; it is hashed by `yams-hub hash-password` inside
   the image and only the hash is stored). It ends with `yams-hub check-config`; check that every service you expect
   says `configured`.
6. Snapshot of `docker ps -a` ids, then `COMPOSE up -d --no-deps yams-hub socket-proxy-hub yams-hub-updater`, then a
   second snapshot. **If any other container changed id, appeared or disappeared, the deploy fails loudly** and
   lists them.
7. Waits until `yams-hub` and `yams-hub-updater` report `healthy`, pings `http://127.0.0.1:8090/api/v1/ping`, then
   proves the proxy's source ACL is in effect (see "How the control plane is protected"); an exposed proxy is
   stopped and the deploy fails.

`deploy.sh` itself is tested without a NAS by `bash deploy/test/deploy_test.sh` (fake `ssh` and `docker`).
8. **`verify.sh`** on the NAS (it asks for the admin password once for the `/health` check). All 7 checks must say
   PASS; check 7 says SKIP for the Tailscale URL until Tailscale is logged in (re-run it then, see below).
   Check 1 proves that prowlarr and the host are refused by both the proxy and the updater; check 5 (docker `up`,
   updater `up`) proves that the gateway itself still gets through.

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

## Upgrade: fixed control network (one time, after 2026-11-08)

Only for a hub deployed before the source ACLs existed (the first deploy on 2026-11-08 was: `verify.sh` check 1
failed with "prowlarr reached socket-proxy-hub by IP (172.18.0.2)"). Docker gave that `yams_yams_hub_ctl` an
automatic subnet (172.18.0.0/16), and **compose cannot change the subnet of an existing network**, so the network
has to be removed and recreated once. That stops the hub and its two helpers for about a minute; no stack service
is touched (the `docker ps` id snapshot still proves it).

Steps 2 and 3 belong together: **do them back to back**, and run no whole-project `docker compose up` (nor
anything that does one for the whole stack) in between. Until the migration, the re-merged file declares static
addresses on a network that has none, and a bind mount whose file does not exist yet, so such a run would fail to
recreate the hub containers (leaving them stopped). Single-service runs such as the updater's
`compose up -d --no-deps -- <svc>` are not affected. If you have to stop half way, put the backup back.

1. Back up the custom compose file (first-deploy step 1).
2. Re-merge: in `/opt/yams/docker-compose.custom.yaml`, replace the `yams_hub_ctl:` network entry and the three
   service blocks with the ones from `docker-compose.hub.yaml` (keep the digest-pinned proxy `image:`), then
   validate and swap in exactly as in first-deploy step 3. The diff of the merged configs must only show the three
   hub services and `yams_hub_ctl`.
3. Commit, make sure the hub's Updates screen shows no running job, then:

   ```sh
   deploy/deploy.sh --dry-run --migrate-ctl-network   # shows the migration commands; nothing runs
   deploy/deploy.sh --migrate-ctl-network
   ```

   Without the flag, `deploy.sh` stops in the preflight ("exists with subnet 172.18.0.0/16, but the compose file
   now pins 172.30.250.0/29") and prints these commands. This is the same migration by hand (only these three
   containers and this network, nothing else), followed by a normal deploy:

   ```sh
   ssh nas 'docker stop yams-hub yams-hub-updater socket-proxy-hub && docker rm yams-hub yams-hub-updater socket-proxy-hub && docker network rm yams_yams_hub_ctl'
   deploy/deploy.sh
   ```

   `docker stop` honours the updater's `stop_grace_period`, so a job that started meanwhile still finishes its
   step. `--migrate-ctl-network` refuses when any other container, running or stopped, is attached to
   `yams_yams_hub_ctl` (disconnect it first; it re-checks right before removing anything), and is a no-op once the
   network has the right subnet and gateway. It needs all three services, so it cannot be
   combined with `--only`; an unchanged updater is recreated from the image it already runs.
4. Run `verify.sh` as in "Optional follow-ups" below: check 1 must now PASS, and check 5 must show docker and
   updater `up`.

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

An updater `:previous` built before `UPDATER_ALLOWED_SOURCES` existed ignores that variable, so only its token
protects it: `verify.sh` check 1 then FAILs with "got HTTP 401 from the updater". Roll forward again as soon as you
can. Reverting the custom file from its backup after the control-network migration also works (the old blocks set
no addresses), but it gives up the fixed addresses the source ACLs are written for.

### Remove the hub completely

Nothing else depends on the hub; Homepage keeps running the whole time (it is only replaced in phase 3).

```sh
# 1. stop and remove only the three hub containers (while they are still in the compose file)
ssh nas 'cd /opt/yams && docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml \
  rm -s -f yams-hub yams-hub-updater socket-proxy-hub'
# 2. restore the custom file from the backup of first-deploy step 1 (use the right timestamp)
ssh nas 'cd /opt/yams && ls docker-compose.custom.yaml.bak-* &&
  cp -p docker-compose.custom.yaml.bak-YYYYMMDD-HHMM docker-compose.custom.yaml'
# 3. remove the control network, the proxy template and the images
ssh nas 'docker network rm yams_yams_hub_ctl;
  rm -f /opt/yams/monitoring/yams-hub/socket-proxy-hub.haproxy.cfg; rmdir /opt/yams/monitoring/yams-hub;
  docker image rm yams-hub:latest yams-hub:previous yams-hub-updater:latest yams-hub-updater:previous'
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
| `deploy.sh`: "docker-compose.custom.yaml predates the fixed control network" | The merged file is from before the source ACLs: re-merge ("Upgrade: fixed control network", step 2). The message lists what is missing. |
| `deploy.sh`: "yams_yams_hub_ctl exists with subnet ..." | The one-time network migration is due: "Upgrade: fixed control network", step 3. Nothing was changed. |
| `deploy.sh`: "172.30.250.0/29 overlaps the Docker network(s) ..." or "... overlaps host route(s)" | Another network, a UGOS bridge or a VPN uses that range: pick a free /29 and change it everywhere listed in "Before you start" item 2. |
| `deploy.sh`: "socket-proxy-hub is NOT protected by its source ACL" (proxy stopped) | What it serves lacks the ACL, or the host got an HTTP answer from 172.30.250.3:2375. Compare `ssh nas docker exec socket-proxy-hub cat /run/haproxy/haproxy.cfg` with `socket-proxy-hub/haproxy.cfg` and check the bind mount (`docker inspect -f '{{json .Mounts}}' socket-proxy-hub`); fix, then `deploy/deploy.sh --skip-web --only socket-proxy-hub`. Until then the hub shows docker as down. |
| `deploy.sh`: "serves an ACL, but not exactly HEAD's template rendered with bind :2375" | Usually a new image that ignores `DISABLE_IPV6` (bind `[::]:2375 v4v6`) or renders differently: re-diff the template against the image (`haproxy.cfg` header). The proxy keeps running with its ACL. |
| `deploy.sh`: "... differs from HEAD (or is missing), and socket-proxy-hub is not part of this deploy" | `--only` without `socket-proxy-hub` after `socket-proxy-hub/haproxy.cfg` changed: `deploy/deploy.sh --skip-web --only socket-proxy-hub`. |
| `verify.sh` check 1: "... reached socket-proxy-hub" or "got HTTP 200/401 from the updater" | The source ACLs are not in effect: the proxy runs without the template (check 1 also greps `/run/haproxy/haproxy.cfg`), the updater lacks `UPDATER_ALLOWED_SOURCES`, or the addresses differ from the compose file. Re-merge and redeploy; until then any container can restart containers through the proxy. |
| `verify.sh` check 5: docker or updater not `up` after the upgrade | The gateway is refused by its own ACLs: `docker inspect -f '{{json .NetworkSettings.Networks}}' yams-hub` must show 172.30.250.2 on `yams_yams_hub_ctl`; `docker logs yams-hub-updater` names refused peers ("refused GET from ..."). |
| `deploy.sh`: "containers outside the hub changed id" | Something else was recreated during `up` (e.g. a dependency or a concurrent Watchtower run). Inspect with `docker ps -a`; the hub services were deployed with `--no-deps`, so this should never be caused by the hub itself. |
| `yams-hub` stays `unhealthy` | `docker logs --tail 50 yams-hub`; typical: data dir not owned by 64090 (re-run `make_hub_env.sh`, it fixes the owner), invalid policy file (`check-config` names the key). |
| Updates screen says the updater is unavailable | `docker logs yams-hub-updater`: "refusing to start" means the token file is missing or shorter than 32 bytes; re-run `make_hub_env.sh` and recreate both containers. |
| `verify.sh` check 4 fails on `/host/proc/1/net/dev` | The single-file bind does not track the host netns on this UGOS build: change that volume to `/proc:/host/proc:ro` (keep `HOST_NET_DEV=/host/proc/1/net/dev`), recreate `yams-hub`, and note it in `/opt/yams/monitoring/README.md`. |
| `verify.sh` check 6 lists a container | A container with `stdin_open: true`; the attach residual of ARCHITECTURE §5.16 applies to it. Remove `stdin_open` from its compose entry unless it needs it. |

## The updater sidecar

`yams-hub-updater` (source in [`../updater`](../updater)) is the only container with a writable Docker socket. It
listens only on `yams_hub_ctl`, answers a bare 403 to every peer not in `UPDATER_ALLOWED_SOURCES` (the compose file
sets the gateway's 172.30.250.2; loopback is always allowed; unset, it logs a warning at start-up and only the token
protects it), requires `Authorization: Bearer <UPDATER_TOKEN>` on every path (401 otherwise, even for unknown paths),
and can only run, for one compose service from `COMPOSE config --services` that is not in
`UPDATER_DENY` (default `yams-hub,yams-hub-updater,socket-proxy-hub`; it never updates itself):
`compose pull -- <svc>`, `compose up -d --no-deps -- <svc>` (gluetun also force-recreates `qbittorrent`) and
`docker image prune -f`, plus the fixed `docker exec recyclarr recyclarr sync`. One job at a time, 15 minutes per step.
