#!/usr/bin/env bash
# Installs YAMS Hub next to a stock YAMS install (https://yams.media). Run it ON the YAMS server, from the repo
# checkout, after ./build.sh (or with app/build/web copied over from the machine that built it).
#
#   ./install.sh                  install, or re-run (keeps the secrets, the admin and the port)
#   ./install.sh --update         after `git pull && ./build.sh`: rebuild and recreate the hub containers only
#   ./install.sh --reconfigure    ask again for the keys that cannot be read automatically
#   ./install.sh --uninstall      remove the hub containers (keeps its data; add --purge to delete it too)
#   ./install.sh --dry-run        detect and show what would be done; changes nothing
#   ./install.sh -h               this help
#
# Needs bash, docker with compose v2 and GNU grep; run it as root or as a user in the docker group.
# It writes <YAMS dir>/yams-hub/ (compose project "yams-hub") and <media dir>/config/yams-hub/ only.
# YAMS's own compose files are never modified and no YAMS container is restarted.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=yams-hub
HUB_UID=64090
HUB_CONTAINERS=(yams-hub socket-proxy-hub yams-hub-updater)
HUB_IMAGE=yams-hub:latest
UPDATER_IMAGE=yams-hub-updater:latest
PROXY_IMAGE=lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105@sha256:823dda971e9a3951257eb251586a804199819fe1587c35faa43adc7b52a2ff16
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}
CTL_NET=yams-hub_ctl
CTL_BRIDGE=br-yams-hub
CTL_SUBNET=172.30.250.0/29
DEFAULT_PORT=8090

mode=install reconfigure=0 purge=0 dry_run=0
for arg in "$@"; do
  case "$arg" in
    --update) mode=update ;;
    --uninstall) mode=uninstall ;;
    --reconfigure) reconfigure=1 ;;
    --purge) purge=1 ;;
    --dry-run) dry_run=1 ;;
    -h | --help)
      sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done
if ((purge)) && [[ $mode != uninstall ]]; then
  echo '--purge only goes with --uninstall' >&2
  exit 2
fi
if ((reconfigure)) && [[ $mode != install ]]; then
  echo '--reconfigure does not go with --update or --uninstall' >&2
  exit 2
fi

if [[ -t 1 ]]; then
  bold=$'\e[1m' red=$'\e[31m' green=$'\e[32m' reset=$'\e[0m'
else
  bold='' red='' green='' reset=''
fi
die() {
  printf '%sinstall.sh: ERROR: %s%s\n' "$red" "$*" "$reset" >&2
  exit 1
}
info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
step() { printf '\n%s==> %s%s\n' "$bold" "$*" "$reset"; }

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------
# helper DIR SCRIPT ARGS...: runs SCRIPT in a throwaway alpine container with DIR at /m. Root-owned
# changes go through it, so no sudo is needed. SCRIPT and ARGS hold paths and ids only, never a secret.
helper() {
  local dir=$1 script=$2
  shift 2
  docker run --rm --network none -v "$dir:/m" "$ALPINE_IMAGE" sh -euc "$script" sh "$@"
}

# read_file PATH: prints a file, through the helper (read-only) when this user cannot read it.
read_file() {
  local f=$1 dir
  if [[ -r $f ]]; then
    cat -- "$f"
    return
  fi
  dir=$(dirname -- "$f")
  [[ -d $dir ]] || return 1 # never let `docker run -v` create a missing directory
  docker run --rm --network none -v "$dir:/m:ro" "$ALPINE_IMAGE" sh -euc 'cat "/m/$1"' sh "$(basename -- "$f")" 2>/dev/null
}

# A prompt: from the terminal (secrets without echo) or, without one, a line of stdin.
ask() { # PROMPT [DEFAULT] -> REPLY
  local p=$1 def=${2-}
  [[ -n $def ]] && p="$p [$def]"
  REPLY=''
  if [[ -t 0 ]]; then
    IFS= read -rp "$p: " REPLY || true
  else
    IFS= read -r REPLY || true
  fi
  REPLY=${REPLY%$'\r'}
  [[ -n $REPLY ]] || REPLY=$def
}
ask_secret() { # PROMPT -> REPLY
  REPLY=''
  if [[ -t 0 ]]; then
    IFS= read -rsp "$1: " REPLY || true
    printf '\n' >&2
  else
    IFS= read -r REPLY || true
  fi
  REPLY=${REPLY%$'\r'}
}

