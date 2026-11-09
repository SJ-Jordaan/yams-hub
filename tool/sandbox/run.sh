#!/usr/bin/env bash
# A disposable stock-YAMS server for end-to-end tests: ./install.sh and the hub run against it, locally and in CI
# (.github/workflows/sandbox.yml).
#
#   tool/sandbox/run.sh [--variant vpn-off|vpn-on] [COMMAND...]
#
#   up       start the sandbox YAMS stack (compose project sbx-yams) under $SANDBOX_DIR
#   seed     configure the apps through their own APIs (idempotent; Sonarr/Radarr lookups need internet)
#   install  run the real ./install.sh against it, unattended (--answers); needs ./build.sh first
#   test     smoke test of every hub page's API (smoke.py), plus the issue #2 Allowed Hosts check
#   screens  Playwright screenshots into the artifacts dir (optional: a failure only warns)
#   logs     save every sandbox and hub container's log into the artifacts dir
#   down     remove what the sandbox created: its containers, networks, volumes and $SANDBOX_DIR
#   all      down, up, seed, install, test, screens, logs, down (the default). KEEP=1 skips the last down.
#
# Environment:
#   SANDBOX_DIR        default ${XDG_CACHE_HOME:-~/.cache}/yams-hub-sandbox (INSTALL_DIRECTORY is its yams/,
#                      MEDIA_DIRECTORY its media/, throwaway passwords in secrets.env)
#   SANDBOX_ARTIFACTS  logs, results and screenshots; default $SANDBOX_DIR-artifacts (kept by down)
#   SANDBOX_HUB_PORT   the hub's port (default 28090). The apps listen on 127.0.0.1:2xxxx (see compose.yaml).
#   SANDBOX_SUBNET     the sandbox yams_network, a /24 (default 172.29.213.0/24)
#   SANDBOX_PYTHON     python for screens (default ~/development/perf-venv/bin/python when present, else python3)
#   KEEP=1             all: leave the sandbox running at the end (then: run.sh down)
#
# Fixed names it shares with a real install (so they must be free on this machine): the YAMS container names
# (jellyfin, sonarr, ...), the hub's containers (yams-hub, socket-proxy-hub, yams-hub-updater), compose project
# yams-hub and the hub's control network 172.30.250.0/29. `up` refuses to start when any of them belongs to
# something else, and `down` only removes what carries the sandbox's compose labels.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PROJECT='sbx-yams'
SBX_CONTAINERS=(jellyfin qbittorrent sonarr radarr bazarr prowlarr gluetun seerr)
HUB_CONTAINERS=(yams-hub socket-proxy-hub yams-hub-updater)
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}

SANDBOX_DIR=${SANDBOX_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/yams-hub-sandbox}
SANDBOX_DIR=${SANDBOX_DIR%/}
SANDBOX_ARTIFACTS=${SANDBOX_ARTIFACTS:-$SANDBOX_DIR-artifacts}
SANDBOX_HUB_PORT=${SANDBOX_HUB_PORT:-28090}
SANDBOX_SUBNET=${SANDBOX_SUBNET:-172.29.213.0/24}
YAMS=$SANDBOX_DIR/yams
MEDIA=$SANDBOX_DIR/media
STATE=$SANDBOX_DIR/state
MARKER=$SANDBOX_DIR/.yams-hub-sandbox
export SANDBOX_DIR SANDBOX_ARTIFACTS SANDBOX_HUB_PORT

if [[ -t 1 ]]; then
  bold=$'\e[1m' red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
else
  bold='' red='' green='' yellow='' reset=''
fi
die() {
  printf '%srun.sh: ERROR: %s%s\n' "$red" "$*" "$reset" >&2
  exit 1
}
warn() { printf '%sWARNING: %s%s\n' "$yellow" "$*" "$reset" >&2; }
step() { printf '\n%s==> [%s] %s%s\n' "$bold" "$variant" "$*" "$reset"; }

