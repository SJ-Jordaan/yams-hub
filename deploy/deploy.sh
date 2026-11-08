#!/usr/bin/env bash
# Builds YAMS Hub and deploys it to the NAS "Zenith" without touching any other container
# (ARCHITECTURE §9). Run it on the dev machine from anywhere inside the repo.
#
# There is no docker on the dev machine, so the images are built ON THE NAS:
#   0. local preflight: the working tree must be clean (deploy ships HEAD; see --allow-dirty)
#   1. remote preflight: compose files merged (deploy/README.md) with the fixed control network
#              (each service checked on its own: yams_hub_ctl 172.30.250.0/29, static addresses,
#              haproxy template mount + DISABLE_IPV6, updater source allow-list), 172.28.0.49 free,
#              no other Docker network and no host route overlapping 172.30.250.0/29, secrets
#              present, and the existing yams_yams_hub_ctl network (if any) has that subnet and
#              gateway (otherwise: --migrate-ctl-network, see below);
#              plan: the updater is only rebuilt and recreated when updater/ at HEAD differs from
#              the tree its running image was built from (label yams-hub.updater-tree), or with
#              --pull or --only yams-hub-updater
#   2. local:  flutter build web --release --no-web-resources-cdn, delete *.symbols
#   3. ship:   git archive HEAD (packages/yams_models, gateway, updater, deploy, .dockerignore)
#              + app/build/web, as one tar stream over ssh into a mktemp dir on the NAS
#   4. NAS:    docker build only the images of the services being deployed (tagged :latest; the
#              image the running container uses is kept as :previous, the rollback image);
#              install deploy/socket-proxy-hub/haproxy.cfg as
#              /opt/yams/monitoring/yams-hub/socket-proxy-hub.haproxy.cfg (atomic, only when it changed);
#              when the running socket-proxy-hub serves anything but HEAD's template (compared with its
#              rendered /run/haproxy/haproxy.cfg, so an interrupted earlier deploy is caught too), it is
#              force-recreated so its entrypoint renders the template again
#   5. NAS:    wait until the updater has no job running (when it is recreated), then
#              [--migrate-ctl-network: stop + rm yams-hub, yams-hub-updater, socket-proxy-hub and
#              docker network rm yams_yams_hub_ctl, nothing else] and
#              docker compose -p yams ... up -d --no-deps <services>
#              with a `docker ps -a` id snapshot before and after: any other container whose id
#              changed (or that appeared/disappeared) fails the deploy loudly
#   6. NAS:    wait until the deployed services are healthy, ping the hub; when socket-proxy-hub was
#              deployed, prove its source ACL is in effect (rendered config = HEAD's template, and the
#              host gets no HTTP answer from 172.30.250.3:2375), otherwise stop it and fail
#
# Usage: deploy/deploy.sh [options]
#   --dry-run       print every command (local and remote) without running anything
#   --first-run     also run make_hub_env.sh (secrets files, data dir, admin password prompt)
#                   before `up`, and verify.sh after it (both interactive over ssh -t)
#   --skip-web      reuse the existing app/build/web
#   --pull          docker build --pull (refresh the dart / distroless base images)
#   --only SERVICE  build and restart only this hub service (repeatable): yams-hub,
#                   socket-proxy-hub, yams-hub-updater (always rebuilt when named). Default:
#                   yams-hub and socket-proxy-hub, plus yams-hub-updater if updater/ changed
#   --allow-dirty   deploy HEAD even though the working tree has uncommitted or untracked changes
#                   (they are NOT deployed; the web app is built from the working tree)
#   --migrate-ctl-network
#                   one-time move to the fixed 172.30.250.0/29 control network: when
#                   yams_yams_hub_ctl exists with another subnet (compose cannot change it), stop and
#                   remove the three hub containers and that network, then recreate all three
#                   (about a minute of hub downtime; no other container is touched). Without the flag
#                   deploy.sh stops in the preflight and prints the commands. No-op once migrated.
#   --host HOST     ssh host (default: nas, or $NAS_HOST)
#   -h, --help      show this help
#
# Environment: NAS_HOST, UPDATER_IDLE_WAIT (seconds to wait for a running updater job, 900),
#   CFG_HELPER_IMAGE (image for writing the haproxy template when its directory is not writable over
#   ssh; default: the digest-pinned socket-proxy image from the merged compose file).
# Control plane addresses: HUB_CTL_* below must match deploy/docker-compose.hub.yaml, verify.sh and
# deploy/socket-proxy-hub/haproxy.cfg (deploy/test/deploy_test.sh checks it).
# Rollback: deploy/README.md ("Rollback").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAS_HOST=${NAS_HOST:-nas}
SSH_OPTS=(-o BatchMode=yes -o WarnWeakCrypto=no)
# The REMOTE_* / SECRETS_DIR / DATA_DIR overrides exist for deploy/test/deploy_test.sh.
REMOTE_YAMS=${REMOTE_YAMS:-/opt/yams}
REMOTE_TMP_BASE=${REMOTE_TMP_BASE:-/tmp}
SECRETS_DIR=${SECRETS_DIR:-/opt/yams/monitoring/secrets}
DATA_DIR=${DATA_DIR:-/volume1/mediashare/config/yams-hub}
HUB_IP=172.28.0.49
# The control network (ARCHITECTURE §6): UGOS's DOCKER-USER ACCEPT defeats `internal: true`, so the
# proxy and the updater only accept connections from the gateway's fixed address on it.
CTL_NET=yams_yams_hub_ctl
HUB_CTL_SUBNET=172.30.250.0/29
HUB_CTL_BRIDGE_IP=172.30.250.1
HUB_CTL_GATEWAY_IP=172.30.250.2
HUB_CTL_PROXY_IP=172.30.250.3
HUB_CTL_UPDATER_IP=172.30.250.4
HAPROXY_SRC=deploy/socket-proxy-hub/haproxy.cfg
HAPROXY_CFG=${HAPROXY_CFG:-/opt/yams/monitoring/yams-hub/socket-proxy-hub.haproxy.cfg}
CFG_HELPER_IMAGE=${CFG_HELPER_IMAGE:-}
# deploy/test/deploy_test.sh only: write the template through the helper container even when the
# directory is writable.
CFG_INSTALL_VIA_CONTAINER=${CFG_INSTALL_VIA_CONTAINER:-0}
HUB_SERVICES=(yams-hub socket-proxy-hub yams-hub-updater)
ARCHIVE_PATHS=(.dockerignore packages/yams_models gateway updater deploy)
ENV_SH=${YAMS_ENV_SH:-$HOME/development/env.sh}
UPDATER="yams-hub-updater"
# Label on the updater image: the git tree id of updater/ (its whole build context) it was built from.
TREE_LABEL=yams-hub.updater-tree
UPDATER_IDLE_WAIT=${UPDATER_IDLE_WAIT:-900}