# KEY=value from YAMS's .env text ($env_text); quotes stripped.
env_get() {
  local v
  v=$(grep -m1 -E "^[[:space:]]*$1=" <<<"$env_text" | cut -d= -f2- || true)
  v=${v%$'\r'}
  v=${v%"${v##*[![:space:]]}"}
  v=${v#\"} v=${v%\"} v=${v#\'} v=${v%\'}
  printf '%s' "$v"
}

safe_path() { [[ $1 =~ ^/[A-Za-z0-9._/-]*$ && $1 != *..* ]]; }

ip4() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}
ip4_str() { echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"; }
overlaps() { # NET/PREFIX CANDIDATE -> 0 when they share an address (IPv6 candidates never do)
  local n1=${1%/*} p1=${1#*/} n2=${2%/*} p2=32 m mask
  [[ $2 == */* ]] && p2=${2#*/}
  [[ $n2 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && $p2 =~ ^[0-9]+$ ]] || return 1
  m=$((p1 < p2 ? p1 : p2))
  mask=$((m == 0 ? 0 : (0xffffffff << (32 - m)) & 0xffffffff))
  (($(($(ip4 "$n1") & mask)) == $(($(ip4 "$n2") & mask))))
}

# ---------------------------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------------------------
command -v docker >/dev/null || die 'docker not found'
docker info >/dev/null 2>&1 || die 'cannot talk to the Docker daemon (run as root or as a user in the docker group)'
docker compose version >/dev/null 2>&1 || die 'docker compose v2 is required (the `docker compose` plugin)'
if ! grep -qP 'x' <<<'x' 2>/dev/null; then die 'GNU grep with -P is required'; fi
if [[ $mode != uninstall ]]; then
  [[ -f $ROOT/app/build/web/index.html ]] || die "no web build in $ROOT/app/build/web: run ./build.sh first"
fi

declare -A cstate=()
while IFS=$'\t' read -r name state; do
  [[ -n $name ]] && cstate[$name]=$state
done < <(docker ps -a --format '{{.Names}}\t{{.State}}')
exists() { [[ -n ${cstate[$1]-} ]]; }

# ---------------------------------------------------------------------------------------------
# Find YAMS
# ---------------------------------------------------------------------------------------------
exists sonarr || die 'no sonarr container: install.sh expects a YAMS install (https://yams.media)'
labels=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project.config_files"}}' sonarr)
IFS='|' read -r yams_project yams_dir yams_files <<<"$labels"
[[ $yams_project != '<no value>' ]] || yams_project=''
[[ $yams_dir != '<no value>' ]] || yams_dir=''
[[ $yams_files != '<no value>' ]] || yams_files=''
if [[ -z $yams_dir || ! -d $yams_dir ]]; then
  if [[ $mode == install ]] && ((!dry_run)); then
    ask 'YAMS install directory (INSTALL_DIRECTORY)' /opt/yams
    yams_dir=$REPLY
  else
    yams_dir=/opt/yams
  fi
fi
yams_dir=${yams_dir%/}
safe_path "$yams_dir" || die "unsupported YAMS directory path: $yams_dir"
env_text=$(read_file "$yams_dir/.env") || die "cannot read $yams_dir/.env: is that the YAMS install directory?"
MEDIA=$(env_get MEDIA_DIRECTORY)
MEDIA=${MEDIA%/}
TZ_NAME=$(env_get TZ)
MEDIA_SERVICE=$(env_get MEDIA_SERVICE)
[[ -n $MEDIA ]] || die "MEDIA_DIRECTORY is not set in $yams_dir/.env"
safe_path "$MEDIA" || die "unsupported MEDIA_DIRECTORY path: $MEDIA"
[[ $TZ_NAME =~ ^[A-Za-z0-9/_+-]+$ ]] || TZ_NAME=UTC
MEDIA_SERVICE=${MEDIA_SERVICE:-jellyfin}
[[ -n $yams_project ]] || yams_project=yams

HUB_DIR=$yams_dir/yams-hub
SECRETS=$HUB_DIR/secrets
HUB_ENV=$SECRETS/yams-hub.env
UPDATER_ENV=$SECRETS/updater.env
COMPOSE=$HUB_DIR/compose.yaml
CONF=$HUB_DIR/install.conf
DATA_DIR=$MEDIA/config/yams-hub
compose_hub() { docker compose -p "$PROJECT" -f "$COMPOSE" "$@"; }

installed=0
[[ -f $COMPOSE ]] && installed=1

# ---------------------------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------------------------
if [[ $mode == uninstall ]]; then
  ((installed)) || die "YAMS Hub is not installed here ($COMPOSE is missing)"
  if ((dry_run)); then
    info "would run: docker compose -p $PROJECT -f $COMPOSE down"
    ((purge)) && info "would delete $HUB_DIR, $DATA_DIR and the hub images"
    exit 0
  fi
  if ((purge)); then
    info "This deletes the hub's users, settings and secrets ($HUB_DIR and $DATA_DIR)."
    ask 'Type purge to confirm'
    [[ $REPLY == purge ]] || die 'not confirmed; nothing was changed'
  fi
  step "docker compose -p $PROJECT down"
  compose_hub down
  if ((purge)); then
    helper "$yams_dir" 'rm -rf /m/yams-hub'
    helper "$MEDIA/config" 'rm -rf /m/yams-hub'
    docker image rm "$HUB_IMAGE" "$UPDATER_IMAGE" >/dev/null 2>&1 || true
    info "deleted $HUB_DIR, $DATA_DIR and the hub images"
  else
    info "kept $HUB_DIR and $DATA_DIR (./install.sh brings the hub back; --uninstall --purge deletes them)"
  fi
  exit 0
fi

if [[ $mode == update ]]; then
  ((installed)) || die 'YAMS Hub is not installed yet: run ./install.sh first'
fi
interactive=0
if [[ $mode == install ]] && ((!dry_run)); then interactive=1; fi

conf_get() { [[ -r $CONF ]] && grep -m1 -oP "^$1=\\K[A-Za-z0-9._:/-]*" "$CONF" || true; }

# ---------------------------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------------------------
step 'YAMS'
info "install dir:   $yams_dir (compose project \"$yams_project\")"
info "media dir:     $MEDIA (media server: $MEDIA_SERVICE, TZ $TZ_NAME)"

yams_net=''
while read -r n; do
  [[ -z $n || $n == bridge || $n == host || $n == none ]] && continue
  if [[ -z $yams_net || $n == yams_network ]]; then yams_net=$n; fi
done < <(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' sonarr)
[[ -n $yams_net ]] || die 'sonarr is not on a user-defined Docker network'
[[ $yams_net =~ ^[A-Za-z0-9_.-]+$ ]] || die "unsupported network name: $yams_net"
info "network:       $yams_net"

# The control subnet must not clash with another Docker network or a host route.
clash=()
while read -r name; do
  [[ -n $name && $name != "$CTL_NET" ]] || continue
  for sn in $(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$name" 2>/dev/null || true); do
    if overlaps "$CTL_SUBNET" "$sn"; then clash+=("$name ($sn)"); fi
  done
done < <(docker network ls --format '{{.Name}}')
if command -v ip >/dev/null; then
  while read -r line; do
    [[ -n $line ]] || continue
    read -r -a f <<<"$line"
    dst=${f[0]}
    case $dst in unicast | blackhole | unreachable | prohibit | throw | local | broadcast | multicast | anycast | nat) dst=${f[1]:-} ;; esac
    [[ -n $dst && $dst != default ]] || continue
    [[ " $line " == *" dev $CTL_BRIDGE "* ]] && continue # our own bridge
    if overlaps "$CTL_SUBNET" "$dst"; then clash+=("host route: $line"); fi
  done < <(ip -4 route show 2>/dev/null || true)
fi
if ((${#clash[@]})); then
  printf '%s overlaps:\n' "$CTL_SUBNET" >&2
  printf '  %s\n' "${clash[@]}" >&2
  die "the hub's control network needs $CTL_SUBNET: move or remove what uses it, then re-run"
fi

# A fixed address on the YAMS network, high in its subnet: a dynamic one could take the static address of a YAMS
# container that is not running at that moment (after a reboot, for instance), and that container would not start.
yams_subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$yams_net" | grep -oP -m1 '\b[0-9]+(\.[0-9]+){3}/[0-9]+\b' | head -n1 || true)
hub_ip=''
if [[ -n $yams_subnet ]]; then
  used=" $(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' "$yams_net") "
  while read -r cname cip; do
    [[ -n ${cip:-} && $cname != yams-hub ]] && used+="${cip%/*} "
  done < <(docker network inspect -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' "$yams_net")
  IFS=, read -r -a cfg_files <<<"$yams_files"
  for f in "${cfg_files[@]}"; do
    used+="$(read_file "$f" 2>/dev/null | grep -oP 'ipv4_address:\s*["'\'']?\K[0-9.]+' | tr '\n' ' ' || true) "
  done
  prefix=${yams_subnet#*/}
  ((prefix <= 26)) || die "$yams_net ($yams_subnet) is too small for a fixed hub address"
  base=$(($(ip4 "${yams_subnet%/*}") & ((0xffffffff << (32 - prefix)) & 0xffffffff)))
  size=$((1 << (32 - prefix)))
  stored=$(conf_get HUB_IP)
  if [[ -n $stored ]] && overlaps "$yams_subnet" "$stored" && [[ $used != *" $stored "* ]]; then
    hub_ip=$stored
  else
    for ((i = size - 6; i > size - 56 && i > 1; i--)); do
      cand=$(ip4_str $((base + i)))
      if [[ $used != *" $cand "* ]]; then
        hub_ip=$cand
        break
      fi
    done
    [[ -n $hub_ip ]] || die "no free address for the hub at the top of $yams_subnet"
  fi
  info "hub address:   $hub_ip on $yams_net"
fi

# ---------------------------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------------------------
step 'Services'
# config_dir NAME DEST: the host directory mounted at DEST in container NAME.
config_dir() {
  local d
  d=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Source}}{{end}}{{end}}" "$1" 2>/dev/null || true)
  [[ -n $d ]] || d=$MEDIA/config/$1
  printf '%s' "$d"
}
container_env() { # NAME KEY
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | grep -m1 -oP "^$2=\\K.*" || true
}

declare -A url=() out=() source_of=() existing=()
order=(
  YAMS_HUB_ADMIN_USERNAME YAMS_HUB_ADMIN_PASSWORD_HASH
  SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY BAZARR_API_KEY SEERR_API_KEY
  JELLYFIN_API_KEY JELLYSTAT_API_KEY QBIT_USERNAME QBIT_PASSWORD
  WATCHTOWER_TOKEN UPDATER_TOKEN ABS_API_KEY KAVITA_API_KEY
)
url_order=(
  SONARR_URL RADARR_URL PROWLARR_URL BAZARR_URL SEERR_URL JELLYFIN_URL JELLYSTAT_URL QBIT_URL GLUETUN_URL
  WATCHTOWER_URL UPTIME_KUMA_URL ABS_URL KAVITA_URL SHELFMARK_URL
)
for v in "${url_order[@]}"; do url[$v]=''; done

check_value() {
  [[ $2 != *"'"* ]] || die "$1 contains a single quote; refusing"
  [[ $2 != *$'\n'* && $2 != *$'\r'* ]] || die "$1 contains a newline; refusing"
}
put() { # KEY VALUE SOURCE
  check_value "$1" "$2"
  out[$1]=$2
  source_of[$1]=$3
}

# Existing secrets (re-runs). The files are 0400 and not ours: read them through the helper.
if [[ -d $SECRETS ]]; then
  for f in "$HUB_ENV" "$UPDATER_ENV"; do
    text=$(read_file "$f" 2>/dev/null || true)
    while IFS= read -r line; do
      if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'([^\']*)\'[[:space:]]*$ ]]; then
        existing[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
      fi
    done <<<"$text"
  done
  unset text line
fi
[[ $mode != update || -n ${existing[UPDATER_TOKEN]-} ]] || die "cannot read $UPDATER_ENV: run ./install.sh (without --update)"
first_run=1
[[ -n ${existing[UPDATER_TOKEN]-} ]] && first_run=0
# Values only a person can give are asked for on the first run and with --reconfigure.
prompting=0
if ((interactive && (first_run || reconfigure))); then prompting=1; fi

# prompt_secret KEY LABEL HINT [spaces]: asks for a value that cannot be read automatically. Keys never contain
# spaces (a space is a copy-paste slip); pass "spaces" for a password.
prompt_secret() {
  local key=$1 label=$2 hint=$3 spaces=${4-} keep=''
  if ((!prompting)); then
    if [[ -n ${existing[$key]-} ]]; then put "$key" "${existing[$key]}" kept; fi
    return 0
  fi
  [[ -n ${existing[$key]-} ]] && keep=' (Enter keeps the current one, - clears it)'
  info "  $label: $hint$keep"
  ask_secret "  $label (Enter skips)"
  if [[ -z $REPLY && -n ${existing[$key]-} ]]; then
    put "$key" "${existing[$key]}" kept
  elif [[ -n $REPLY && $REPLY != - ]]; then
    [[ $spaces == spaces || $REPLY != *[[:space:]]* ]] || die "$label must not contain spaces"
    put "$key" "$REPLY" entered
  fi
  REPLY=''
}

# auto_secret KEY VALUE FILE LABEL HINT: a key read from the app's own config, else kept or asked for.
auto_secret() {
  local key=$1 value=$2 file=$3
  if [[ -n $value ]]; then
    put "$key" "$value" "$file"
  else
    warn "$key not found in $file"
    prompt_secret "$key" "$4" "$5"
  fi
}

found=()
on_yams_net() {
  local nets
  nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" 2>/dev/null || true)
  [[ " $nets " == *" $yams_net "* ]]
}
# note_found NAME [NETWORK_CONTAINER]: notes a detected container; fails (with a warning) when the hub cannot reach it.
note_found() {
  local s=${cstate[$1]}
  if ! on_yams_net "${2:-$1}"; then
    warn "$1 is not on $yams_net, so the hub cannot reach it; leaving it off"
    return 1
  fi
  if [[ $s == running ]]; then found+=("$1"); else found+=("$1 ($s)"); fi
}

for svc in sonarr radarr prowlarr; do
  exists "$svc" && note_found "$svc" || continue
  svc_port=$(case $svc in sonarr) echo 8989 ;; radarr) echo 7878 ;; prowlarr) echo 9696 ;; esac)
  var=${svc^^}
  url[${var}_URL]=http://$svc:$svc_port
  file=$(config_dir "$svc" /config)/config.xml
  key=$(read_file "$file" 2>/dev/null | grep -oP -m1 '<ApiKey>\K[A-Za-z0-9]+(?=</ApiKey>)' || true)
  auto_secret "${var}_API_KEY" "$key" "$file" "${svc^} API key" 'Settings > General > Security > API Key'
done

if exists bazarr && note_found bazarr; then
  url[BAZARR_URL]=http://bazarr:6767
  file=$(config_dir bazarr /config)/config/config.yaml
  key=$(read_file "$file" 2>/dev/null | awk '
    /^[^[:space:]#]/ { in_auth = ($0 ~ /^auth:/) }
    in_auth && /^[[:space:]]+apikey:/ { sub(/^[[:space:]]+apikey:[[:space:]]*/, ""); gsub(/["'\'' ]/, ""); print; exit }' || true)
  [[ $key =~ ^[A-Za-z0-9]+$ ]] || key=''
  auto_secret BAZARR_API_KEY "$key" "$file" 'Bazarr API key' 'Settings > General > Security > API Key'
fi

for name in seerr jellyseerr overseerr; do
  exists "$name" || continue
  note_found "$name" || break
  url[SEERR_URL]=http://$name:5055
  file=$(config_dir "$name" /app/config)/settings.json
  key=$(read_file "$file" 2>/dev/null | tr -d '\0' | grep -zoP '"main"\s*:\s*\{[^{}]*?"apiKey"\s*:\s*"\K[^"]+' | tr -d '\0' || true)
  auto_secret SEERR_API_KEY "$key" "$file" 'Seerr API key' 'Settings > General > API Key'
  break
done

if [[ $MEDIA_SERVICE == jellyfin ]] && exists jellyfin && note_found jellyfin; then
  url[JELLYFIN_URL]=http://jellyfin:8096
  prompt_secret JELLYFIN_API_KEY 'Jellyfin API key' 'Jellyfin > Dashboard > API Keys > + (name it "YAMS Hub")'
elif [[ $MEDIA_SERVICE != jellyfin ]]; then
  info "  $MEDIA_SERVICE: not supported by the hub (Jellyfin only); the media pages stay off"
fi

if exists jellystat && [[ -n ${url[JELLYFIN_URL]} ]] && note_found jellystat; then
  url[JELLYSTAT_URL]=http://jellystat:3000
  prompt_secret JELLYSTAT_API_KEY 'Jellystat API key' 'Jellystat > Settings > API Keys'
fi

qbit_host=qbittorrent
if exists qbittorrent; then
  # With the VPN on, qBittorrent shares gluetun's network namespace and is reached through it.
  mode_net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' qbittorrent)
  if [[ $mode_net == container:* || $mode_net == service:* ]]; then
    qbit_host=$(docker inspect -f '{{.Name}}' "${mode_net#*:}" 2>/dev/null || echo gluetun)
    qbit_host=${qbit_host#/}
  fi
  [[ $qbit_host =~ ^[A-Za-z0-9_.-]+$ ]] || qbit_host=gluetun
fi
if exists qbittorrent && note_found qbittorrent "$qbit_host"; then
  qbit_port=$(container_env qbittorrent WEBUI_PORT)
  [[ $qbit_port =~ ^[0-9]+$ ]] || qbit_port=8081
  url[QBIT_URL]=http://$qbit_host:$qbit_port
  prompt_secret QBIT_USERNAME 'qBittorrent username' 'the qBittorrent Web UI login'
  prompt_secret QBIT_PASSWORD 'qBittorrent password' 'the qBittorrent Web UI password' spaces
fi

if exists gluetun && note_found gluetun; then
  url[GLUETUN_URL]=http://gluetun:8000
fi

# Stock YAMS's watchtower has no HTTP API: it stays off unless a token was added by hand.
if [[ -n ${existing[WATCHTOWER_TOKEN]-} ]]; then
  url[WATCHTOWER_URL]=http://watchtower:8080
  put WATCHTOWER_TOKEN "${existing[WATCHTOWER_TOKEN]}" kept
fi

uptime_slug=$(conf_get UPTIME_KUMA_SLUG)
if exists uptime-kuma && note_found uptime-kuma; then
  if ((prompting)); then
    info '  Uptime Kuma status page slug: the part after /status/ in the page address'
    ask '  Uptime Kuma status page slug (Enter skips)' "$uptime_slug"
    uptime_slug=$REPLY
  fi
  [[ $uptime_slug =~ ^[A-Za-z0-9_-]{1,64}$ ]] || uptime_slug=''
  [[ -n $uptime_slug ]] && url[UPTIME_KUMA_URL]=http://uptime-kuma:3001
fi

if exists audiobookshelf && note_found audiobookshelf; then
  url[ABS_URL]=http://audiobookshelf:80
  prompt_secret ABS_API_KEY 'Audiobookshelf API key' 'Audiobookshelf > Settings > API Keys'
fi
if exists kavita && note_found kavita; then
  url[KAVITA_URL]=http://kavita:5000
  prompt_secret KAVITA_API_KEY 'Kavita Auth Key' 'Kavita > User settings > Auth Keys'
fi
if exists shelfmark && note_found shelfmark; then
  url[SHELFMARK_URL]=http://shelfmark:8084
fi
info "found:         ${found[*]:-nothing}"

# Recyclarr's logs, when YAMS has a recyclarr container.
recyclarr_logs=''
if exists recyclarr; then
  d=$(config_dir recyclarr /config)/logs
  [[ -d $d ]] && safe_path "$d" && recyclarr_logs=$d
fi

# The data volume's disk device for the I/O graph (empty: none).
disk_device=''
dev=$(df -P "$MEDIA" 2>/dev/null | awk 'NR == 2 { print $1 }' || true)
if [[ $dev == /dev/* ]]; then
  dev=$(readlink -f -- "$dev" 2>/dev/null || echo "$dev")
  dev=${dev##*/}
  [[ $dev =~ ^[A-Za-z0-9_.-]+$ ]] && disk_device=$dev
fi
# The server's own name works in the browser too (the gateway allows LAN IPs and *.ts.net by itself).
host_name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
host_name=${host_name,,}
[[ $host_name =~ ^[a-z0-9-]{1,63}$ && $host_name != localhost ]] || host_name=''
tz_offset=$(TZ=$TZ_NAME date +%:z 2>/dev/null || true)
[[ $tz_offset =~ ^[+-][0-9]{2}:[0-9]{2}$ ]] || tz_offset=+00:00

# ---------------------------------------------------------------------------------------------
# Port and admin
# ---------------------------------------------------------------------------------------------
port=$(conf_get PORT)
if [[ -z $port ]]; then
  port=$DEFAULT_PORT
  if ((interactive)); then
    ask 'Port for YAMS Hub' "$DEFAULT_PORT"
    port=$REPLY
  fi
fi
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || die "not a port number: $port"
if command -v ss >/dev/null && [[ ${cstate[yams-hub]-} != running || $port != "$(conf_get PORT)" ]]; then
  if ss -Htln 2>/dev/null | awk -v p="$port" '$4 ~ ("[:.]" p "$") { found = 1 } END { exit !found }'; then
    die "port $port is already in use on this host; re-run and choose another one"
  fi
fi

if [[ -n ${existing[YAMS_HUB_ADMIN_USERNAME]-} ]]; then
  put YAMS_HUB_ADMIN_USERNAME "${existing[YAMS_HUB_ADMIN_USERNAME]}" kept
fi
password=''
if [[ -n ${existing[YAMS_HUB_ADMIN_PASSWORD_HASH]-} ]]; then
  put YAMS_HUB_ADMIN_PASSWORD_HASH "${existing[YAMS_HUB_ADMIN_PASSWORD_HASH]}" kept
elif ((interactive)) && ! read_file "$DATA_DIR/users.json" >/dev/null 2>&1; then
  step 'Admin account'
  ask 'Admin username' admin
  admin=${REPLY,,}
  [[ $admin =~ ^[a-z0-9._-]{2,32}$ ]] || die 'the username may only use a-z, 0-9, . _ - (2 to 32 characters)'
  put YAMS_HUB_ADMIN_USERNAME "$admin" entered
  ask_secret 'Admin password (at least 10 characters)'
  password=$REPLY
  if [[ -t 0 ]]; then
    ask_secret 'Repeat the password'
    [[ $REPLY == "$password" ]] || die 'the passwords do not match'
  fi
  REPLY=''
  ((${#password} >= 10)) || die 'the password must have at least 10 characters'
fi

if [[ -n ${existing[UPDATER_TOKEN]-} ]]; then
  put UPDATER_TOKEN "${existing[UPDATER_TOKEN]}" kept
else
  token=$(head -c 48 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
  ((${#token} == 64)) || die 'could not generate UPDATER_TOKEN'
  put UPDATER_TOKEN "$token" generated
  unset token
fi

# ---------------------------------------------------------------------------------------------
# The compose file
# ---------------------------------------------------------------------------------------------
IFS=, read -r -a cfg_files <<<"$yams_files"
compose_files=()
for f in "${cfg_files[@]}"; do
  [[ -n $f ]] || continue
  safe_path "$f" && [[ $f == "$yams_dir"/* ]] || die "YAMS compose file $f is outside $yams_dir; not supported"
  if [[ -e $f ]]; then compose_files+=("$f"); else warn "$f is in YAMS's labels but does not exist; leaving it out"; fi
done
((${#compose_files[@]})) || compose_files=("$yams_dir/docker-compose.yaml")
compose_list=$(IFS=,; echo "${compose_files[*]}")

service_env=''
for v in "${url_order[@]}"; do service_env+=$'\n'"      - $v=${url[$v]}"; done
[[ -n $uptime_slug ]] && service_env+=$'\n'"      - UPTIME_KUMA_SLUG=$uptime_slug"
[[ -n $host_name ]] && service_env+=$'\n'"      - YAMS_HUB_ALLOWED_HOSTS=$host_name,$host_name.local"
recyclarr_mount=''
if [[ -n $recyclarr_logs ]]; then
  recyclarr_mount=$'\n'"      - $recyclarr_logs:/host/recyclarr-logs:ro"
fi
if [[ -n $hub_ip ]]; then
  net_entry=$'\n'"      yams:"$'\n'"        ipv4_address: $hub_ip"
else
  net_entry=$'\n'"      yams: {}"
fi

tpl=$(<"$ROOT/install/compose.yaml")
tpl=${tpl//$'\n'@@SERVICE_ENV@@/$service_env}
tpl=${tpl//$'\n'@@RECYCLARR_MOUNT@@/$recyclarr_mount}
tpl=${tpl//$'\n'@@YAMS_NETWORK_ENTRY@@/$net_entry}
tpl=${tpl//@@YAMS_NETWORK@@/$yams_net}
tpl=${tpl//@@TZ@@/$TZ_NAME}
tpl=${tpl//@@TZ_OFFSET@@/$tz_offset}
tpl=${tpl//@@MEDIA_DIRECTORY@@/$MEDIA}
tpl=${tpl//@@DISK_DEVICE@@/$disk_device}
tpl=${tpl//@@PORT@@/$port}
tpl=${tpl//@@DATA_DIR@@/$DATA_DIR}
tpl=${tpl//@@HUB_DIR@@/$HUB_DIR}
tpl=${tpl//@@YAMS_PROJECT@@/$yams_project}
tpl=${tpl//@@YAMS_DIR@@/$yams_dir}
tpl=${tpl//@@YAMS_COMPOSE_FILES@@/$compose_list}
[[ $tpl != *@@* ]] || die "install/compose.yaml has a placeholder install.sh does not know: $(grep -o '@@[A-Z_]*@@' <<<"$tpl" | head -n1)"
compose_text="# Rendered by install.sh from install/compose.yaml; re-run install.sh instead of editing it."$'\n'"$tpl"
conf_text="# install.sh settings (not secret)"$'\n'"PORT=$port"$'\n'"HUB_IP=$hub_ip"$'\n'"UPTIME_KUMA_SLUG=$uptime_slug"

if ((dry_run)); then
  step 'Dry run: nothing was changed'
  info "would write:   $COMPOSE, $CONF, $HUB_DIR/socket-proxy-hub.haproxy.cfg"
  info "               $HUB_ENV (uid $HUB_UID, 0400), $UPDATER_ENV (root, 0400)"
  info "               $DATA_DIR (uid $HUB_UID, 0700)"
  info "would build:   $HUB_IMAGE, $UPDATER_IMAGE; pull $PROXY_IMAGE"
  info "would run:     docker compose -p $PROJECT -f $COMPOSE up -d"
  info 'secrets:'
  for k in "${order[@]}"; do
    [[ -n ${out[$k]-} ]] && printf '  %-30s %s\n' "$k" "${source_of[$k]}"
  done
  info ''
  info "--- $COMPOSE ---"
  printf '%s\n' "$compose_text"
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------------------------
step 'Build the images (a few minutes the first time)'
docker build -f "$ROOT/gateway/Dockerfile" -t "$HUB_IMAGE" "$ROOT"
docker build -f "$ROOT/updater/Dockerfile" -t "$UPDATER_IMAGE" "$ROOT/updater"
docker image inspect "$PROXY_IMAGE" >/dev/null 2>&1 || docker pull "$PROXY_IMAGE"

if [[ -n $password ]]; then
  # The password travels through a pipe (printf is a builtin), never through argv.
  hash=$(printf '%s\n' "$password" |
    docker run --rm -i --network none --entrypoint /app/yams-hub "$HUB_IMAGE" hash-password) ||
    die 'hash-password failed'
  password=''
  [[ $hash =~ ^pbkdf2-sha256\$[0-9]+\$[A-Za-z0-9_=+/-]+\$[A-Za-z0-9_=+/-]+$ ]] || die 'unexpected hash-password output'
  put YAMS_HUB_ADMIN_PASSWORD_HASH "$hash" entered
  unset hash
fi

# ---------------------------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------------------------
step "Write $HUB_DIR"
me="$(id -u):$(id -g)"
locked=1
lock_files() {
  helper "$HUB_DIR" "if [ -f /m/secrets/yams-hub.env ]; then chown $HUB_UID:$HUB_UID /m/secrets/yams-hub.env; chmod 0400 /m/secrets/yams-hub.env; fi
    if [ -f /m/secrets/updater.env ]; then chown 0:0 /m/secrets/updater.env; chmod 0400 /m/secrets/updater.env; fi"
  locked=1
}
tmp_files=()
cleanup() {
  local status=$?
  local f
  for f in ${tmp_files[@]+"${tmp_files[@]}"}; do rm -f -- "$f"; done
  if ((!locked)); then lock_files || warn "could not restore the owner/mode of $SECRETS; re-run install.sh"; fi
  exit "$status"
}
trap cleanup EXIT

# The hub dir belongs to this user (so it can write it); the secrets go back to their owners below.
helper "$yams_dir" "mkdir -p /m/yams-hub/secrets
  chown $me /m/yams-hub /m/yams-hub/secrets; chmod 0755 /m/yams-hub; chmod 0700 /m/yams-hub/secrets
  for f in yams-hub.env updater.env; do
    if [ -d /m/yams-hub/secrets/\$f ]; then rmdir /m/yams-hub/secrets/\$f; fi
    if [ -f /m/yams-hub/secrets/\$f ]; then chown $me /m/yams-hub/secrets/\$f; chmod 0600 /m/yams-hub/secrets/\$f; fi
  done"
locked=0

write_file() { # TARGET MODE (content on stdin)
  local tmp
  tmp=$(mktemp "$(dirname -- "$1")/.$(basename -- "$1").XXXXXX")
  tmp_files+=("$tmp")
  cat >"$tmp"
  chmod "$2" "$tmp"
  mv -f -- "$tmp" "$1"
}
write_secrets() { # TARGET KEYS...
  local target=$1 k
  shift
  {
    printf "# Written by install.sh. KEY='value' lines.\n"
    for k in "$@"; do
      if [[ -n ${out[$k]-} ]]; then printf "%s='%s'\n" "$k" "${out[$k]}"; fi
    done
  } | write_file "$target" 0600
}

old_cfg=$(cat -- "$HUB_DIR/socket-proxy-hub.haproxy.cfg" 2>/dev/null || true)
write_file "$HUB_DIR/socket-proxy-hub.haproxy.cfg" 0644 <"$ROOT/deploy/socket-proxy-hub/haproxy.cfg"
cfg_changed=0
[[ $old_cfg == "$(cat -- "$ROOT/deploy/socket-proxy-hub/haproxy.cfg")" ]] || cfg_changed=1
printf '%s\n' "$compose_text" | write_file "$COMPOSE" 0644
printf '%s\n' "$conf_text" | write_file "$CONF" 0644
write_secrets "$HUB_ENV" "${order[@]}"
write_secrets "$UPDATER_ENV" UPDATER_TOKEN
lock_files
helper "$MEDIA/config" "mkdir -p /m/yams-hub && chown $HUB_UID:$HUB_UID /m/yams-hub && chmod 0700 /m/yams-hub"

info "compose file:  $COMPOSE"
info "secrets:       $HUB_ENV (uid $HUB_UID, 0400), $UPDATER_ENV (root, 0400)"
info "data:          $DATA_DIR (uid $HUB_UID, 0700)"
for k in "${order[@]}"; do
  [[ -n ${out[$k]-} ]] && printf '  %-30s %s\n' "$k" "${source_of[$k]}"
done
compose_hub config -q || die "docker compose rejected $COMPOSE"

# ---------------------------------------------------------------------------------------------
# Start, proving no other container changed
# ---------------------------------------------------------------------------------------------
step "docker compose -p $PROJECT up -d"
snapshot() { docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'; }
before=$(snapshot) || die 'docker ps failed'
up_failed=0
compose_hub up -d || up_failed=1
if ((!up_failed && cfg_changed)) && [[ -n ${cstate[socket-proxy-hub]-} ]]; then
  # A new template only takes effect when the proxy's entrypoint renders it again.
  compose_hub up -d --no-deps --force-recreate socket-proxy-hub || up_failed=1
fi
after=$(snapshot) || die 'docker ps failed'

declare -A id_before=() id_after=()
while read -r id name; do [[ -n ${name:-} ]] && id_before[$name]=$id; done <<<"$before"
while read -r id name; do [[ -n ${name:-} ]] && id_after[$name]=$id; done <<<"$after"
changed=()
for name in "${!id_before[@]}" "${!id_after[@]}"; do
  case " ${HUB_CONTAINERS[*]} " in *" $name "*) continue ;; esac
  if [[ ${id_before[$name]-} != "${id_after[$name]-}" ]]; then
    case " ${changed[*]-} " in *" $name "*) ;; *) changed+=("$name") ;; esac
  fi
done
if ((${#changed[@]})); then
  printf '\n%s!!! containers outside the hub changed: %s%s\n' "$red" "${changed[*]}" "$reset" >&2
  die 'other containers were recreated, created or removed; check them now (docker ps -a)'
fi
((!up_failed)) || die "docker compose up failed (see above); logs: docker logs yams-hub"
info "no container outside the hub changed (${#id_before[@]} before, ${#id_after[@]} after)"

step 'Wait for health'
health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo missing; }
for c in "${HUB_CONTAINERS[@]}"; do
  for _ in $(seq 1 60); do
    s=$(health "$c")
    [[ $s == healthy || ($c == socket-proxy-hub && $s == running) ]] && break
    sleep 2
  done
  s=$(health "$c")
  if [[ $s == healthy || ($c == socket-proxy-hub && $s == running) ]]; then
    info "$c: $s"
  else
    docker logs --tail 20 "$c" >&2 || true
    die "$c is $s after 120 s (logs above: docker logs $c)"
  fi
done
ping_url=http://127.0.0.1:$port/api/v1/ping
if command -v curl >/dev/null; then
  curl -fsS -m 5 -o /dev/null "$ping_url" || die "the hub is healthy but $ping_url does not answer"
  info "ping:          $ping_url OK"
elif command -v wget >/dev/null; then
  wget -q -T 5 -O /dev/null "$ping_url" || die "the hub is healthy but $ping_url does not answer"
  info "ping:          $ping_url OK"
fi

# ---------------------------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------------------------
lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -n1 || true)
[[ -n $lan_ip ]] || lan_ip=$(hostname -I 2>/dev/null | awk '{ print $1 }' || true)
hub_url=http://${lan_ip:-<server-ip>}:$port
printf '\n%sYAMS Hub is running: %s%s\n' "$green" "$hub_url" "$reset"
if ((first_run)); then
  info "  1. Open $hub_url and sign in as ${out[YAMS_HUB_ADMIN_USERNAME]:-admin}."
  info '  2. Phone: Android app (./build.sh --apk) or, on an iPhone, open the address in Safari > Share > Add to Home Screen.'
  info '  3. Missing a service? ./install.sh --reconfigure asks for its key again.'
fi
info "  Logs: docker logs yams-hub (also yams-hub-updater, socket-proxy-hub)"
info '  Update: git pull && ./build.sh && ./install.sh --update'
