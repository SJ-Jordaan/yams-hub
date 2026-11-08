#!/usr/bin/env bash
# Mobile-web benchmark of the YAMS Hub web app: one command, re-runnable.
#
#   tool/perf/run.sh [--label baseline|after|...] [--repeat 3] [--skip-build]
#                    [--no-profile] [--no-safari-path] [--cpu 4] [--gpu hw|swiftshader]
#
# Builds the current working tree (release + profile web builds and the
# gateway executable), starts the mock upstreams + a local gateway, runs
# bench.py --repeat times against the release build, once more with the
# Safari/iOS image-decode path, and once against the profile build with
# Chromium traces. Writes tool/perf/results/<label>.json (and
# tool/perf/baseline.json when --label baseline) and prints a comparison with
# tool/perf/baseline.json.
#
# Environment:
#   PERF_OUT      where builds, traces, screenshots go (default ${TMPDIR:-/tmp}/yams-hub-perf)
#   YAMS_ENV_SH   toolchain env file (default ~/development/env.sh)
#   PERF_VENV     python venv (default ~/development/perf-venv; created by setup.sh)
#   PLAYWRIGHT_BROWSERS_PATH (default ~/development/ms-playwright)
#   PERF_MOCK_ARGS extra mock_upstreams.py args, e.g. "--scale 2 --poster-mode arr"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

label=run repeat=3 skip_build=0 profile=1 safari=1 cpu=4 gpu=hw
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --repeat) repeat="$2"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --no-profile) profile=0; shift ;;
    --no-safari-path) safari=0; shift ;;
    --cpu) cpu="$2"; shift 2 ;;
    --gpu) gpu="$2"; shift 2 ;;
    -h | --help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The label names a directory that is deleted and recreated below.
if [[ ! "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "--label must be letters, digits, '.', '_' or '-' (got '$label')" >&2
  exit 2
fi

env_sh="${YAMS_ENV_SH:-$HOME/development/env.sh}"
if [[ -f "$env_sh" ]]; then set +eu; source "$env_sh"; set -eu; fi
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/development/ms-playwright}"
VENV="${PERF_VENV:-$HOME/development/perf-venv}"
export PERF_PYTHON="$VENV/bin/python"
"$HERE/setup.sh" >/dev/null

OUT="${PERF_OUT:-${TMPDIR:-/tmp}/yams-hub-perf}"
mkdir -p "$OUT"
RUN="$OUT/$label"
rm -rf "$RUN"
mkdir -p "$RUN"
STACK="$OUT/stack"
export PERF_GATEWAY_BIN="$OUT/yams-hub-gateway"

cleanup() { "$HERE/stack.sh" stop "$STACK" || true; }
trap cleanup EXIT

if [[ "$skip_build" == 0 || ! -d "$OUT/web-release" ]]; then
  echo "==> flutter build web --release"
  (cd "$ROOT/app" && flutter build web --release --no-web-resources-cdn --no-wasm-dry-run -o "$OUT/web-release" >/dev/null)
  find "$OUT/web-release" -name '*.symbols' -delete
fi
if [[ "$profile" == 1 && ( "$skip_build" == 0 || ! -d "$OUT/web-profile" ) ]]; then
  echo "==> flutter build web --profile --source-maps"
  (cd "$ROOT/app" && flutter build web --profile --source-maps --no-web-resources-cdn --no-wasm-dry-run -o "$OUT/web-profile" >/dev/null)
fi
if [[ "$skip_build" == 0 || ! -x "$PERF_GATEWAY_BIN" ]]; then
  echo "==> dart compile exe gateway"
  (cd "$ROOT/gateway" && dart pub get >/dev/null && dart compile exe bin/server.dart -o "$PERF_GATEWAY_BIN" >/dev/null)
fi

bench() { "$PERF_PYTHON" "$HERE/bench.py" --cpu "$cpu" --gpu "$gpu" "$@"; }

runs=()
for i in $(seq 1 "$repeat"); do
  echo "==> release run $i/$repeat"
  url="$("$HERE/stack.sh" start "$STACK" "$OUT/web-release")"
  bench --url "$url" --label "$label" --out "$RUN/release-$i" >"$RUN/release-$i.log" 2>&1 \
    || { echo "run $i failed, see $RUN/release-$i.log" >&2; tail -20 "$RUN/release-$i.log" >&2; }
  cp "$STACK/gateway.log" "$RUN/release-$i/gateway.log" 2>/dev/null || true
  "$HERE/stack.sh" stop "$STACK"
  runs+=("$RUN/release-$i")
done

noid_args=()
if [[ "$safari" == 1 ]]; then
  echo "==> release, Safari/iOS image decode path (images phase)"
  url="$("$HERE/stack.sh" start "$STACK" "$OUT/web-release")"
  bench --url "$url" --label "$label-safari-path" --out "$RUN/safari-path" \
    --phases boot,login,images --no-image-decoder >"$RUN/safari-path.log" 2>&1 || true
  "$HERE/stack.sh" stop "$STACK"
  noid_args=(--noid "$RUN/safari-path")
fi

profile_args=()
if [[ "$profile" == 1 ]]; then
  echo "==> profile build + traces"
  url="$("$HERE/stack.sh" start "$STACK" "$OUT/web-profile")"
  bench --url "$url" --label "$label-profile" --out "$RUN/profile" --phases boot,login,dashboard,tabs,images \
    --trace --sourcemap "$OUT/web-profile/main.dart.js.map" >"$RUN/profile.log" 2>&1 || true
  "$HERE/stack.sh" stop "$STACK"
  profile_args=(--profile "$RUN/profile")
fi

result="$HERE/results/$label.json"
meta="$(printf '{"date":"%s","git":"%s","cpu":%s,"gpu":"%s","mock_args":"%s"}' \
  "$(date -Iseconds)" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo none)" \
  "$cpu" "$gpu" "${PERF_MOCK_ARGS:-}")"
"$PERF_PYTHON" "$HERE/aggregate.py" --label "$label" --runs "${runs[@]}" "${noid_args[@]}" "${profile_args[@]}" \
  --out "$result" --baseline "$HERE/baseline.json" --meta "$meta"
if [[ "$label" == baseline ]]; then
  cp "$result" "$HERE/baseline.json"
  echo "baseline written to $HERE/baseline.json"
fi
echo "artifacts (screenshots, traces, logs): $RUN"
