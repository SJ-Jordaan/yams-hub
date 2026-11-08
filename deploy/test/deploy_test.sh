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
printf '#!/bin/sh\nexit 0\n' >"$bin/curl"
printf '#!/bin/sh\nexit 0\n' >"$bin/sleep"
chmod +x "$bin"/*

# new_case: a fresh repo, NAS dirs and docker state; sets $repo and $st.
new_case() {
  local c="$work/case$((pass + fail))"
  rm -rf "$c"
  repo="$c/repo" st="$c/docker"
  mkdir -p "$repo/deploy" "$repo/packages/yams_models" "$repo/gateway" "$repo/updater" \
    "$repo/app/build/web" "$c/opt_yams" "$c/secrets" "$c/data" "$c/nas_tmp" "$st"
  cp "$DEPLOY_SH" "$repo/deploy/deploy.sh"
  printf 'build/\n' >"$repo/.gitignore"
  printf '.dart_tool\n' >"$repo/.dockerignore"
  echo models >"$repo/packages/yams_models/pubspec.yaml"
  echo gateway >"$repo/gateway/Dockerfile"
  echo updater >"$repo/updater/Dockerfile"
  echo '<!doctype html>' >"$repo/app/build/web/index.html"
  touch "$c/secrets/yams-hub.env" "$c/secrets/yams-hub-updater.env"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
  export REMOTE_YAMS="$c/opt_yams" SECRETS_DIR="$c/secrets" DATA_DIR="$c/data" \
    REMOTE_TMP_BASE="$c/nas_tmp" FAKE_DOCKER_STATE="$st" UPDATER_IDLE_WAIT=900
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
ups() { cat "$st/up" 2>/dev/null || true; }

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

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do run_test "$t"; done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
