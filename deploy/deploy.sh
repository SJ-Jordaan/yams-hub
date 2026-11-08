#!/usr/bin/env bash
# Builds YAMS Hub and deploys it to the NAS "Zenith" without touching any other container
# (ARCHITECTURE §9). Run it on the dev machine from anywhere inside the repo.
#
# There is no docker on the dev machine, so the images are built ON THE NAS:
#   1. remote preflight: compose files merged (deploy/README.md), 172.28.0.49 free, secrets present
#   2. local:  flutter build web --release --no-web-resources-cdn, delete *.symbols
#   3. ship:   git archive HEAD (packages/yams_models, gateway, updater, deploy, .dockerignore)
#              + app/build/web, as one tar stream over ssh into a mktemp dir on the NAS
#   4. NAS:    docker build both images (tagged :latest, the old :latest kept as :previous)
#   5. NAS:    docker compose -p yams ... up -d --no-deps yams-hub socket-proxy-hub yams-hub-updater
#              with a `docker ps -a` id snapshot before and after: any other container whose id
#              changed (or that appeared/disappeared) fails the deploy loudly
#   6. NAS:    wait until yams-hub and the updater are healthy, ping the hub
#
# Usage: deploy/deploy.sh [options]
#   --dry-run       print every command (local and remote) without running anything
#   --first-run     also run make_hub_env.sh (secrets files, data dir, admin password prompt)
#                   before `up`, and verify.sh after it (both interactive over ssh -t)
#   --skip-web      reuse the existing app/build/web
#   --pull          docker build --pull (refresh the dart / distroless base images)
#   --only SERVICE  restart only this hub service (repeatable): yams-hub, socket-proxy-hub,
#                   yams-hub-updater (default: all three)
#   --allow-dirty   deploy HEAD even though the archived paths have uncommitted changes
#   --host HOST     ssh host (default: nas, or $NAS_HOST)
#   -h, --help      show this help
#
# Rollback: deploy/README.md ("Rollback").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAS_HOST=${NAS_HOST:-nas}
SSH_OPTS=(-o BatchMode=yes -o WarnWeakCrypto=no)
REMOTE_YAMS=/opt/yams
REMOTE_TMP_BASE=${REMOTE_TMP_BASE:-/tmp}
SECRETS_DIR=/opt/yams/monitoring/secrets
DATA_DIR=/volume1/mediashare/config/yams-hub
HUB_IP=172.28.0.49
HUB_SERVICES=(yams-hub socket-proxy-hub yams-hub-updater)
ARCHIVE_PATHS=(.dockerignore packages/yams_models gateway updater deploy)
ENV_SH=${YAMS_ENV_SH:-$HOME/development/env.sh}

dry_run=0 first_run=0 skip_web=0 pull=0 allow_dirty=0
only=()

usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --first-run) first_run=1 ;;
    --skip-web) skip_web=1 ;;
    --pull) pull=1 ;;
    --allow-dirty) allow_dirty=1 ;;
    --only)
      [[ $# -ge 2 ]] || {
        echo '--only needs a service' >&2
        exit 2
      }
      only+=("$2")
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
if ((${#only[@]})); then
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
dirty=$(git status --porcelain -- "${ARCHIVE_PATHS[@]}")
if [[ -n $dirty ]]; then
  if ((allow_dirty || dry_run)); then
    warn "uncommitted changes in the archived paths are NOT deployed (HEAD $sha is):"
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
  else
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
    die "uncommitted changes in ${ARCHIVE_PATHS[*]}: commit them (deploy ships HEAD) or pass --allow-dirty"
  fi
fi
ok "deploying $sha to $NAS_HOST: ${services[*]}"

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

# --- 2. web build ---------------------------------------------------------------------------------
if ((skip_web)); then
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
run find app/build/web -name '*.symbols' -delete

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
  mkdir -p "$local_stage/app/build"
  cp -a app/build/web "$local_stage/app/build/web"
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
step 'docker build on the NAS'
pull_flag=''
if ((pull)); then pull_flag='--pull'; fi
remote "
cd $(q "$remote_dir")
label=org.opencontainers.image.revision=$(q "$sha")
docker build $pull_flag --label \"\$label\" -f gateway/Dockerfile -t yams-hub:$(q "$sha") .
docker build $pull_flag --label \"\$label\" -f updater/Dockerfile -t yams-hub-updater:$(q "$sha") updater
for img in yams-hub yams-hub-updater; do
  new=\$(docker image inspect -f '{{.Id}}' \"\$img:$(q "$sha")\")
  cur=\$(docker image inspect -f '{{.Id}}' \"\$img:latest\" 2>/dev/null || true)
  old_prev=\$(docker image inspect -f '{{.Id}}' \"\$img:previous\" 2>/dev/null || true)
  if [[ -n \$cur && \$cur != \"\$new\" ]]; then
    docker image tag \"\$img:latest\" \"\$img:previous\"
  fi
  docker image tag \"\$img:$(q "$sha")\" \"\$img:latest\"
  docker image rm \"\$img:$(q "$sha")\" >/dev/null
  # The image that was :previous before is no longer needed (ignored while a container uses it).
  if [[ -n \$old_prev && \$old_prev != \"\$cur\" && \$old_prev != \"\$new\" ]]; then
    docker image rm \"\$old_prev\" >/dev/null 2>&1 || true
  fi
  echo \"\$img:latest = \${new:7:12} (previous: \${cur:7:12})\"
done
" || die 'docker build on the NAS failed'

# --- first run: secrets files and data dir --------------------------------------------------------
if ((first_run)); then
  step 'first run: make_hub_env.sh (on the NAS)'
  remote_tty "bash '$remote_dir/deploy/make_hub_env.sh'" || die 'make_hub_env.sh failed'
fi

# --- 5. up -d --no-deps with an id snapshot -------------------------------------------------------
snapshot() { remote "docker ps -a --no-trunc --format '{{.ID}} {{.Names}}'"; }

step 'restart the hub services'
if ((dry_run)); then
  snapshot
  remote "cd $(q "$REMOTE_YAMS") && $compose_cmd up -d --no-deps ${services[*]}"
  snapshot
else
  before=$(snapshot) || die 'docker ps snapshot failed'
  remote "cd $(q "$REMOTE_YAMS") && $compose_cmd up -d --no-deps ${services[*]}" || up_failed=1
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
