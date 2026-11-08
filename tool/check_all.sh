#!/usr/bin/env bash
# Analyze and test every package of the repo, then smoke-build the Docker images.
#
#   tool/check_all.sh [--skip-docker]
#
# Order (ARCHITECTURE §4, §5.20, §12):
#   1. `dart analyze packages/yams_models` first: a duplicate public model name
#      breaks every other package, so the run stops here when it fails.
#   2. analyze + test for each package that exists: yams_models, gateway,
#      updater (dart) and app (flutter).
#   3. docker build smoke of gateway/Dockerfile and updater/Dockerfile (each
#      skipped while it does not exist; the whole step is skipped with a warning
#      when docker is not available).
#
# Environment:
#   YAMS_ENV_SH          toolchain env file to source (default ~/development/env.sh)
#   CHECK_ALL_SKIP_DOCKER=1  same as --skip-docker
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

skip_docker="${CHECK_ALL_SKIP_DOCKER:-0}"
for arg in "$@"; do
  case "$arg" in
    --skip-docker) skip_docker=1 ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

env_sh="${YAMS_ENV_SH:-$HOME/development/env.sh}"
if [[ -f "$env_sh" ]]; then
  # The env file is not written for `set -eu`; relax both while sourcing it.
  set +eu
  # shellcheck disable=SC1090
  source "$env_sh"
  set -eu
fi

if [[ -t 1 ]]; then
  bold=$'\e[1m' red=$'\e[31m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
else
  bold='' red='' green='' yellow='' reset=''
fi

failures=()
skipped=()

section() { printf '\n%s==> %s%s\n' "$bold" "$*" "$reset"; }
warn() { printf '%sWARNING: %s%s\n' "$yellow" "$*" "$reset" >&2; }

# run <label> <dir> <command...>: runs the command inside <dir>, records failures.
run() {
  local label="$1" dir="$2"
  shift 2
  section "$label"
  if (cd "$dir" && "$@"); then
    printf '%sok%s %s\n' "$green" "$reset" "$label"
    return 0
  fi
  printf '%sFAILED%s %s\n' "$red" "$reset" "$label"
  failures+=("$label")
  return 1
}

has_tests() { [[ -d "$1/test" ]] && find "$1/test" -name '*_test.dart' -print -quit | grep -q .; }

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '%s%s not found on PATH (source %s?)%s\n' "$red" "$1" "$env_sh" "$reset" >&2
    exit 1
  fi
}

require_tool dart

# --- 1. shared models first --------------------------------------------------
models=packages/yams_models
if [[ ! -f "$models/pubspec.yaml" ]]; then
  echo "${red}$models/pubspec.yaml is missing${reset}" >&2
  exit 1
fi
run "yams_models: pub get" "$models" dart pub get || exit 1
run "yams_models: analyze" . dart analyze --fatal-infos "$models" || {
  echo "${red}yams_models must analyze cleanly before anything else is checked.${reset}" >&2
  exit 1
}

# --- 2. every package ----------------------------------------------------------
check_dart_package() {
  local name="$1" dir="$2"
  if [[ ! -f "$dir/pubspec.yaml" ]]; then
    skipped+=("$name (no $dir/pubspec.yaml yet)")
    return
  fi
  if [[ "$dir" != "$models" ]]; then
    run "$name: pub get" "$dir" dart pub get || return 0 # recorded in failures; keep checking the other packages
    run "$name: analyze" "$dir" dart analyze --fatal-infos . || true
  fi
  if has_tests "$dir"; then
    run "$name: test" "$dir" dart test || true
  else
    skipped+=("$name tests (none yet)")
  fi
}

check_flutter_package() {
  local name="$1" dir="$2"
  if [[ ! -f "$dir/pubspec.yaml" ]]; then
    skipped+=("$name (no $dir/pubspec.yaml yet)")
    return
  fi
  require_tool flutter
  run "$name: pub get" "$dir" flutter pub get || return 0 # recorded in failures; keep checking the other packages
  run "$name: analyze" "$dir" flutter analyze || true
  if has_tests "$dir"; then
    run "$name: test" "$dir" flutter test || true
  else
    skipped+=("$name tests (none yet)")
  fi
}

check_dart_package yams_models "$models"
check_dart_package gateway gateway
check_dart_package updater updater
check_flutter_package app app

# --- 3. docker build smoke -----------------------------------------------------
docker_smoke() {
  section "docker build smoke"
  if [[ "$skip_docker" == 1 ]]; then
    warn 'docker build smoke skipped (--skip-docker).'
    skipped+=('docker build smoke (--skip-docker)')
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn 'docker is not installed: docker build smoke skipped.'
    skipped+=('docker build smoke (docker not available)')
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    warn 'docker daemon is not reachable: docker build smoke skipped.'
    skipped+=('docker build smoke (docker daemon not reachable)')
    return
  fi

  local placeholder=app/build/web/index.html created_placeholder=0
  if [[ -f gateway/Dockerfile && ! -f "$placeholder" ]]; then
    mkdir -p "$(dirname "$placeholder")"
    printf '<!doctype html><title>YAMS Hub</title><p>placeholder web build (tool/check_all.sh)</p>\n' >"$placeholder"
    created_placeholder=1
  fi

  if [[ -f gateway/Dockerfile ]]; then
    run 'docker build gateway' . docker build -f gateway/Dockerfile -t yams-hub:smoke . || true
  else
    skipped+=('docker build gateway (no gateway/Dockerfile yet)')
  fi
  if [[ -f updater/Dockerfile ]]; then
    run 'docker build updater' . docker build -f updater/Dockerfile -t yams-hub-updater:smoke updater || true
  else
    skipped+=('docker build updater (no updater/Dockerfile yet)')
  fi

  if [[ "$created_placeholder" == 1 ]]; then
    rm -f "$placeholder"
    rmdir -p "$(dirname "$placeholder")" 2>/dev/null || true
  fi
}
docker_smoke

# --- summary -------------------------------------------------------------------
section summary
for s in ${skipped[@]+"${skipped[@]}"}; do
  printf '%sskipped%s %s\n' "$yellow" "$reset" "$s"
done
if ((${#failures[@]})); then
  for f in "${failures[@]}"; do
    printf '%sFAILED%s  %s\n' "$red" "$reset" "$f"
  done
  exit 1
fi
printf '%sAll checks passed.%s\n' "$green" "$reset"