variant='vpn-off'
commands=()
while (($#)); do
  case "$1" in
    --variant)
      (($# >= 2)) || die '--variant needs vpn-off or vpn-on'
      variant=$2
      shift 2
      ;;
    --variant=*)
      variant=${1#--variant=}
      shift
      ;;
    -h | --help)
      sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    up | seed | install | test | screens | logs | down | all)
      commands+=("$1")
      shift
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ $variant == vpn-off || $variant == vpn-on ]] || die "unknown variant: $variant (vpn-off or vpn-on)"
((${#commands[@]})) || commands=(all)
export SANDBOX_VARIANT=$variant

[[ $SANDBOX_DIR == /* && $SANDBOX_DIR =~ ^/[A-Za-z0-9._/-]+$ && $SANDBOX_DIR != *..* ]] ||
  die "SANDBOX_DIR must be an absolute path of letters, digits and ._/- (got: $SANDBOX_DIR)"
case $SANDBOX_DIR in / | "$HOME" | /tmp | /var | /opt | /home | /usr) die "refusing SANDBOX_DIR=$SANDBOX_DIR" ;; esac
[[ $SANDBOX_SUBNET =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.0/24$ ]] || die "SANDBOX_SUBNET must be a /24 ending in .0/24"
NET_PREFIX=${BASH_REMATCH[1]}
[[ $SANDBOX_HUB_PORT =~ ^[0-9]+$ ]] || die "SANDBOX_HUB_PORT must be a number"

command -v docker >/dev/null || die 'docker not found'
docker info >/dev/null 2>&1 || die 'cannot talk to the Docker daemon'
docker compose version >/dev/null 2>&1 || die 'docker compose v2 is required'
command -v python3 >/dev/null || die 'python3 is required'

compose_files() {
  local f=(-f docker-compose.yaml)
  [[ -f $YAMS/docker-compose.vpn.yaml ]] && f+=(-f docker-compose.vpn.yaml)
  printf '%s\n' "${f[@]}"
}
compose_sbx() {
  local files
  mapfile -t files < <(compose_files)
  (cd "$YAMS" && docker compose -p "$PROJECT" "${files[@]}" "$@")
}
label() { docker inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true; }
container_exists() { docker container inspect "$1" >/dev/null 2>&1; }
# Ours: a YAMS container of project sbx-yams, or a hub container installed into this sandbox's YAMS dir.
ours() { [[ $(label "$1" com.docker.compose.project) == "$PROJECT" ]]; }
ours_hub() { [[ $(label "$1" com.docker.compose.project.working_dir) == "$YAMS/yams-hub" ]]; }

# ---------------------------------------------------------------------------------------------------------------
preflight() {
  local c bad=()
  for c in "${SBX_CONTAINERS[@]}"; do
    if container_exists "$c" && ! ours "$c"; then bad+=("container $c (project \"$(label "$c" com.docker.compose.project)\")"); fi
  done
  for c in "${HUB_CONTAINERS[@]}"; do
    if container_exists "$c" && ! ours_hub "$c"; then bad+=("container $c (not installed into $YAMS)"); fi
  done
  # The sandbox network must not overlap another Docker network or a host route (its own bridge's route aside).
  local nets own=() id
  # shellcheck disable=SC2046 # one network id per word
  nets=$(docker network inspect -f '{{.Name}} {{index .Labels "com.docker.compose.project"}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' \
    $(docker network ls -q) 2>/dev/null || true)
  for id in $(docker network ls -q --no-trunc --filter "label=com.docker.compose.project=$PROJECT"); do own+=("br-${id:0:12}"); done
  local routes=''
  if command -v ip >/dev/null; then routes=$(ip -4 route show 2>/dev/null || true); fi
  local overlap
  overlap=$(printf '%s\n--routes--\n%s\n' "$nets" "$routes" | python3 -c '
import ipaddress, sys
mine = ipaddress.ip_network(sys.argv[1]); project = sys.argv[2]; own = set(sys.argv[3:])
nets, _, routes = sys.stdin.read().partition("--routes--")
out = []
def net(s):
    try:
        n = ipaddress.ip_network(s, strict=False)
        return n if n.version == 4 else None
    except ValueError:
        return None
for line in nets.splitlines():
    f = line.split()
    if len(f) < 2:
        continue
    if f[1] == project:  # ours; a network without the label shows its first subnet in f[1]
        continue
    for s in f[1:]:
        n = net(s)
        if n and n.overlaps(mine):
            out.append(f"docker network {f[0]} ({s})")
for line in routes.splitlines():
    f = line.split()
    if not f or f[0] == "default" or ("dev" in f and f[f.index("dev") + 1:][:1] and f[f.index("dev") + 1] in own):
        continue
    n = net(f[0])
    if n and n.overlaps(mine):
        out.append("host route " + line.strip())
print("; ".join(out))
' "$SANDBOX_SUBNET" "$PROJECT" ${own[@]+"${own[@]}"})
  [[ -z $overlap ]] || bad+=("$SANDBOX_SUBNET overlaps: $overlap (set SANDBOX_SUBNET)")
  if ((${#bad[@]})); then
    printf '  %s\n' "${bad[@]}" >&2
    die 'these are in the way of the sandbox; it never touches them. Stop them or run the sandbox on another machine.'
  fi
  if [[ -f $STATE/variant && $(<"$STATE/variant") != "$variant" ]]; then
    die "the sandbox is set up as $(<"$STATE/variant"); run: tool/sandbox/run.sh down"
  fi
}

# secret KEY: a value from $SANDBOX_DIR/secrets.env.
secret() { grep -m1 "^$1=" "$SANDBOX_DIR/secrets.env" | cut -d= -f2-; }
gen_password() { head -c 18 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'; }

cmd_up() {
  step "up: compose project $PROJECT in $SANDBOX_DIR"
  preflight
  mkdir -p "$SANDBOX_DIR" "$STATE" "$SANDBOX_ARTIFACTS"
  : >"$MARKER"
  local svc
  for svc in "${SBX_CONTAINERS[@]}"; do mkdir -p "$YAMS/config/$svc"; done
  mkdir -p "$MEDIA/tvshows" "$MEDIA/movies" "$MEDIA/downloads/torrents"
  rm -rf "$YAMS/config/gluetun/www"
  cp -R "$HERE/gluetun-www" "$YAMS/config/gluetun/www"
  chmod -R a+rX "$YAMS/config/gluetun/www"
  cp "$HERE/compose.yaml" "$YAMS/docker-compose.yaml"
  local vpn=n
  if [[ $variant == vpn-on ]]; then
    cp "$HERE/compose.vpn-on.yaml" "$YAMS/docker-compose.vpn.yaml"
    vpn=y
  else
    rm -f "$YAMS/docker-compose.vpn.yaml"
  fi
  # The keys of stock YAMS's .env, plus the sandbox's subnet.
  cat >"$YAMS/.env" <<EOF
# YAMS sandbox (tool/sandbox/run.sh); throwaway.
PUID=$(id -u)
PGID=$(id -g)
MEDIA_DIRECTORY=$MEDIA
INSTALL_DIRECTORY=$YAMS
MEDIA_SERVICE=jellyfin
TZ=Etc/UTC
VPN_ENABLED=$vpn
VPN_SERVICE=sandbox
VPN_USER=sandbox
VPN_PASSWORD=sandbox
SBX_NET_PREFIX=$NET_PREFIX
EOF
  if [[ ! -s $SANDBOX_DIR/secrets.env ]]; then
    (
      umask 077
      {
        echo '# Throwaway sandbox passwords (tool/sandbox/run.sh); deleted by run.sh down.'
        echo 'SBX_JELLYFIN_USER=sbxadmin'
        echo "SBX_JELLYFIN_PASSWORD=jf-$(gen_password)"
        echo 'SBX_QBIT_USER=admin'
        echo "SBX_QBIT_PASSWORD=qb-$(gen_password)"
        echo 'SBX_ADMIN_USER=admin'
        echo "SBX_ADMIN_PASSWORD=hub-$(gen_password)"
      } >"$SANDBOX_DIR/secrets.env"
    )
  fi
  echo "$variant" >"$STATE/variant"
  compose_sbx up -d --quiet-pull
  compose_sbx ps
}

cmd_seed() {
  step 'seed: configure the apps through their APIs'
  [[ -f $MARKER ]] || die 'the sandbox is not up (run.sh up)'
  python3 "$HERE/seed.py"
}

cmd_install() {
  step 'install: ./install.sh --answers (unattended)'
  [[ -f $MARKER ]] || die 'the sandbox is not up (run.sh up)'
  [[ -f $REPO/app/build/web/index.html ]] || die "no web build in $REPO/app/build/web: run ./build.sh first"
  local key
  key=$(cat "$STATE/jellyfin_api_key" 2>/dev/null || true)
  [[ -n $key ]] || die 'no Jellyfin API key yet (run.sh seed)'
  local answers=$STATE/answers
  (
    umask 077
    {
      echo '# install.sh answers for the sandbox'
      echo "YAMS_DIR=$YAMS"
      echo "PORT=$SANDBOX_HUB_PORT"
      echo "JELLYFIN_API_KEY=$key"
      echo "QBIT_USERNAME=$(secret SBX_QBIT_USER)"
      echo "QBIT_PASSWORD=$(secret SBX_QBIT_PASSWORD)"
      echo "ADMIN_USERNAME=$(secret SBX_ADMIN_USER)"
      echo "ADMIN_PASSWORD=$(secret SBX_ADMIN_PASSWORD)"
    } >"$answers"
  )
  mkdir -p "$SANDBOX_ARTIFACTS"
  if ! "$REPO/install.sh" --answers "$answers" </dev/null 2>&1 | tee "$SANDBOX_ARTIFACTS/install-$variant.log"; then
    die "install.sh failed; log: $SANDBOX_ARTIFACTS/install-$variant.log"
  fi
  # A re-run must keep everything and touch nothing else (what users do after a reboot or an edit).
  step 'install: re-run (must change nothing outside the hub)'
  if ! "$REPO/install.sh" --answers "$answers" </dev/null 2>&1 | tee "$SANDBOX_ARTIFACTS/install-rerun-$variant.log"; then
    die "install.sh re-run failed; log: $SANDBOX_ARTIFACTS/install-rerun-$variant.log"
  fi
  grep -q 'no container outside the hub changed' "$SANDBOX_ARTIFACTS/install-rerun-$variant.log" ||
    die 'the install.sh re-run did not prove that no other container changed'
}

cmd_test() {
  step 'test: smoke test of the hub API'
  python3 "$HERE/smoke.py"
}

cmd_screens() {
  step 'screens: Playwright screenshots (optional)'
  local py=${SANDBOX_PYTHON:-}
  if [[ -z $py ]]; then
    if [[ -x $HOME/development/perf-venv/bin/python ]]; then py=$HOME/development/perf-venv/bin/python; else py=python3; fi
  fi
  if [[ -z ${PLAYWRIGHT_BROWSERS_PATH:-} && -d $HOME/development/ms-playwright ]]; then
    export PLAYWRIGHT_BROWSERS_PATH=$HOME/development/ms-playwright
  fi
  if ! "$py" -c 'import playwright' 2>/dev/null; then
    warn "screens skipped: playwright is not installed for $py (pip install playwright && playwright install chromium)"
    return 0
  fi
  "$py" "$HERE/screens.py" || warn 'screens failed (not fatal); see above'
}

cmd_logs() {
  local d=$SANDBOX_ARTIFACTS/logs-$variant c
  mkdir -p "$d"
  for c in "${SBX_CONTAINERS[@]}" "${HUB_CONTAINERS[@]}"; do
    if container_exists "$c" && { ours "$c" || ours_hub "$c"; }; then
      docker logs --timestamps "$c" >"$d/$c.log" 2>&1 || true
    fi
  done
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" --format '{{.Names}}\t{{.Image}}\t{{.Status}}' >"$d/ps.txt" 2>&1 || true
  docker ps -a --filter "label=com.docker.compose.project=yams-hub" --format '{{.Names}}\t{{.Image}}\t{{.Status}}' >>"$d/ps.txt" 2>&1 || true
  [[ -f $YAMS/yams-hub/compose.yaml ]] && cp "$YAMS/yams-hub/compose.yaml" "$d/hub-compose.yaml" # no secrets in it
  echo "logs: $d"
}

cmd_down() {
  step 'down: remove the sandbox'
  # The hub first (installed by install.sh into the sandbox's YAMS dir), only when it is ours.
  local hub_ours=1 c
  for c in "${HUB_CONTAINERS[@]}"; do
    if container_exists "$c" && ! ours_hub "$c"; then hub_ours=0; fi
  done
  if ((hub_ours)); then
    if [[ -f $YAMS/yams-hub/compose.yaml ]]; then
      docker compose -p yams-hub -f "$YAMS/yams-hub/compose.yaml" down -v --remove-orphans || true
    fi
  else
    warn 'the yams-hub containers belong to another install; left alone'
  fi
  # The YAMS stack: by compose file when it is still there, then anything left with the project's labels.
  if [[ -f $YAMS/docker-compose.yaml ]]; then compose_sbx down -v --remove-orphans || true; fi
  local ids=()
  mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")
  ((${#ids[@]} == 0)) || docker rm -f "${ids[@]}" >/dev/null
  mapfile -t ids < <(docker network ls -q --filter "label=com.docker.compose.project=$PROJECT")
  ((${#ids[@]} == 0)) || docker network rm "${ids[@]}" >/dev/null
  mapfile -t ids < <(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")
  ((${#ids[@]} == 0)) || docker volume rm "${ids[@]}" >/dev/null
  # The directory holds files owned by root and the hub's uid (written by install.sh): delete through a container.
  if [[ -f $MARKER ]]; then
    docker run --rm --network none -v "$SANDBOX_DIR:/m" "$ALPINE_IMAGE" sh -c 'rm -rf /m/..?* /m/.[!.]* /m/*'
    rmdir "$SANDBOX_DIR"
    echo "removed $SANDBOX_DIR"
  elif [[ -e $SANDBOX_DIR ]]; then
    warn "$SANDBOX_DIR has no sandbox marker; not deleting it"
  fi
}

# ---------------------------------------------------------------------------------------------------------------
# Each step runs as its own run.sh, so a failing step (die/exit, set -e) still leaves logs and a down behind.
run_all() {
  local rc=0 self=("$HERE/run.sh" --variant "$variant")
  "${self[@]}" down
  local step
  for step in up seed install test; do
    if ! "${self[@]}" "$step"; then
      rc=1
      break
    fi
  done
  if ((rc == 0)); then "${self[@]}" screens || true; fi
  "${self[@]}" logs || true
  if [[ ${KEEP:-0} == 1 ]]; then
    warn "KEEP=1: the sandbox keeps running (hub: http://127.0.0.1:$SANDBOX_HUB_PORT; remove: run.sh down)"
  else
    "${self[@]}" down || rc=$((rc ? rc : 1))
  fi
  if ((rc == 0)); then
    printf '\n%ssandbox %s: all passed%s\n' "$green" "$variant" "$reset"
  else
    printf '\n%ssandbox %s: FAILED (exit %d); artifacts in %s%s\n' "$red" "$variant" "$rc" "$SANDBOX_ARTIFACTS" "$reset" >&2
  fi
  return "$rc"
}

for c in "${commands[@]}"; do
  case $c in
    all) run_all ;;
    up) cmd_up ;;
    seed) cmd_seed ;;
    install) cmd_install ;;
    test) cmd_test ;;
    screens) cmd_screens ;;
    logs) cmd_logs ;;
    down) cmd_down ;;
  esac
done
