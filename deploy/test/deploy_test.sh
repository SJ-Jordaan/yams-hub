#!/usr/bin/env bash
# Tests for deploy/deploy.sh without a NAS: a throwaway git repo holds a copy of deploy.sh, `ssh`
# runs the remote scripts locally, and `docker` is fake_docker.sh (an in-memory-ish image store).
#
#   bash deploy/test/deploy_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SH="$HERE/../deploy.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/deploy-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

pass=0 fail=0
failed=()

# --- fixture --------------------------------------------------------------------------------------
bin="$work/bin"
mkdir -p "$bin"
cp "$HERE/fake_docker.sh" "$bin/docker"
cat >"$bin/ssh" <<'SH'
#!/usr/bin/env bash
# Fake ssh: drops options and the host, runs the command locally (stdin passed through).
while (($#)); do
  case "$1" in
    -o) shift 2 ;;
    -t) shift ;;
    *) break ;;
  esac
done
shift # host
exec bash -c "$*"
SH
# Fake curl: the proxy (:2375) drops the connection (exit 52, status 000) unless $st/proxy_http holds
# the HTTP status it should answer; everything else answers 200.
cat >"$bin/curl" <<'SH'
#!/usr/bin/env bash
w=0
for a; do [[ $a == -w ]] && w=1; done
url=${!#}
if [[ $url == *:2375/* ]]; then
  code=$(cat "$FAKE_DOCKER_STATE/proxy_http" 2>/dev/null || true)
  if [[ -n $code ]]; then
    ((w)) && printf '%s' "$code"
    exit 0
  fi
  ((w)) && printf 000
  exit 52
fi
((w)) && printf 200
exit 0
SH
# Fake ip: `ip -4 route show` prints $st/routes.
cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_DOCKER_STATE/routes" 2>/dev/null || true
SH
printf '#!/bin/sh\nexit 0\n' >"$bin/sleep"
chmod +x "$bin"/*

# new_case: a fresh repo, NAS dirs and docker state; sets $repo and $st.
new_case() {
  local c="$work/case$((pass + fail))"
  rm -rf "$c"
  repo="$c/repo" st="$c/docker"
  mkdir -p "$repo/deploy/socket-proxy-hub" "$repo/packages/yams_models" "$repo/gateway" "$repo/updater" \
    "$repo/app/build/web" "$c/opt_yams" "$c/secrets" "$c/data" "$c/nas_tmp" "$st/nets" "$st/stopped"
  cp "$DEPLOY_SH" "$repo/deploy/deploy.sh"
  printf 'build/\n' >"$repo/.gitignore"
  printf '.dart_tool\n' >"$repo/.dockerignore"
  echo models >"$repo/packages/yams_models/pubspec.yaml"
  echo gateway >"$repo/gateway/Dockerfile"
  echo updater >"$repo/updater/Dockerfile"
  echo '<!doctype html>' >"$repo/app/build/web/index.html"
  printf '%s\n' 'frontend proxy' '    bind @@BIND_PROTO@@' '    acl from_hub src 172.30.250.2 127.0.0.1 # YAMS-HUB' \
    '    tcp-request connection reject if !from_hub # YAMS-HUB' >"$repo/deploy/socket-proxy-hub/haproxy.cfg"
  touch "$c/secrets/yams-hub.env" "$c/secrets/yams-hub-updater.env"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
  export REMOTE_YAMS="$c/opt_yams" SECRETS_DIR="$c/secrets" DATA_DIR="$c/data" \
    REMOTE_TMP_BASE="$c/nas_tmp" FAKE_DOCKER_STATE="$st" UPDATER_IDLE_WAIT=900 \
    HAPROXY_CFG="$c/opt_yams/monitoring/yams-hub/socket-proxy-hub.haproxy.cfg"
}

# net NAME SUBNET [MEMBER...]: an existing Docker network.
net() {
  local name=$1 subnet=$2
  shift 2
  echo "$subnet" >"$st/nets/$name.subnet"
  printf '%s\n' "$@" | sed '/^$/d' >"$st/nets/$name.members"
}
# container NAME: an existing container (of a registry image).
container() { echo "sha256:$1-image" >"$st/containers/$1"; }
# The pre-2026-11-09 layout: the control network without IPAM, Docker picked 172.18.0.0/16.
old_ctl_network() {
  net yams_yams_hub_ctl 172.18.0.0/16 "$@"
}

commit_change() {
  echo "$2" >>"$repo/$1"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm change
}

# seed IMAGE LABELS...: an image tagged IMAGE:latest that the container IMAGE runs.
seed() {
  local img=$1 n id
  shift
  n=$(($(cat "$st/counter" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$st/counter"
  id=$(printf 'sha256:%064x' "$n")
  mkdir -p "$st/ids" "$st/tags" "$st/containers"
  printf '%s\n' "$@" >"$st/ids/${id#sha256:}"
  echo "$id" >"$st/tags/${img}__latest"
  echo "$id" >"$st/containers/$img"
  echo "$id"
}
tag_of() { cat "$st/tags/${1//:/__}" 2>/dev/null || echo none; }
running() { cat "$st/containers/$1"; }
updater_tree() { git -C "$repo" rev-parse HEAD:updater; }

deploy() {
  set +e
  out=$(cd "$repo" && PATH="$bin:$PATH" bash deploy/deploy.sh --skip-web --host nas "$@" 2>&1)
  status=$?
  set -e
  printf '%s\n' "$out" >"$work/out"
}

# check DESCRIPTION CONDITION...: records a failed assertion (errexit does not apply inside the
# `if` that runs a test, so failures are counted in a file instead of relying on exit codes).
check() {
  local d=$1
  shift
  if "$@"; then return 0; fi
  printf '    assertion failed: %s\n' "$d" >&2
  echo "$d" >>"$work/failures"
  return 0
}
contains() { [[ $1 == *"$2"* ]]; }
not_contains() { [[ $1 != *"$2"* ]]; }
calls() { cat "$st/calls" 2>/dev/null || true; }
# fake_config: the default `compose config` output of fake_docker.sh.
fake_config() { FAKE_DOCKER_STATE="$work/empty-state" "$bin/docker" compose -p yams config yams-hub; }
ups() { cat "$st/up" 2>/dev/null || true; }
forced() { cat "$st/force" 2>/dev/null || true; }
# line NUMBER of the first call matching an ERE (0 when absent).
call_line() { calls | grep -nE -m1 -- "$1" | cut -d: -f1 || echo 0; }

run_test() {
  local name=$1
  new_case
  rm -f "$work/out" "$work/failures"
  "$name" >"$work/log" 2>&1 || echo "$name returned $?" >>"$work/failures"
  if [[ ! -s $work/failures ]]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    failed+=("$name")
    printf 'FAIL %s\n' "$name"
    sed 's/^/    /' "$work/log"
    printf '    --- deploy output ---\n'
    sed 's/^/    /' "$work/out" 2>/dev/null || true
  fi
}

# --- tests ----------------------------------------------------------------------------------------
test_dirty_tree_refuses_without_allow_dirty() {
  echo wip >>"$repo/gateway/Dockerfile"
  echo scratch >"$repo/notes.txt"
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names --allow-dirty' contains "$out" '--allow-dirty'
  check 'says it ships HEAD' contains "$out" 'ships HEAD'
  check 'lists the modified file' contains "$out" 'gateway/Dockerfile'
  check 'lists the untracked file' contains "$out" 'notes.txt'
  check 'touched nothing on the NAS' test -z "$(calls)"
}

test_dirty_change_outside_archived_paths_also_refuses() {
  echo wip >>"$repo/.gitignore"
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'touched nothing on the NAS' test -z "$(calls)"
}

test_allow_dirty_deploys_head_and_says_so() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  echo wip >>"$repo/gateway/Dockerfile"
  deploy --allow-dirty
  check 'exit 0' test "$status" -eq 0
  check 'warns that the changes are not deployed' contains "$out" 'NOT deployed'
}

test_dry_run_on_dirty_tree_warns() {
  echo wip >>"$repo/gateway/Dockerfile"
  deploy --dry-run
  check 'exit 0' test "$status" -eq 0
  check 'says a real deploy refuses' contains "$out" 'a real deploy refuses'
  check 'touched nothing on the NAS' test -z "$(calls)"
}

test_unchanged_updater_is_left_running() {
  local upd hub
  upd=$(seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)")
  hub=$(seed yams-hub)
  commit_change gateway/Dockerfile 'gateway change'
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'one image built' test "$(calls | grep -c '^build')" -eq 1
  check 'only the gateway is built' contains "$(calls | grep '^build')" 'gateway/Dockerfile'
  check 'updater not passed to up' test "$(ups)" = 'yams-hub socket-proxy-hub'
  check 'updater not inspected for jobs' not_contains "$(calls)" 'top yams-hub-updater'
  check 'updater still runs its image' test "$(running yams-hub-updater)" = "$upd"
  check 'updater :latest untouched' test "$(tag_of yams-hub-updater:latest)" = "$upd"
  check 'updater has no :previous' test "$(tag_of yams-hub-updater:previous)" = none
  check 'hub :previous is what ran' test "$(tag_of yams-hub:previous)" = "$hub"
  check 'hub runs the new image' test "$(running yams-hub)" != "$hub"
  check 'says the updater was left running' contains "$out" 'left running'
}

test_changed_updater_is_rebuilt_with_its_tree_label() {
  local upd
  upd=$(seed yams-hub-updater "yams-hub.updater-tree=0000000000000000000000000000000000000000")
  seed yams-hub >/dev/null
  commit_change updater/Dockerfile 'updater change'
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'both images built' test "$(calls | grep -c '^build')" -eq 2
  check 'updater build carries its tree' contains "$(calls | grep 'updater/Dockerfile')" "yams-hub.updater-tree=$(updater_tree)"
  check 'checked for a running job first' contains "$(calls)" 'top yams-hub-updater'
  check 'updater passed to up' test "$(ups)" = 'yams-hub socket-proxy-hub yams-hub-updater'
  check 'updater :previous is what ran' test "$(tag_of yams-hub-updater:previous)" = "$upd"
  check 'updater runs the new build' test "$(running yams-hub-updater)" != "$upd"
}

test_unlabelled_updater_image_counts_as_changed() {
  seed yams-hub-updater >/dev/null
  seed yams-hub >/dev/null
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'updater passed to up' contains "$(ups)" 'yams-hub-updater'
}

test_only_hub_never_builds_or_retags_the_updater() {
  local upd hub
  upd=$(seed yams-hub-updater "yams-hub.updater-tree=0000000000000000000000000000000000000000")
  hub=$(seed yams-hub)
  commit_change updater/Dockerfile 'c2'
  deploy --only yams-hub
  check 'first deploy ok' test "$status" -eq 0
  commit_change updater/Dockerfile 'c3'
  : >"$st/calls"
  deploy --only yams-hub
  check 'second deploy ok' test "$status" -eq 0
  check 'no updater build' not_contains "$(calls)" 'updater/Dockerfile'
  check 'no updater job check' not_contains "$(calls)" 'top yams-hub-updater'
  check 'updater :latest is the image that runs' test "$(tag_of yams-hub-updater:latest)" = "$upd"
  check 'updater has no unverified :previous' test "$(tag_of yams-hub-updater:previous)" = none
  check 'updater not passed to up' test "$(ups | tail -n1)" = 'yams-hub'
  check 'hub :previous is the image that ran before' test "$(tag_of yams-hub:previous)" != "$hub"
  check 'hub :previous is not :latest' test "$(tag_of yams-hub:previous)" != "$(tag_of yams-hub:latest)"
}

test_previous_is_the_running_image_not_a_stale_latest() {
  local hub stale
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  hub=$(seed yams-hub)
  # A failed deploy left :latest at a build that never ran.
  stale=$(printf 'sha256:%064x' 99)
  touch "$st/ids/${stale#sha256:}"
  echo "$stale" >"$st/tags/yams-hub__latest"
  deploy
  check 'exit 0' test "$status" -eq 0
  check ':previous is the running image' test "$(tag_of yams-hub:previous)" = "$hub"
  check 'the stale build is dropped' contains "$(cat "$st/removed" 2>/dev/null)" "$stale"
}

test_waits_while_the_updater_runs_a_job() {
  seed yams-hub-updater >/dev/null
  seed yams-hub >/dev/null
  echo 2 >"$st/busy"
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'said it was waiting' contains "$out" 'is running a job; waiting'
  check 'polled until idle' test "$(calls | grep -c '^top yams-hub-updater')" -eq 3
  check 'then recreated it' contains "$(ups)" 'yams-hub-updater'
}

test_busy_updater_stops_the_deploy_before_up() {
  seed yams-hub-updater >/dev/null
  seed yams-hub >/dev/null
  echo forever >"$st/busy"
  UPDATER_IDLE_WAIT=10 deploy
  check 'exit 1' test "$status" -eq 1
  check 'says it is busy' contains "$out" 'still running a job'
  check 'no compose up ran' test -z "$(ups)"
}

test_only_updater_rebuilds_even_when_unchanged() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  deploy --only yams-hub-updater
  check 'exit 0' test "$status" -eq 0
  check 'only the updater is built' test "$(calls | grep '^build' | grep -c 'gateway/Dockerfile')" -eq 0
  check 'updater passed to up' test "$(ups)" = 'yams-hub-updater'
}

test_first_run_rejects_only() {
  deploy --first-run --only yams-hub
  check 'exit 2' test "$status" -eq 2
}

# --- the fixed control network (ARCHITECTURE §6) ----------------------------------------------------
test_haproxy_cfg_is_installed_and_the_proxy_recreated_first() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  container socket-proxy-hub
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'installed' cmp -s "$repo/deploy/socket-proxy-hub/haproxy.cfg" "$HAPROXY_CFG"
  check 'mode 0644' test "$(stat -c %a "$HAPROXY_CFG")" = 644
  check 'no temp file left' test "$(find "${HAPROXY_CFG%/*}" -name '.*' | wc -l)" -eq 0
  check 'proxy force-recreated' test "$(forced)" = 'socket-proxy-hub'
  check 'before the other services' test "$(call_line 'up -d --force-recreate')" -lt "$(call_line 'up -d --no-deps')"
  check 'main up unchanged' test "$(ups)" = 'yams-hub socket-proxy-hub'
  check 'says so' contains "$out" 'it will be recreated'
  check 'ACL proven after up' contains "$out" 'source ACL in effect'
  commit_change gateway/Dockerfile 'next'
  : >"$st/force"
  deploy
  check 'second deploy ok' test "$status" -eq 0
  check 'unchanged file is left alone' contains "$out" 'is up to date'
  check 'proxy not force-recreated again' test -z "$(forced)"
  check 'says it already serves it' contains "$out" 'already serves this template'
}

test_changed_haproxy_cfg_is_rewritten() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  mkdir -p "${HAPROXY_CFG%/*}"
  echo old >"$HAPROXY_CFG"
  container socket-proxy-hub
  echo old >"$st/rendered"
  commit_change deploy/socket-proxy-hub/haproxy.cfg '# upstream bump'
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'new content' cmp -s "$repo/deploy/socket-proxy-hub/haproxy.cfg" "$HAPROXY_CFG"
  check 'proxy force-recreated' test "$(forced)" = 'socket-proxy-hub'
  check 'proxy serves the new template' contains "$(cat "$st/rendered")" '# upstream bump'
}

# An earlier deploy installed the file but stopped before recreating the proxy: the file now looks
# unchanged, yet the proxy still serves the old rendering.
test_interrupted_install_still_recreates_the_proxy() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  container socket-proxy-hub
  mkdir -p "${HAPROXY_CFG%/*}"
  cp "$repo/deploy/socket-proxy-hub/haproxy.cfg" "$HAPROXY_CFG"
  printf 'frontend proxy\n    bind [::]:2375 v4v6\n' >"$st/rendered"
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'file left alone' contains "$out" 'is up to date'
  check 'proxy force-recreated' test "$(forced)" = 'socket-proxy-hub'
  check 'says why' contains "$out" 'older rendering'
}

test_stopped_proxy_is_started_not_forced() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  container socket-proxy-hub
  touch "$st/stopped/socket-proxy-hub"
  deploy
  check 'exit 0' test "$status" -eq 0
  check 'no force-recreate' test -z "$(forced)"
  check 'started by up' test ! -e "$st/stopped/socket-proxy-hub"
  check 'serves the template' contains "$(cat "$st/rendered")" 'acl from_hub src 172.30.250.2'
}

test_exposed_proxy_is_stopped_and_fails_the_deploy() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  echo 200 >"$st/proxy_http"
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names the probe' contains "$out" 'the host got HTTP 200'
  check 'proxy stopped' contains "$(calls)" 'stop socket-proxy-hub'
  check 'says so' contains "$out" 'NOT protected by its source ACL'
}

test_proxy_without_acl_in_its_rendering_is_stopped() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  # A template that lost its YAMS-HUB lines (an upstream bump copied over wholesale).
  printf '%s\n' 'frontend proxy' '    bind @@BIND_PROTO@@' >"$repo/deploy/socket-proxy-hub/haproxy.cfg"
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qam 'lost acl'
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names the missing reject' contains "$out" "no 'tcp-request connection reject if !from_hub'"
  check 'proxy stopped' contains "$(calls)" 'stop socket-proxy-hub'
}

test_render_drift_fails_without_stopping_the_proxy() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  FAKE_BIND='[::]:2375 v4v6' deploy
  check 'exit 1' test "$status" -eq 1
  check 'names DISABLE_IPV6' contains "$out" 'DISABLE_IPV6 ignored'
  check 'proxy not stopped' not_contains "$(calls)" 'stop socket-proxy-hub'
}

test_template_through_the_helper_container() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  CFG_INSTALL_VIA_CONTAINER=1 deploy
  check 'exit 0' test "$status" -eq 0
  check 'used the pinned proxy image' contains "$(calls | grep '^run ')" \
    '--entrypoint sh -v '"${HAPROXY_CFG%/*/*}"':/m lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105@sha256:'
  check 'no network, root' contains "$(calls | grep '^run ')" '--network none --user 0:0'
  check 'installed' cmp -s "$repo/deploy/socket-proxy-hub/haproxy.cfg" "$HAPROXY_CFG"
  check 'mode 0644' test "$(stat -c %a "$HAPROXY_CFG")" = 644
  check 'no temp file left' test "$(find "${HAPROXY_CFG%/*}" -name '.*' | wc -l)" -eq 0
}

test_other_container_recreated_fails_the_deploy() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  container sonarr
  container radarr
  echo sonarr >"$st/recreate_also"
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names sonarr only' contains "$out" 'containers outside the hub changed id: sonarr'
  check 'shows the ids' contains "$out" 'cid-sonarr-0 -> cid-sonarr-1'
  check 'radarr not named' not_contains "$out" 'radarr '
}

test_migration_that_touches_another_container_fails() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  container socket-proxy-hub
  container sonarr
  old_ctl_network yams-hub socket-proxy-hub yams-hub-updater
  echo sonarr >"$st/recreate_also"
  deploy --migrate-ctl-network
  check 'exit 1' test "$status" -eq 1
  check 'names sonarr' contains "$out" 'containers outside the hub changed id: sonarr'
}

test_only_hub_does_not_install_haproxy_cfg_but_warns() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  deploy --only yams-hub
  check 'exit 0' test "$status" -eq 0
  check 'not installed' test ! -e "$HAPROXY_CFG"
  check 'warns' contains "$out" '--only socket-proxy-hub'
  check 'proxy untouched' test -z "$(forced)"
}

test_setting_in_the_wrong_service_stops_in_preflight() {
  # DISABLE_IPV6 under the updater instead of the proxy: matching the whole config would accept it.
  fake_config | sed -e '/^  socket-proxy-hub:/,/^  yams-hub:/{/DISABLE_IPV6/d}' \
    -e 's/^      UPDATER_TOKEN_FILE:.*/&\n      DISABLE_IPV6: "1"/' >"$st/compose_config.new"
  mv "$st/compose_config.new" "$st/compose_config"
  check 'fixture moved the setting' test "$(grep -c DISABLE_IPV6 "$st/compose_config")" -eq 1
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names it' contains "$out" 'socket-proxy-hub DISABLE_IPV6=1'
  check 'nothing else missing' not_contains "$out" 'ipv4_address'
  check 'nothing built' not_contains "$(calls)" 'build'
}

test_host_route_overlap_stops_in_preflight() {
  printf '%s\n' 'default via 192.168.10.1 dev eth0 proto dhcp' '192.168.10.0/24 dev eth0 proto kernel scope link' \
    '172.30.0.0/16 dev wg0 scope link' >"$st/routes"
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names the route' contains "$out" '172.30.0.0/16 dev wg0'
  check 'nothing built' not_contains "$(calls)" 'build'
}

test_ctl_network_with_wrong_gateway_needs_migration() {
  seed yams-hub-updater >/dev/null
  seed yams-hub >/dev/null
  net yams_yams_hub_ctl 172.30.250.0/29 yams-hub socket-proxy-hub yams-hub-updater
  echo 172.30.250.6 >"$st/nets/yams_yams_hub_ctl.gateway"
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names the gateway' contains "$out" 'exists with subnet 172.30.250.0/29 and gateway 172.30.250.6'
  check 'nothing started' test -z "$(ups)$(forced)"
}

test_stopped_stranger_on_the_ctl_network_blocks_the_migration() {
  seed yams-hub-updater >/dev/null
  seed yams-hub >/dev/null
  container socket-proxy-hub
  old_ctl_network yams-hub socket-proxy-hub yams-hub-updater
  echo leftover >"$st/nets/yams_yams_hub_ctl.stopped"
  deploy --migrate-ctl-network
  check 'exit 1' test "$status" -eq 1
  check 'names it' contains "$out" 'running or stopped): leftover'
  check 'no stop' test "$(call_line '^stop ')" -eq 0
  check 'network kept' test -f "$st/nets/yams_yams_hub_ctl.subnet"
}

test_old_compose_layout_stops_in_preflight() {
  cat >"$st/compose_config" <<'EOF'
services:
  socket-proxy-hub:
    networks:
      yams_hub_ctl: null
networks:
  yams_hub_ctl:
    internal: true
EOF
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'says to re-merge' contains "$out" 'predates the fixed control network'
  check 'names the subnet' contains "$out" 'yams_hub_ctl subnet 172.30.250.0/29'
  check 'names the allow-list' contains "$out" 'UPDATER_ALLOWED_SOURCES=172.30.250.2'
  check 'nothing built' not_contains "$(calls)" 'build'
  check 'nothing started' test -z "$(ups)"
}

test_overlapping_network_stops_in_preflight() {
  net yams_yams_network 172.28.0.0/24
  net someone_else 172.30.0.0/16
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names the clash' contains "$out" 'someone_else (172.30.0.0/16)'
  check 'nothing built' not_contains "$(calls)" 'build'
}

test_old_ctl_network_prints_the_migration_and_changes_nothing() {
  seed yams-hub-updater >/dev/null
  seed yams-hub >/dev/null
  container socket-proxy-hub
  old_ctl_network yams-hub socket-proxy-hub yams-hub-updater
  deploy
  check 'exit 1' test "$status" -eq 1
  check 'names the subnets' contains "$out" 'yams_yams_hub_ctl exists with subnet 172.18.0.0/16, but the compose file now pins 172.30.250.0/29'
  check 'offers the flag' contains "$out" 'deploy/deploy.sh --migrate-ctl-network'
  check 'prints the exact commands' contains "$out" "ssh nas 'docker stop yams-hub yams-hub-updater socket-proxy-hub && docker rm yams-hub yams-hub-updater socket-proxy-hub && docker network rm yams_yams_hub_ctl'"
  check 'no stop' test "$(call_line '^stop ')" -eq 0
  check 'no rm' test "$(call_line '^(rm|network rm) ')" -eq 0
  check 'nothing built' not_contains "$(calls)" 'build'
  check 'nothing started' test -z "$(ups)$(forced)"
  check 'network kept' test -f "$st/nets/yams_yams_hub_ctl.subnet"
}

test_migrate_ctl_network_recreates_only_the_hub() {
  local upd
  upd=$(seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)")
  seed yams-hub >/dev/null
  container socket-proxy-hub
  container sonarr
  old_ctl_network yams-hub socket-proxy-hub yams-hub-updater
  net yams_yams_network 172.28.0.0/24 sonarr yams-hub
  deploy --migrate-ctl-network
  check 'exit 0' test "$status" -eq 0
  check 'stopped exactly the hub trio' test "$(calls | grep '^stop ' | sort | tr '\n' ' ')" = 'stop socket-proxy-hub stop yams-hub stop yams-hub-updater '
  check 'removed exactly the hub trio' test "$(calls | grep '^rm ' | sort | tr '\n' ' ')" = 'rm socket-proxy-hub rm yams-hub rm yams-hub-updater '
  check 'removed only the ctl network' test "$(calls | grep '^network rm' | tr '\n' ' ')" = 'network rm yams_yams_hub_ctl '
  check 'after the job check' test "$(call_line '^top yams-hub-updater')" -lt "$(call_line '^stop ')"
  check 'before compose up' test "$(call_line '^stop ')" -lt "$(call_line 'up -d --no-deps')"
  check 'all three recreated' test "$(ups)" = 'yams-hub socket-proxy-hub yams-hub-updater'
  check 'no separate proxy recreate' test -z "$(forced)"
  check 'network recreated by compose' test "$(cat "$st/nets/yams_yams_hub_ctl.subnet")" = 172.30.250.0/29
  check 'yams_network untouched' test -f "$st/nets/yams_yams_network.subnet"
  check 'sonarr untouched' test -f "$st/containers/sonarr"
  check 'unchanged updater not rebuilt' not_contains "$(calls | grep '^build')" 'updater/Dockerfile'
  check 'updater runs the same image' test "$(running yams-hub-updater)" = "$upd"
  check 'snapshot guarantee still checked' contains "$out" 'no container outside'
}

test_migrate_refuses_when_other_containers_share_the_ctl_network() {
  seed yams-hub-updater >/dev/null
  seed yams-hub >/dev/null
  container portainer
  old_ctl_network yams-hub socket-proxy-hub yams-hub-updater portainer
  deploy --migrate-ctl-network
  check 'exit 1' test "$status" -eq 1
  check 'names the stranger' contains "$out" 'portainer'
  check 'no stop' test "$(call_line '^stop ')" -eq 0
  check 'nothing started' test -z "$(ups)"
}

test_migrate_flag_is_a_noop_once_migrated() {
  seed yams-hub-updater "yams-hub.updater-tree=$(updater_tree)" >/dev/null
  seed yams-hub >/dev/null
  net yams_yams_hub_ctl 172.30.250.0/29 yams-hub socket-proxy-hub yams-hub-updater
  echo 172.30.250.1 >"$st/nets/yams_yams_hub_ctl.gateway"
  net neighbour 172.30.250.8/29
  # The control network's own bridge route is no clash (fake network id 0123456789ab...).
  echo '172.30.250.0/29 dev br-0123456789ab proto kernel scope link src 172.30.250.1' >"$st/routes"
  deploy --migrate-ctl-network
  check 'exit 0' test "$status" -eq 0
  check 'says nothing to migrate' contains "$out" 'nothing to migrate'
  check 'adjacent subnet is no clash' not_contains "$out" 'overlaps'
  check 'no stop' test "$(call_line '^stop ')" -eq 0
  check 'updater left running' test "$(ups)" = 'yams-hub socket-proxy-hub'
}

test_migrate_rejects_only() {
  deploy --migrate-ctl-network --only yams-hub
  check 'exit 2' test "$status" -eq 2
}

test_dry_run_with_migrate_shows_the_migration() {
  deploy --dry-run --migrate-ctl-network
  check 'exit 0' test "$status" -eq 0
  check 'shows the network removal' contains "$out" 'docker network rm "$CTL_NET"'
  check 'shows the haproxy install' contains "$out" 'haproxy-cfg: installed'
  check 'touched nothing on the NAS' test -z "$(calls)"
}

# --- verify.sh check 1, against fake_verify.sh (the scenario files are described there) ------------
vbin="$work/vbin"
mkdir -p "$vbin"
cp "$HERE/fake_verify.sh" "$vbin/docker"
cp "$HERE/fake_verify.sh" "$vbin/curl"
chmod +x "$vbin"/*

# verify: runs the real verify.sh (check 5 skipped) and keeps its check 1 lines in $v1.
verify() {
  vs="$st/verify"
  mkdir -p "$vs"
  [[ -f $vs/rendered ]] || sed 's/@@BIND_PROTO@@/:2375/g' "$HERE/../socket-proxy-hub/haproxy.cfg" >"$vs/rendered"
  set +e
  out=$(VERIFY_STATE="$vs" YAMS_SECRETS_DIR="$work/no-secrets" PATH="$vbin:$PATH" \
    bash "$HERE/../verify.sh" --skip-health 2>&1)
  set -e
  printf '%s\n' "$out" >"$work/out"
  v1=$(grep -E '^(PASS|FAIL) 1 ' <<<"$out" || true)
}
verify_state() { mkdir -p "$st/verify" && printf '%s\n' "$2" >"$st/verify/$1"; }

test_verify_fixed_layout_passes() {
  verify
  check 'PASS 1' contains "$v1" 'PASS 1 isolation'
  check 'no FAIL 1' not_contains "$v1" 'FAIL 1'
  check 'probed from prowlarr and the host' contains "$v1" 'refuse prowlarr host'
  check 'notes check 5' contains "$out" 'check 5 is skipped'
}

test_verify_old_behaviour_fails() {
  verify_state proxy open
  verify_state updater 401
  verify
  check 'proxy reached' contains "$v1" 'FAIL 1 isolation: prowlarr reached socket-proxy-hub (http://172.30.250.3:2375/_ping answered HTTP 200)'
  check 'host too' contains "$v1" 'host reached socket-proxy-hub'
  check 'updater 401' contains "$v1" 'prowlarr got HTTP 401 from the updater'
  check 'no PASS 1' not_contains "$v1" 'PASS 1'
}

test_verify_broken_prowlarr_probe_fails() {
  verify_state prowlarr_curl missing
  verify
  check 'cannot probe' contains "$v1" 'FAIL 1 isolation: cannot probe from prowlarr (its curl got exit 126'
  check 'no PASS 1' not_contains "$v1" 'PASS 1'
}

test_verify_updater_dropping_the_connection_passes() {
  verify_state updater drop
  verify
  check 'PASS 1' contains "$v1" 'PASS 1 isolation'
}

test_verify_v4v6_bind_fails() {
  mkdir -p "$st/verify"
  sed 's/@@BIND_PROTO@@/[::]:2375 v4v6/g' "$HERE/../socket-proxy-hub/haproxy.cfg" >"$st/verify/rendered"
  verify
  check 'names the bind' contains "$v1" "does not bind exactly ':2375' (bind [::]:2375 v4v6;)"
  check 'no PASS 1' not_contains "$v1" 'PASS 1'
}

test_verify_extra_acl_line_fails() {
  mkdir -p "$st/verify"
  sed -e 's/@@BIND_PROTO@@/:2375/g' -e 's|^\(    acl from_hub src .*\)$|\1\n    acl from_hub src 0.0.0.0/0|' \
    "$HERE/../socket-proxy-hub/haproxy.cfg" >"$st/verify/rendered"
  check 'fixture has two acl lines' test "$(grep -cE '^ +acl from_hub' "$st/verify/rendered")" -eq 2
  verify
  check 'names the ACL' contains "$v1" "needs exactly one 'acl from_hub src 172.30.250.2 127.0.0.1'"
}

test_verify_template_without_acl_fails() {
  mkdir -p "$st/verify"
  sed -e 's/@@BIND_PROTO@@/:2375/g' -e '/YAMS-HUB/d' "$HERE/../socket-proxy-hub/haproxy.cfg" >"$st/verify/rendered"
  verify
  check 'names the reject rule' contains "$v1" 'no source ACL reject rule'
}

test_verify_shared_network_namespace_fails() {
  verify_state netmodes "$(printf '%s\n' '/sonarr yams_network' \
    "/sidecar container:$(printf '%s' yams-hub-updater | sha256sum | cut -c1-12)" '/debug container:yams-hub')"
  verify
  check 'by id prefix' contains "$v1" 'sidecar shares the network namespace of yams-hub-updater'
  check 'by name' contains "$v1" 'debug shares the network namespace of yams-hub'
  check 'gluetun sharing is fine' not_contains "$v1" 'qbittorrent'
}

test_verify_wrong_address_fails() {
  verify_state ip_yams-hub 172.30.250.5
  verify
  check 'names it' contains "$v1" 'yams-hub has 172.30.250.5 on yams_yams_hub_ctl, expected 172.30.250.2'
}

# The addresses live in five files; they must agree (this checks the real repo, not the fixture).
test_control_plane_addresses_agree() {
  local top="$HERE/../.." compose verify hp v
  compose=$(cat "$top/deploy/docker-compose.hub.yaml")
  verify=$(cat "$top/deploy/verify.sh")
  hp=$(cat "$top/deploy/socket-proxy-hub/haproxy.cfg")
  # shellcheck disable=SC1090
  eval "$(grep -E '^(CTL_NET|HUB_CTL_[A-Z_]+|HUB_IP)=' "$DEPLOY_SH")"
  eval "$(grep -E '^HAPROXY_CFG=' "$DEPLOY_SH" | sed 's/^HAPROXY_CFG=.*:-\(.*\)}$/HAPROXY_DEFAULT=\1/')"
  check 'subnet in compose' contains "$compose" "- subnet: $HUB_CTL_SUBNET"
  check 'bridge gateway in compose' grep -qxE "\s+gateway: ${HUB_CTL_BRIDGE_IP//./\\.}" <<<"$compose"
  check 'hub address in compose' contains "$compose" "ipv4_address: $HUB_CTL_GATEWAY_IP "
  check 'proxy address in compose' grep -qxE "\s+ipv4_address: ${HUB_CTL_PROXY_IP//./\\.}" <<<"$compose"
  check 'updater address in compose' grep -qxE "\s+ipv4_address: ${HUB_CTL_UPDATER_IP//./\\.}" <<<"$compose"
  check 'yams_network address in compose' grep -qxE "\s+ipv4_address: ${HUB_IP//./\\.}" <<<"$compose"
  check 'updater allow-list in compose' contains "$compose" "UPDATER_ALLOWED_SOURCES=$HUB_CTL_GATEWAY_IP "
  check 'haproxy mount in compose' contains "$compose" "source: $HAPROXY_DEFAULT"
  check 'ACL in haproxy.cfg' grep -qE "^\s+acl from_hub src ${HUB_CTL_GATEWAY_IP//./\\.} 127\.0\.0\.1 # YAMS-HUB$" <<<"$hp"
  check 'one ACL line in haproxy.cfg' test "$(grep -cE '^\s*acl\s+from_hub\s' <<<"$hp")" -eq 1
  check 'reject in haproxy.cfg' grep -qE '^\s+tcp-request connection reject if !from_hub( |$)' <<<"$hp"
  for v in CTL_NET HUB_CTL_SUBNET HUB_CTL_GATEWAY_IP HUB_CTL_PROXY_IP HUB_CTL_UPDATER_IP; do
    check "verify.sh $v" grep -qx "$v=${!v}" <<<"$verify"
  done
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do run_test "$t"; done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
