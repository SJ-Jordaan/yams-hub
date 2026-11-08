#!/usr/bin/env bash
# Start / stop the benchmark stack: mock upstreams + a local gateway serving a
# web build. Used by run.sh; handy on its own for poking at the app.
#
#   tool/perf/stack.sh start <run-dir> <web-dir>   # prints the hub URL
#   tool/perf/stack.sh stop  <run-dir>
#
# Environment:
#   PERF_HUB_PORT        gateway port (default 18090)
#   PERF_MOCK_BASE_PORT  first mock port (default 18100; 14 ports are used)
#   PERF_MOCK_ARGS       extra mock_upstreams.py arguments (e.g. "--scale 2")
#   PERF_GATEWAY_BIN     prebuilt gateway executable (default: compiled into
#                        <run-dir>/../yams-hub-gateway when missing)
#   PERF_PASSWORD        admin password (default perf-bench-pass)
#   PERF_PYTHON          python with Pillow (default ~/development/perf-venv/bin/python)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cmd="${1:-}"
run_dir="${2:-}"
[[ -n "$cmd" && -n "$run_dir" ]] || { sed -n '2,16p' "$0"; exit 2; }

HUB_PORT="${PERF_HUB_PORT:-18090}"
MOCK_PORT="${PERF_MOCK_BASE_PORT:-18100}"
PASSWORD="${PERF_PASSWORD:-perf-bench-pass}"
PY="${PERF_PYTHON:-$HOME/development/perf-venv/bin/python}"

stop_pid() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local pid
    pid="$(cat "$f")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$f"
  fi
}

wait_port() {
  local url="$1"
  for _ in $(seq 1 100); do
    if curl -s -o /dev/null "$url"; then return 0; fi
    sleep 0.2
  done
  echo "timed out waiting for $url" >&2
  return 1
}

case "$cmd" in
  stop)
    stop_pid "$run_dir/gateway.pid"
    stop_pid "$run_dir/mock.pid"
    ;;
  start)
    web_dir="${3:?web dir}"
    mkdir -p "$run_dir"
    "$0" stop "$run_dir"
    for port in "$HUB_PORT" "$MOCK_PORT"; do
      if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
        echo "port $port is already in use (a stack from another run dir? stop it first)" >&2
        exit 1
      fi
    done
    rm -rf "$run_dir/data" "$run_dir/unmatched.log" "$run_dir/mock.env"
    mkdir -p "$run_dir/data" "$run_dir/recyclarr"

    bin="${PERF_GATEWAY_BIN:-$(dirname "$run_dir")/yams-hub-gateway}"
    if [[ ! -x "$bin" ]]; then
      echo "compiling gateway -> $bin" >&2
      (cd "$ROOT/gateway" && dart pub get >/dev/null && dart compile exe bin/server.dart -o "$bin" >&2)
    fi

    # shellcheck disable=SC2086
    "$PY" "$HERE/mock_upstreams.py" --base-port "$MOCK_PORT" \
      --env-out "$run_dir/mock.env" --unmatched-log "$run_dir/unmatched.log" \
      --stats-out "$run_dir/mock-stats.json" ${PERF_MOCK_ARGS:-} \
      >"$run_dir/mock.log" 2>&1 &
    echo $! >"$run_dir/mock.pid"
    for _ in $(seq 1 100); do [[ -s "$run_dir/mock.env" ]] && break; sleep 0.1; done
    [[ -s "$run_dir/mock.env" ]] || { cat "$run_dir/mock.log" >&2; exit 1; }

    hash="$(printf '%s' "$PASSWORD" | "$bin" hash-password 2>/dev/null | tail -1)"
    {
      cat "$run_dir/mock.env"
      echo "YAMS_HUB_ADMIN_PASSWORD_HASH='$hash'"
    } >"$run_dir/secrets.env"
    chmod 600 "$run_dir/secrets.env"

    YAMS_HUB_PORT="$HUB_PORT" \
    YAMS_HUB_DATA_DIR="$run_dir/data" \
    YAMS_HUB_WEB_DIR="$web_dir" \
    YAMS_HUB_SECRETS_FILE="$run_dir/secrets.env" \
    HOST_NET_DEV=/proc/net/dev \
    RECYCLARR_LOG_DIR="$run_dir/recyclarr" \
      "$bin" serve >"$run_dir/gateway.log" 2>&1 &
    echo $! >"$run_dir/gateway.pid"
    wait_port "http://127.0.0.1:$HUB_PORT/api/v1/ping"
    echo "http://127.0.0.1:$HUB_PORT/"
    ;;
  *)
    echo "unknown command: $cmd" >&2
    exit 2
    ;;
esac