dry_run=0 first_run=0 skip_web=0 pull=0 allow_dirty=0 migrate_ctl=0
only=()

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

while (($#)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --first-run) first_run=1 ;;
    --skip-web) skip_web=1 ;;
    --pull) pull=1 ;;
    --allow-dirty) allow_dirty=1 ;;
    --migrate-ctl-network) migrate_ctl=1 ;;
    --only)
      [[ $# -ge 2 ]] || {
        echo '--only needs a service' >&2
        exit 2
      }
      case " ${only[*]-} " in *" $2 "*) ;; *) only+=("$2") ;; esac
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || {
        echo '--host needs a value' >&2
        exit 2
      }
      NAS_HOST=$2
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1 (see --help)" >&2
      exit 2
      ;;
  esac
  shift
done

services=("${HUB_SERVICES[@]}")
explicit=0
if ((${#only[@]})); then
  explicit=1
  for s in "${only[@]}"; do
    case " ${HUB_SERVICES[*]} " in
      *" $s "*) ;;
      *)
        echo "--only: $s is not one of: ${HUB_SERVICES[*]}" >&2
        exit 2
        ;;
    esac
  done
  services=("${only[@]}")
fi
[[ $NAS_HOST =~ ^[A-Za-z0-9._@-]+$ ]] || {
  echo "invalid --host: $NAS_HOST" >&2
  exit 2
}
if ((first_run && explicit)); then
  echo '--first-run deploys all three hub services; drop --only' >&2
  exit 2
fi
if ((migrate_ctl && explicit)); then
  echo '--migrate-ctl-network recreates all three hub services; drop --only' >&2
  exit 2
fi
[[ $HAPROXY_CFG =~ ^/[A-Za-z0-9._/-]+$ ]] || {
  echo "invalid HAPROXY_CFG: $HAPROXY_CFG" >&2
  exit 2
}
[[ -z $CFG_HELPER_IMAGE || $CFG_HELPER_IMAGE =~ ^[A-Za-z0-9._/:@-]+$ ]] || {
  echo "invalid CFG_HELPER_IMAGE: $CFG_HELPER_IMAGE" >&2
  exit 2
}
[[ $UPDATER_IDLE_WAIT =~ ^[0-9]+$ ]] || {
  echo "invalid UPDATER_IDLE_WAIT: $UPDATER_IDLE_WAIT (seconds)" >&2
  exit 2
}
has_service() { case " ${services[*]-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
drop_service() {
  local s keep=()
  for s in "${services[@]}"; do [[ $s == "$1" ]] || keep+=("$s"); done
  services=(${keep[@]+"${keep[@]}"})
}

if [[ -t 1 ]]; then
  bold=$'\e[1m' red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
else
  bold='' red='' green='' yellow='' reset=''
fi
step() { printf '\n%s==> %s%s\n' "$bold" "$*" "$reset"; }
ok() { printf '%sok%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$yellow" "$reset" "$*" >&2; }
die() {
  printf '\n%sDEPLOY FAILED:%s %s\n' "$red" "$reset" "$*" >&2
  exit 1
}

# --- command helpers ----------------------------------------------------------------------------
show() { printf '%s+%s %s\n' "$yellow" "$reset" "$*"; }

# run CMD...: a local command (printed in dry-run mode).
run() {
  if ((dry_run)); then
    show "$(printf '%q ' "$@")"
    return 0
  fi
  "$@"
}

ssh_nas() { ssh "${SSH_OPTS[@]}" "$NAS_HOST" "$@"; }

# remote SCRIPT: runs a bash script on the NAS (sent on stdin, so the login shell does not
# matter and nothing is interpolated by it). Values are embedded with printf %q.
remote() {
  local script
  # Wrapped in a function so bash reads the whole script before running any of it, and run with
  # stdin from /dev/null so no remote command can swallow the rest of the script.
  script="set -euo pipefail"$'\n'"__deploy_step() {"$'\n'"$1"$'\n'"}"$'\n'"__deploy_step </dev/null"
  if ((dry_run)); then
    show "ssh $NAS_HOST bash -s <<'EOF'"
    printf '%s\n' "$script" | sed 's/^/    /'
    show 'EOF'
    return 0
  fi
  ssh_nas 'bash -s' <<<"$script"
}

# remote_tty CMD: an interactive command on the NAS (prompts need a terminal).
remote_tty() {
  if ((dry_run)); then
    show "ssh -t $NAS_HOST $1"
    return 0
  fi
  ssh -t "${SSH_OPTS[@]}" "$NAS_HOST" "$1"
}

q() { printf '%q' "$1"; }

compose_cmd="docker compose -p yams -f docker-compose.yaml -f docker-compose.custom.yaml"

local_stage=''
remote_dir=''
cleanup() {
  local status=$?
  if [[ -n $local_stage ]]; then rm -rf -- "$local_stage"; fi
  if [[ -n $remote_dir ]] && ((!dry_run)); then
    ssh_nas "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || warn "could not remove $remote_dir on the NAS"
  fi
  exit "$status"
}
trap cleanup EXIT

cd "$ROOT"
if ((dry_run)); then printf '%sDRY RUN: nothing is built, shipped or restarted.%s\n' "$bold" "$reset"; fi

# --- 0. local preflight -------------------------------------------------------------------------
step 'local preflight'
command -v git >/dev/null || die 'git not found'
git rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git repository (git archive needs HEAD)"
sha=$(git rev-parse --short=12 HEAD) || die 'no commit at HEAD'
# The whole tree, untracked files included: the images come from HEAD, the web app from app/ as
# it is on disk, so any difference means the deployed hub is not what $sha says.
dirty=$(git status --porcelain --untracked-files=normal) || die 'git status failed'
if [[ -n $dirty ]]; then
  if ((allow_dirty)); then
    warn "--allow-dirty: these changes are NOT deployed (HEAD $sha is; app/build/web comes from the working tree):"
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
  elif ((dry_run)); then
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
    warn "the working tree is dirty: a real deploy refuses to run until you commit (or stash) these, or pass --allow-dirty"
  else
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
    die "the working tree has uncommitted or untracked changes (above). deploy.sh ships HEAD $sha, so it refuses to run: commit or stash them, or pass --allow-dirty to deploy HEAD anyway"
  fi
fi
updater_tree=$(git rev-parse "HEAD:updater") || die 'updater/ is not committed at HEAD'
[[ $updater_tree =~ ^[0-9a-f]{40,64}$ ]] || die "unexpected tree id for updater/: $updater_tree"
git cat-file -e "HEAD:$HAPROXY_SRC" 2>/dev/null || die "$HAPROXY_SRC is not committed at HEAD"
ok "HEAD $sha (updater/ tree ${updater_tree:0:12})"

# --- 1. remote preflight ------------------------------------------------------------------------
step 'NAS preflight'
remote "
cd $(q "$REMOTE_YAMS")
docker version --format 'docker {{.Server.Version}}' >/dev/null || { echo 'cannot reach the Docker daemon' >&2; exit 1; }
listed=\$($compose_cmd config --services)
for s in ${HUB_SERVICES[*]}; do
  grep -qx -- \"\$s\" <<<\"\$listed\" || { echo \"\$s is not in docker-compose.custom.yaml yet: merge deploy/docker-compose.hub.yaml first (deploy/README.md)\" >&2; exit 1; }
done
net=\$(docker network ls --format '{{.Name}}' | grep -E '(^|_)yams_network\$' | head -n1 || true)
if [[ -n \$net ]]; then
  taken=\$(docker network inspect -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{\"\\n\"}}{{end}}' \"\$net\" | awk -v ip=$(q "$HUB_IP") '\$2 ~ \"^\" ip \"/\" && \$1 != \"yams-hub\" {print \$1}')
  [[ -z \$taken ]] || { echo \"$HUB_IP is already used by \$taken on \$net\" >&2; exit 1; }
fi
if [[ $first_run == 0 ]]; then
  for f in $(q "$SECRETS_DIR/yams-hub.env") $(q "$SECRETS_DIR/yams-hub-updater.env"); do
    [[ -f \$f ]] || { echo \"\$f is missing (or a directory): run deploy.sh --first-run or make_hub_env.sh\" >&2; exit 1; }
  done
  [[ -d $(q "$DATA_DIR") ]] || { echo '$DATA_DIR is missing: run deploy.sh --first-run' >&2; exit 1; }
fi
echo \"compose services merged; $HUB_IP free\"
" || die 'NAS preflight failed (see above)'

# --- 1a. control network: merged layout, address clashes, existing network -----------------------
# Values reach the remote scripts below as %q-quoted assignments; the scripts themselves are quoted
# heredocs, so nothing in them is expanded locally.
ctl_vars=$(printf 'CTL_NET=%q SUBNET=%q BRIDGE_IP=%q GW_IP=%q PROXY_IP=%q UPDATER_IP=%q HUB_IP=%q HAPROXY_CFG=%q COMPOSE=%q REMOTE_YAMS=%q' \
  "$CTL_NET" "$HUB_CTL_SUBNET" "$HUB_CTL_BRIDGE_IP" "$HUB_CTL_GATEWAY_IP" "$HUB_CTL_PROXY_IP" "$HUB_CTL_UPDATER_IP" \
  "$HUB_IP" "$HAPROXY_CFG" "$compose_cmd" "$REMOTE_YAMS")
ctl_preflight=$(
  cat <<'SH'
cd "$REMOTE_YAMS"
rx() { local s=${1//./\\.}; printf '%s' "$s"; }
# 1. The merged custom file has the fixed control network (deploy/docker-compose.hub.yaml), each
#    setting in the service (or network) it belongs to.
# shellcheck disable=SC2086 # COMPOSE is a word list
cfg=$($COMPOSE config yams-hub socket-proxy-hub yams-hub-updater) || { echo 'docker compose config failed' >&2; exit 1; }
# block KEY NAME: the lines of entry NAME under the top-level KEY (services or networks) of $cfg.
block() {
  awk -v top="$1:" -v want="  $2:" '
    /^[^ ]/ { cur = $0; inside = 0; next }
    cur == top && /^  [^ ]/ { inside = ($0 == want); next }
    inside { print }' <<<"$cfg"
}
net_cfg=$(block networks yams_hub_ctl)
hub_cfg=$(block services yams-hub)
proxy_cfg=$(block services socket-proxy-hub)
updater_cfg=$(block services yams-hub-updater)
missing=()
need() { grep -qE -- "^[[:space:]]*(- )?$2[[:space:]]*\$" <<<"$1" || missing+=("$3"); }
need "$net_cfg" "subnet: \"?$(rx "$SUBNET")\"?" "networks.yams_hub_ctl subnet $SUBNET"
need "$hub_cfg" "ipv4_address: \"?$(rx "$GW_IP")\"?" "yams-hub ipv4_address $GW_IP"
need "$hub_cfg" "ipv4_address: \"?$(rx "$HUB_IP")\"?" "yams-hub ipv4_address $HUB_IP"
need "$proxy_cfg" "ipv4_address: \"?$(rx "$PROXY_IP")\"?" "socket-proxy-hub ipv4_address $PROXY_IP"
need "$proxy_cfg" "source: \"?$(rx "$HAPROXY_CFG")\"?" "socket-proxy-hub volume $HAPROXY_CFG"
need "$proxy_cfg" 'target: "?/templates/haproxy\.cfg"?' 'socket-proxy-hub volume target /templates/haproxy.cfg'
need "$proxy_cfg" 'DISABLE_IPV6: "?1"?' 'socket-proxy-hub DISABLE_IPV6=1'
need "$updater_cfg" "ipv4_address: \"?$(rx "$UPDATER_IP")\"?" "yams-hub-updater ipv4_address $UPDATER_IP"
need "$updater_cfg" "UPDATER_ALLOWED_SOURCES: \"?$(rx "$GW_IP")\"?" "yams-hub-updater UPDATER_ALLOWED_SOURCES=$GW_IP"
proxy_image=$(sed -n 's/^    image: "\{0,1\}\([A-Za-z0-9._/:@-]*\)"\{0,1\}[[:space:]]*$/\1/p' <<<"$proxy_cfg" | head -n1)
[[ -n $proxy_image ]] || missing+=('socket-proxy-hub image')
if ((${#missing[@]})); then
  echo 'docker-compose.custom.yaml predates the fixed control network; re-merge deploy/docker-compose.hub.yaml' >&2
  echo '(deploy/README.md, "Upgrade: fixed control network"). Missing:' >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi
# 2. Nothing else on the host uses the control subnet: no other Docker network (compose would fail
#    half way) and no host route of a UGOS bridge or VPN (the hub would shadow it).
ip4() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(((a << 24) | (b << 16) | (c << 8) | d))
}
overlaps() { # NET/PREFIX CANDIDATE -> 0 when they share an address (IPv6 candidates never do)
  local n1=${1%/*} p1=${1#*/} n2=${2%/*} p2=32 m mask
  [[ $2 == */* ]] && p2=${2#*/}
  [[ $n2 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && $p2 =~ ^[0-9]+$ ]] || return 1
  m=$((p1 < p2 ? p1 : p2))
  mask=$((m == 0 ? 0 : (0xffffffff << (32 - m)) & 0xffffffff))
  (($(($(ip4 "$n1") & mask)) == $(($(ip4 "$n2") & mask))))
}
networks=$(docker network ls --format '{{.Name}}')
clash=()
while read -r name; do
  [[ -n $name && $name != "$CTL_NET" ]] || continue
  for sn in $(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$name" 2>/dev/null || true); do
    if overlaps "$SUBNET" "$sn"; then clash+=("$name ($sn)"); fi
  done
done <<<"$networks"
if ((${#clash[@]})); then
  echo "$SUBNET overlaps the Docker network(s): ${clash[*]}; pick another subnet (deploy/docker-compose.hub.yaml header)" >&2
  exit 1
fi
have_ctl=0
if grep -qx -- "$CTL_NET" <<<"$networks"; then have_ctl=1; fi
ctl_dev=''
if ((have_ctl)); then
  ctl_dev=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$CTL_NET" 2>/dev/null || true)
  if [[ -z $ctl_dev || $ctl_dev == '<no value>' ]]; then
    ctl_id=$(docker network inspect -f '{{.Id}}' "$CTL_NET")
    ctl_dev=br-${ctl_id:0:12}
  fi
fi
if command -v ip >/dev/null; then
  rclash=()
  while read -r line; do
    [[ -n $line ]] || continue
    read -r -a f <<<"$line"
    dst=${f[0]}
    case $dst in unicast | blackhole | unreachable | prohibit | throw | local | broadcast | multicast | anycast | nat) dst=${f[1]:-} ;; esac
    [[ -n $dst && $dst != default ]] || continue
    dev=''
    for ((i = 0; i + 1 < ${#f[@]}; i++)); do
      if [[ ${f[i]} == dev ]]; then dev=${f[i + 1]}; fi
    done
    # The control network's own bridge route is expected.
    [[ -n $ctl_dev && $dev == "$ctl_dev" ]] && continue
    if overlaps "$SUBNET" "$dst"; then rclash+=("$line"); fi
  done < <(ip -4 route show 2>/dev/null || true)
  if ((${#rclash[@]})); then
    echo "$SUBNET overlaps host route(s) outside $CTL_NET:" >&2
    printf '  %s\n' "${rclash[@]}" >&2
    echo 'pick another subnet (deploy/docker-compose.hub.yaml header)' >&2
    exit 1
  fi
else
  echo 'note: no `ip` on the NAS, host routes not checked for overlaps'
fi
# 3. The existing control network, if any, must already have the subnet and gateway: compose cannot
#    change them. Running and stopped members both count (a stopped one has no endpoint, so
#    `docker network rm` would not protect it).
attached() {
  {
    docker network inspect -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$CTL_NET"
    docker ps -a --filter "network=$CTL_NET" --format '{{.Names}}'
  } 2>/dev/null | sed '/^$/d' | sort -u
}
state=absent
if ((have_ctl)); then
  subnets=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$CTL_NET")
  subnets=${subnets% }
  gateways=$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' "$CTL_NET")
  gateways=${gateways% }
  if [[ $subnets == "$SUBNET" && (-z $gateways || $gateways == "$BRIDGE_IP") ]]; then
    state=ok
  else
    desc="subnet ${subnets:-none}"
    if [[ $subnets == "$SUBNET" ]]; then desc+=" and gateway $gateways"; fi
    others=$(attached | grep -vxE 'yams-hub|socket-proxy-hub|yams-hub-updater' | tr '\n' ' ' || true)
    if [[ -n $others ]]; then
      echo "$CTL_NET has $desc (expected $SUBNET, gateway $BRIDGE_IP), and containers outside the hub are attached to it (running or stopped): $others" >&2
      echo "deploy.sh never touches them: disconnect them first (docker network disconnect $CTL_NET <name>)" >&2
      exit 1
    fi
    state="migrate $desc"
  fi
fi
echo "compose file has the fixed control network ($SUBNET); no overlapping network or route"
echo "proxy-image: $proxy_image"
echo "ctl-network: $state"
SH
)

# migration_help WHAT: what to do when the existing network has another subnet (or gateway).
migration_help() {
  cat >&2 <<EOF

$CTL_NET exists with $1, but the compose file now pins $HUB_CTL_SUBNET (gateway $HUB_CTL_BRIDGE_IP;
fixed addresses for the source ACLs, ARCHITECTURE §6). Compose cannot change the IPAM of an existing
network, so it has to be removed and recreated once. That stops yams-hub, socket-proxy-hub and yams-hub-updater for
about a minute; no other container is touched. Check that the hub's Updates screen shows no running
job, then either re-run with

  deploy/deploy.sh --migrate-ctl-network

or do it by hand (only these three containers and this network) and deploy normally:

  ssh $NAS_HOST 'docker stop yams-hub yams-hub-updater socket-proxy-hub && docker rm yams-hub yams-hub-updater socket-proxy-hub && docker network rm $CTL_NET'
  deploy/deploy.sh

EOF
}

migrating=0
ctl_out=$(remote "$ctl_vars"$'\n'"$ctl_preflight") || die 'NAS preflight (control network) failed (see above)'
grep -vE '^(ctl-network|proxy-image): ' <<<"$ctl_out" || true
ctl_state=$(sed -n 's/^ctl-network: //p' <<<"$ctl_out" | tail -n1)
proxy_image=$(sed -n 's/^proxy-image: //p' <<<"$ctl_out" | tail -n1)
[[ -z $proxy_image || $proxy_image =~ ^[A-Za-z0-9._/:@-]+$ ]] || die "unexpected socket-proxy-hub image in the compose config: $proxy_image"
helper_image=${CFG_HELPER_IMAGE:-$proxy_image}
case $ctl_state in
  ok) ok "$CTL_NET has $HUB_CTL_SUBNET" ;;
  absent) ok "$CTL_NET does not exist yet (compose creates it with $HUB_CTL_SUBNET)" ;;
  migrate\ *)
    if ((migrate_ctl)); then
      migrating=1
      ok "$CTL_NET has ${ctl_state#migrate }: --migrate-ctl-network removes and recreates it with the three hub containers"
    else
      migration_help "${ctl_state#migrate }"
      die "$CTL_NET has ${ctl_state#migrate } instead of $HUB_CTL_SUBNET (gateway $HUB_CTL_BRIDGE_IP); nothing was changed (see above)"
    fi
    ;;
  *)
    ((dry_run)) || die "unexpected NAS preflight output: ${ctl_state:-nothing}"
    migrating=$migrate_ctl
    ok "dry run: a real run reads $CTL_NET's subnet here (migration shown below only with --migrate-ctl-network)"
    ;;
esac
if ((migrate_ctl && !migrating && !dry_run)); then ok '--migrate-ctl-network: nothing to migrate'; fi

# --- 1b. plan: which images to build and which services to recreate ---------------------------------
# Every build carries the commit as a label, so its image id changes with every commit and compose
# would recreate the updater on every deploy, even when updater/ did not change. Recreating it is
# not free (it may be in the middle of a job), so it is only rebuilt when its source changed.
step 'plan'
build_hub=0 build_updater=0
if has_service yams-hub; then build_hub=1; fi
if has_service "$UPDATER"; then
  if ((explicit)); then
    build_updater=1
    ok "$UPDATER: rebuilt and recreated (--only)"
  elif ((pull)); then
    build_updater=1
    ok "$UPDATER: rebuilt (--pull refreshes its base images)"
  else
    running_tree_cmd="
id=\$(docker inspect -f '{{.Image}}' $UPDATER 2>/dev/null || true)
if [[ -n \$id ]]; then
  docker image inspect -f '{{index .Config.Labels \"$TREE_LABEL\"}}' \"\$id\" 2>/dev/null || true
fi"
    if ((dry_run)); then
      remote "$running_tree_cmd"
      build_updater=1
      ok "$UPDATER: dry run, so assuming updater/ changed (a real run compares with the running image's $TREE_LABEL)"
    else
      running_tree=$(remote "$running_tree_cmd") || die "could not inspect $UPDATER on the NAS"
      running_tree=${running_tree//[$'\r\n ']/}
      # No container, or an image built before the label existed ("<no value>"): rebuild.
      [[ $running_tree =~ ^[0-9a-f]{40,64}$ ]] || running_tree=''
      if [[ $running_tree == "$updater_tree" ]]; then
        drop_service "$UPDATER"
        if ((migrating)); then
          ok "$UPDATER: updater/ unchanged since its running image (${updater_tree:0:12}); not rebuilt"
        else
          ok "$UPDATER: updater/ unchanged since its running image (${updater_tree:0:12}); left running"
        fi
      else
        build_updater=1
        from=${running_tree:-unknown}
        ok "$UPDATER: updater/ changed (${from:0:12} -> ${updater_tree:0:12}); rebuilt and recreated"
      fi
    fi
  fi
fi
if ((migrating)) && ! has_service "$UPDATER"; then
  # The migration removes all three containers, so the updater is recreated even when its image is
  # unchanged (from the :latest it runs now; nothing is rebuilt or retagged).
  services+=("$UPDATER")
  ok "$UPDATER: recreated on the new control network with its current image (--migrate-ctl-network)"
fi
((${#services[@]})) || die 'nothing to deploy'
ok "deploying $sha to $NAS_HOST: ${services[*]}"

# --- 2. web build ---------------------------------------------------------------------------------
if ((!build_hub)); then
  step 'web build (skipped: yams-hub is not rebuilt)'
elif ((skip_web)); then
  step 'web build (skipped, --skip-web)'
  ((dry_run)) || [[ -f app/build/web/index.html ]] || die 'app/build/web/index.html is missing; drop --skip-web'
else
  step 'flutter build web'
  if ((!dry_run)); then
    [[ -f $ENV_SH ]] || die "$ENV_SH not found"
    # The env file is not written for `set -eu`.
    set +eu
    # shellcheck disable=SC1090
    source "$ENV_SH"
    set -eu
    command -v flutter >/dev/null || die 'flutter not found after sourcing the env file'
  else
    show "source $ENV_SH"
  fi
  run bash -c 'cd app && flutter build web --release --no-web-resources-cdn'
fi
if ((build_hub)); then run find app/build/web -name '*.symbols' -delete; fi

# --- 3. ship the build context --------------------------------------------------------------------
step 'ship build context'
if ((dry_run)); then
  show "git archive --format=tar HEAD -- ${ARCHIVE_PATHS[*]} | tar -x -C <stage>; cp -a app/build/web <stage>/app/build/"
  show "ssh $NAS_HOST mktemp -d $REMOTE_TMP_BASE/yams-hub-deploy.XXXXXX"
  show "tar -C <stage> -czf - . | ssh $NAS_HOST \"tar -xzf - -C <remote dir>\""
  remote_dir="$REMOTE_TMP_BASE/yams-hub-deploy.XXXXXX"
else
  for p in "${ARCHIVE_PATHS[@]}"; do
    git cat-file -e "HEAD:$p" 2>/dev/null || die "$p is not committed at HEAD (deploy ships HEAD)"
  done
  local_stage=$(mktemp -d "${TMPDIR:-/tmp}/yams-hub-stage.XXXXXX")
  git archive --format=tar HEAD -- "${ARCHIVE_PATHS[@]}" | tar -x -C "$local_stage" ||
    die 'git archive failed'
  if ((build_hub)); then
    mkdir -p "$local_stage/app/build"
    cp -a app/build/web "$local_stage/app/build/web"
  fi
  find "$local_stage" -name '*.symbols' -delete
  find "$local_stage" -name '.dart_tool' -prune -exec rm -rf {} +
  printf '%s\n' "$sha" >"$local_stage/REVISION"
  remote_dir=$(ssh_nas "mktemp -d '$REMOTE_TMP_BASE/yams-hub-deploy.XXXXXX'") || die 'mktemp on the NAS failed'
  [[ $remote_dir =~ ^/[A-Za-z0-9._/-]+$ ]] || {
    remote_dir=''
    die 'unexpected mktemp output on the NAS'
  }
  size=$(du -sh "$local_stage" | cut -f1)
  tar -C "$local_stage" -czf - . | ssh_nas "tar -xzf - -C '$remote_dir'" || die 'copying the build context failed'
  ok "shipped $size to $NAS_HOST:$remote_dir"
fi

# --- 4. build the images on the NAS ---------------------------------------------------------------
# Only the images of the services being deployed: a rebuilt but never started image must not
# become :latest (a later `compose up` would silently switch to it) nor push the image that
# actually ran out of :previous.
images=()
if ((build_hub)); then images+=(yams-hub); fi
if ((build_updater)); then images+=("$UPDATER"); fi
if ((${#images[@]})); then
  step "docker build on the NAS: ${images[*]}"
  pull_flag=''
  if ((pull)); then pull_flag='--pull'; fi
  build_cmds=''
  if ((build_hub)); then
    build_cmds+="docker build $pull_flag --label \"\$label\" -f gateway/Dockerfile -t yams-hub:$(q "$sha") ."$'\n'
  fi
  if ((build_updater)); then
    build_cmds+="docker build $pull_flag --label \"\$label\" --label $(q "$TREE_LABEL=$updater_tree") -f updater/Dockerfile -t $UPDATER:$(q "$sha") updater"$'\n'
  fi
  remote "
cd $(q "$remote_dir")
label=org.opencontainers.image.revision=$(q "$sha")
$build_cmds
for img in ${images[*]}; do
  new=\$(docker image inspect -f '{{.Id}}' \"\$img:$(q "$sha")\")
  cur=\$(docker image inspect -f '{{.Id}}' \"\$img:latest\" 2>/dev/null || true)
  old_prev=\$(docker image inspect -f '{{.Id}}' \"\$img:previous\" 2>/dev/null || true)
  # The rollback image is the one the container runs now (the container is named like its image),
  # not :latest, which a failed deploy may have left pointing at a build that never ran.
  ran=\$(docker inspect -f '{{.Image}}' \"\$img\" 2>/dev/null || true)
  prev=\${ran:-\$cur}
  if [[ -n \$prev && \$prev != \"\$new\" ]]; then
    docker image tag \"\$prev\" \"\$img:previous\"
  fi
  docker image tag \"\$img:$(q "$sha")\" \"\$img:latest\"
  docker image rm \"\$img:$(q "$sha")\" >/dev/null
  # Images that lost their tag are no longer needed (ignored while a container uses one).
  for old in \"\$old_prev\" \"\$cur\"; do
    if [[ -n \$old && \$old != \"\$prev\" && \$old != \"\$new\" ]]; then
      docker image rm \"\$old\" >/dev/null 2>&1 || true
    fi
  done
  echo \"\$img:latest = \${new:7:12} (previous: \${prev:7:12})\"
done
" || die 'docker build on the NAS failed'
else
  step 'docker build (nothing to build)'
fi

# --- 4b. the socket proxy's haproxy template ------------------------------------------------------
# deploy/socket-proxy-hub/haproxy.cfg (upstream template + source ACL) is bind-mounted over the image's
# /templates/haproxy.cfg. It is rewritten only when its content changed, atomically (temp file in the
# same directory, then rename), mode 0644 (no secret in it). A single-file bind mount keeps showing
# the old inode after a rename, and the entrypoint renders the template only at start, so whether the
# proxy must be recreated is decided by what it actually serves: its /run/haproxy/haproxy.cfg against
# HEAD's template rendered the same way. That also catches a file installed by an earlier deploy that
# stopped before recreating the proxy (the file then looks unchanged).
cfg_vars=$(printf 'SRC=%q DST=%q HELPER=%q VIA_CT=%q INSTALL=%q' "$remote_dir/$HAPROXY_SRC" "$HAPROXY_CFG" \
  "${helper_image:-<socket-proxy image>}" "$CFG_INSTALL_VIA_CONTAINER" \
  "$(has_service socket-proxy-hub && echo 1 || echo 0)")
cfg_script=$(
  cat <<'SH'
[[ -s $SRC ]] || { echo "$SRC is missing from the build context" >&2; exit 1; }
# What the running proxy serves (the entrypoint renders the template with DISABLE_IPV6=1 as :2375).
want=$(sed 's/@@BIND_PROTO@@/:2375/g' "$SRC")
if [[ $(docker inspect -f '{{.State.Running}}' socket-proxy-hub 2>/dev/null || true) == true ]]; then
  have=$(docker exec socket-proxy-hub cat /run/haproxy/haproxy.cfg 2>/dev/null || true)
  if [[ $have == "$want" ]]; then echo 'haproxy-running: current'; else echo 'haproxy-running: stale'; fi
else
  echo 'haproxy-running: stopped'
fi
if [[ -f $DST ]] && cmp -s -- "$SRC" "$DST"; then
  echo "haproxy-cfg: unchanged"
  exit 0
fi
if [[ $INSTALL != 1 ]]; then
  echo "haproxy-cfg: differs"
  exit 0
fi
dir=${DST%/*} name=${DST##*/}
if [[ $VIA_CT != 1 ]] && mkdir -p -m 0755 -- "$dir" 2>/dev/null && [[ -w $dir ]]; then
  tmp=$(mktemp "$dir/.$name.XXXXXX")
  if ! { cat -- "$SRC" >"$tmp" && chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$DST"; }; then
    rm -f -- "$tmp"
    echo "could not write $DST" >&2
    exit 1
  fi
else
  # Not writable by this user (no sudo on Zenith): through a throwaway root container of the
  # digest-pinned socket-proxy image (Alpine, so it has sh), with no network. The file is then
  # root-owned, 0644, in a 0755 directory.
  docker run --rm -i --network none --user 0:0 --entrypoint sh -v "${dir%/*}:/m" "$HELPER" -euc '
    d="/m/$1"; mkdir -p "$d"; chmod 0755 "$d"
    t=$(mktemp "$d/.$2.XXXXXX"); cat >"$t"; chmod 0644 "$t"; mv -f "$t" "$d/$2"' \
    sh "${dir##*/}" "$name" <"$SRC"
fi
cmp -s -- "$SRC" "$DST" || { echo "$DST does not match $SRC after the install" >&2; exit 1; }
echo "haproxy-cfg: installed"
SH
)
if has_service socket-proxy-hub; then
  step "install the socket-proxy-hub haproxy template"
else
  step "check the socket-proxy-hub haproxy template"
fi
cfg_out=$(remote "$cfg_vars"$'\n'"$cfg_script") || die "installing $HAPROXY_CFG failed (see above)"
proxy_render=$(sed -n 's/^haproxy-running: //p' <<<"$cfg_out" | tail -n1)
case $(sed -n 's/^haproxy-cfg: //p' <<<"$cfg_out" | tail -n1) in
  unchanged) ok "$HAPROXY_CFG is up to date" ;;
  installed) ok "$HAPROXY_CFG installed" ;;
  differs) warn "$HAPROXY_CFG differs from HEAD (or is missing), and socket-proxy-hub is not part of this deploy: run deploy/deploy.sh --skip-web --only socket-proxy-hub" ;;
  *)
    ((dry_run)) || die "unexpected output while installing $HAPROXY_CFG"
    printf '%s\n' "$cfg_out"
    ;;
esac
# A proxy that is stopped or missing renders the template when compose starts or creates it.
force_proxy=0
if has_service socket-proxy-hub && ((!migrating)); then
  if ((dry_run)) || [[ $proxy_render == stale ]]; then force_proxy=1; fi
fi
case $proxy_render in
  stale)
    if ((force_proxy)); then
      ok 'socket-proxy-hub serves an older rendering of the template; it will be recreated to render it'
    elif ((!migrating)); then
      warn "socket-proxy-hub serves something other than HEAD's template, and it is not part of this deploy: run deploy/deploy.sh --skip-web --only socket-proxy-hub"
    fi
    ;;
  current) ok 'socket-proxy-hub already serves this template' ;;
esac

# --- first run: secrets files and data dir --------------------------------------------------------
if ((first_run)); then
  step 'first run: make_hub_env.sh (on the NAS)'
  remote_tty "bash '$remote_dir/deploy/make_hub_env.sh'" || die 'make_hub_env.sh failed'
fi

# --- 5. up -d --no-deps with an id snapshot -------------------------------------------------------
snapshot() { remote "docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'"; }

step 'restart the hub services'
if has_service "$UPDATER"; then
  # Recreating the updater stops it. It drains its job on SIGTERM (stop_grace_period), but do not
  # rely on that alone: wait while it runs a docker command (a job step) before touching it.
  remote "
busy() { docker top $UPDATER 2>/dev/null | awk 'NR > 1 && /docker/ { found = 1 } END { exit !found }'; }
waited=0
while busy; do
  if ((waited == 0)); then echo '$UPDATER is running a job; waiting for it to finish before recreating it'; fi
  if ((waited >= $UPDATER_IDLE_WAIT)); then
    echo \"$UPDATER is still running a job after \$waited s: deploy again once it has finished (Updates screen)\" >&2
    exit 1
  fi
  sleep 5
  waited=\$((waited + 5))
done
echo '$UPDATER: no job running'
" || die "$UPDATER is busy; nothing was restarted"
fi
# The one-time control network migration (--migrate-ctl-network): only the three hub containers (by
# exact name) and the network itself are removed; `docker stop` honours the updater's 17 min
# stop_grace_period, and `docker network rm` refuses while anything else is still attached.
migrate_script="CTL_NET=$(q "$CTL_NET")"$'\n'"$(
  cat <<'SH'
attached() {
  {
    docker network inspect -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$CTL_NET"
    docker ps -a --filter "network=$CTL_NET" --format '{{.Names}}'
  } 2>/dev/null | sed '/^$/d' | sort -u
}
# Re-checked here (the preflight ran minutes ago): anything but the trio, running or stopped, stops it.
others=$(attached | grep -vxE 'yams-hub|socket-proxy-hub|yams-hub-updater' | tr '\n' ' ' || true)
[[ -z $others ]] || { echo "$CTL_NET has containers outside the hub attached: $others; nothing removed" >&2; exit 1; }
for c in yams-hub yams-hub-updater socket-proxy-hub; do
  if docker inspect -f '{{.Id}}' "$c" >/dev/null 2>&1; then
    docker stop "$c" >/dev/null
    docker rm "$c" >/dev/null
    echo "removed container $c"
  fi
done
others=$(attached | tr '\n' ' ')
[[ -z $others ]] || { echo "$CTL_NET still has $others attached; not removing it" >&2; exit 1; }
docker network rm "$CTL_NET" >/dev/null
echo "removed network $CTL_NET"
SH
)"
# A stale template rendering: recreate the proxy first (the gateway self-tests it at start-up).
proxy_cmd="cd $(q "$REMOTE_YAMS") && $compose_cmd up -d --force-recreate --no-deps socket-proxy-hub"
up_cmd="cd $(q "$REMOTE_YAMS") && $compose_cmd up -d --no-deps ${services[*]}"
if ((dry_run)); then
  snapshot
  if ((migrating)); then remote "$migrate_script"; fi
  if ((force_proxy)); then remote "$proxy_cmd"; fi
  remote "$up_cmd"
  snapshot
else
  before=$(snapshot) || die 'docker ps snapshot failed'
  if ((migrating)); then
    step "migrate $CTL_NET to $HUB_CTL_SUBNET"
    remote "$migrate_script" || migrate_failed=1
  fi
  if [[ -z ${migrate_failed:-} ]]; then
    if ((force_proxy)); then remote "$proxy_cmd" || up_failed=1; fi
    if [[ -z ${up_failed:-} ]]; then remote "$up_cmd" || up_failed=1; fi
  fi
  after=$(snapshot) || die 'docker ps snapshot after up failed'

  declare -A id_before=() id_after=()
  while read -r id name; do
    if [[ -n ${name:-} ]]; then id_before[$name]=$id; fi
  done <<<"$before"
  while read -r id name; do
    if [[ -n ${name:-} ]]; then id_after[$name]=$id; fi
  done <<<"$after"
  changed=()
  for name in "${!id_before[@]}" "${!id_after[@]}"; do
    case " ${HUB_SERVICES[*]} " in *" $name "*) continue ;; esac
    if [[ ${id_before[$name]-} != "${id_after[$name]-}" ]]; then
      case " ${changed[*]-} " in *" $name "*) ;; *) changed+=("$name") ;; esac
    fi
  done
  if ((${#changed[@]})); then
    printf '\n%s!!! containers outside the hub changed id: %s%s\n' "$red" "${changed[*]}" "$reset" >&2
    for name in "${changed[@]}"; do
      printf '    %-24s %s -> %s\n' "$name" "${id_before[$name]:-(none)}" "${id_after[$name]:-(none)}" >&2
    done
    die 'other containers were recreated, created or removed; inspect them now (docker ps -a on the NAS)'
  fi
  ok "no container outside ${HUB_SERVICES[*]} changed (${#id_before[@]} before, ${#id_after[@]} after)"
  [[ -z ${migrate_failed:-} ]] || die "the $CTL_NET migration failed (see above); finish it by hand (deploy/README.md, \"Upgrade: fixed control network\"), then run deploy.sh again"
  [[ -z ${up_failed:-} ]] || die 'docker compose up failed (see above); rollback: deploy/README.md'
fi

# --- 6. health ------------------------------------------------------------------------------------
step 'wait for health'
remote "
state() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \"\$1\" 2>/dev/null || echo missing; }
for c in ${services[*]}; do
  for _ in \$(seq 1 60); do
    s=\$(state \"\$c\")
    case \"\$s\" in healthy) break ;; running) [[ \$c == socket-proxy-hub ]] && break ;; esac
    sleep 2
  done
  s=\$(state \"\$c\")
  case \"\$s\" in
    healthy) echo \"\$c: healthy\" ;;
    running) [[ \$c == socket-proxy-hub ]] && echo \"\$c: running\" || { echo \"\$c: still \$s after 120 s\" >&2; exit 1; } ;;
    *) echo \"\$c: \$s\" >&2; docker logs --tail 20 \"\$c\" >&2 || true; exit 1 ;;
  esac
done
if command -v curl >/dev/null; then
  if curl -fsS -m 5 http://127.0.0.1:8090/api/v1/ping >/dev/null; then
    echo 'ping: http://127.0.0.1:8090/api/v1/ping OK'
  else
    echo 'yams-hub is healthy but http://127.0.0.1:8090/api/v1/ping does not answer (port mapping?)' >&2
    exit 1
  fi
fi
" || die 'the hub did not become healthy; rollback: deploy/README.md'

# The proxy's source ACL must actually be in effect (ARCHITECTURE §6). When socket-proxy-hub was
# deployed, an exposed proxy (no ACL in what it serves, or the host gets an HTTP answer) is stopped:
# the hub then shows docker as down, which is better than every container being able to restart any
# other. Not deployed: only a warning.
acl_vars=$(printf 'SRC=%q GW_IP=%q PROXY_IP=%q ENFORCE=%q' "$remote_dir/$HAPROXY_SRC" "$HUB_CTL_GATEWAY_IP" \
  "$HUB_CTL_PROXY_IP" "$(has_service socket-proxy-hub && echo 1 || echo 0)")
acl_script=$(
  cat <<'SH'
rx() { local s=${1//./\\.}; printf '%s' "$s"; }
want=$(sed 's/@@BIND_PROTO@@/:2375/g' "$SRC")
have=$(docker exec socket-proxy-hub cat /run/haproxy/haproxy.cfg 2>/dev/null || true)
problems=()
# haproxy ORs every line of an acl, so exactly one `acl from_hub`, with exactly these sources.
n=$(grep -cE '^[[:space:]]*acl[[:space:]]+from_hub([[:space:]]|$)' <<<"$have" || true)
if [[ $n != 1 ]] || ! grep -qE "^[[:space:]]*acl from_hub src $(rx "$GW_IP")( 127\.0\.0\.1)?([[:space:]]+#.*)?\$" <<<"$have"; then
  problems+=("/run/haproxy/haproxy.cfg has no single 'acl from_hub src $GW_IP [127.0.0.1]' ($n acl from_hub lines)")
fi
if ! grep -qE '^[[:space:]]*tcp-request connection reject if !from_hub([[:space:]]+#.*)?$' <<<"$have"; then
  problems+=("/run/haproxy/haproxy.cfg has no 'tcp-request connection reject if !from_hub'")
fi
if command -v curl >/dev/null; then
  code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://$PROXY_IP:2375/_ping" 2>/dev/null) || true
  [[ ${code:-000} == 000 ]] || problems+=("the host got HTTP $code from http://$PROXY_IP:2375/_ping")
else
  echo 'note: no curl on the NAS, the proxy was not probed from the host'
fi
if ((${#problems[@]})); then
  echo 'socket-proxy-hub is NOT protected by its source ACL:' >&2
  printf '  %s\n' "${problems[@]}" >&2
  if [[ $ENFORCE == 1 ]]; then
    docker stop socket-proxy-hub >/dev/null && echo 'stopped socket-proxy-hub' >&2
  fi
  exit 1
fi
if [[ $have != "$want" ]]; then
  echo "socket-proxy-hub serves an ACL, but not exactly HEAD's template rendered with bind :2375 (DISABLE_IPV6 ignored by a new image?)" >&2
  exit 2
fi
echo "socket-proxy-hub: source ACL in effect (the host got no HTTP answer from $PROXY_IP:2375)"
SH
)
if has_service socket-proxy-hub; then
  step 'socket-proxy-hub source ACL'
  remote "$acl_vars"$'\n'"$acl_script" ||
    die 'socket-proxy-hub is not running HEAD'"'"'s source ACL (see above); rollback: deploy/README.md'
else
  step 'socket-proxy-hub source ACL (check only)'
  remote "$acl_vars"$'\n'"$acl_script" ||
    warn 'socket-proxy-hub is not running HEAD'"'"'s source ACL (see above): deploy/deploy.sh --skip-web --only socket-proxy-hub'
fi

# --- first run: verification ----------------------------------------------------------------------
if ((first_run)); then
  step 'first run: verify.sh (on the NAS)'
  remote_tty "bash '$remote_dir/deploy/verify.sh'" || die 'verify.sh reported failures (see above)'
  printf '\nNext: log in, then drop the bootstrap hash:\n'
  printf "  ssh nas 'cat > /tmp/make_hub_env.sh' < deploy/make_hub_env.sh\n"
  printf "  ssh -t nas 'bash /tmp/make_hub_env.sh --drop-bootstrap; rm -f /tmp/make_hub_env.sh'\n"
fi

step 'done'
if ((dry_run)); then
  ok 'dry run complete'
else
  ok "YAMS Hub $sha is live on http://192.168.10.183:8090"
fi
