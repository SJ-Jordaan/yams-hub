#!/usr/bin/env bash
# Post-deploy verification of YAMS Hub (ARCHITECTURE §6, "Deploy verification"). Run ON THE NAS
# after the first `up -d` (deploy.sh --first-run does it for you). Prints PASS/FAIL/SKIP per
# check and exits 1 if anything failed. It changes nothing (only throwaway --rm containers) and
# prints no secret values.
#
# Usage: verify.sh [--hub-url URL] [--tailscale-url URL] [--user NAME] [--skip-health]
#   --hub-url URL        LAN URL of the hub (default http://192.168.10.183:8090)
#   --tailscale-url URL  Tailscale URL (default: http://<tailscale0 IPv4>:8090 when tailscale0 is up)
#   --user NAME          hub account for the /health check (default admin; the password is
#                        prompted, or set YAMS_HUB_TOKEN to an access token instead)
#   --skip-health        skip check 5 (no login)
#
# Checks:
#   1. socket-proxy-hub and yams-hub-updater are unreachable from yams_network (from prowlarr)
#      and only the three hub containers sit on the internal yams_hub_ctl network
#   2. port 8090 listens on 0.0.0.0 only, never on [::]
#   3. no key, token, password or hash in the Config.Env of the hub containers
#   4. the gateway's /host/proc/1/net/dev shows the host NICs; /sys/class/hwmon has coretemp
#   5. GET /api/v1/health: docker up (proxy self-test passed) and shelfmark up
#   6. Config.OpenStdin is false for every running container
#   7. /api/v1/ping answers on the LAN URL and on the Tailscale URL
set -euo pipefail

HUB_URL=http://192.168.10.183:8090
TAILSCALE_URL=''
HUB_USER=admin
skip_health=0
SECRETS_DIR=${YAMS_SECRETS_DIR:-/opt/yams/monitoring/secrets}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}
HUB_UID=64090
HUB_CONTAINERS=(yams-hub socket-proxy-hub yams-hub-updater)

usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case "$1" in
    --hub-url)
      HUB_URL=${2:?--hub-url needs a value}
      shift 2
      ;;
    --tailscale-url)
      TAILSCALE_URL=${2:?--tailscale-url needs a value}
      shift 2
      ;;
    --user)
      HUB_USER=${2:?--user needs a value}
      shift 2
      ;;
    --skip-health)
      skip_health=1
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
done
HUB_URL=${HUB_URL%/}
TAILSCALE_URL=${TAILSCALE_URL%/}

if [[ -t 1 ]]; then
  green=$'\e[32m' red=$'\e[31m' yellow=$'\e[33m' reset=$'\e[0m'
else
  green='' red='' yellow='' reset=''
fi
passes=0 fails=0 skips=0
pass() {
  passes=$((passes + 1))
  printf '%sPASS%s %s\n' "$green" "$reset" "$*"
}
fail() {
  fails=$((fails + 1))
  printf '%sFAIL%s %s\n' "$red" "$reset" "$*"
}
skip() {
  skips=$((skips + 1))
  printf '%sSKIP%s %s\n' "$yellow" "$reset" "$*"
}
note() { printf '     %s\n' "$*"; }

command -v docker >/dev/null || {
  echo 'docker not found' >&2
  exit 1
}
have_curl=0
command -v curl >/dev/null && have_curl=1

running() { [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true) == true ]]; }

# --- 1. control plane isolation ---------------------------------------------------------------
check_isolation() {
  local ok=1 name ips ip nets target
  if ! running prowlarr; then
    fail '1 isolation: prowlarr is not running, cannot test from yams_network'
    return
  fi
  for target in http://socket-proxy-hub:2375/_ping http://yams-hub-updater:8080/healthz; do
    if docker exec prowlarr curl -s -m 3 -o /dev/null "$target" 2>/dev/null; then
      fail "1 isolation: prowlarr reached $target"
      ok=0
    fi
  done
  # By IP as well (DNS isolation alone would not be enough).
  for name in socket-proxy-hub yams-hub-updater; do
    ips=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$name" 2>/dev/null || true)
    # shellcheck disable=SC2086 # word splitting intended: one address per network
    for ip in $ips; do
      local port=2375 path=/_ping
      [[ $name == yams-hub-updater ]] && port=8080 path=/healthz
      if docker exec prowlarr curl -s -m 3 -o /dev/null "http://$ip:$port$path" 2>/dev/null; then
        fail "1 isolation: prowlarr reached $name by IP ($ip)"
        ok=0
      fi
    done
  done
  # Networks: proxy and updater only on yams_hub_ctl, which is internal and holds only the hub trio.
  for name in socket-proxy-hub yams-hub-updater; do
    nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$name" 2>/dev/null || true)
    nets=${nets% }
    if [[ -z $nets ]]; then
      fail "1 isolation: $name is not running"
      ok=0
    elif [[ $nets == *' '* || $nets != *yams_hub_ctl ]]; then
      fail "1 isolation: $name is attached to: $nets (expected only yams_hub_ctl)"
      ok=0
    fi
  done
  local ctl
  ctl=$(docker network ls --format '{{.Name}}' | grep -E '(^|_)yams_hub_ctl$' | head -n1 || true)
  if [[ -z $ctl ]]; then
    fail '1 isolation: no yams_hub_ctl network'
    ok=0
  else
    if [[ $(docker network inspect -f '{{.Internal}}' "$ctl") != true ]]; then
      fail "1 isolation: $ctl is not internal"
      ok=0
    fi
    local members expected
    members=$(docker network inspect -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$ctl" | sed '/^$/d' | sort | tr '\n' ' ')
    expected=$(printf '%s\n' "${HUB_CONTAINERS[@]}" | sort | tr '\n' ' ')
    if [[ $members != "$expected" ]]; then
      fail "1 isolation: $ctl members are: ${members:-none} (expected: $expected)"
      ok=0
    fi
  fi
  if ((ok)); then pass '1 isolation: socket-proxy-hub and the updater are unreachable from yams_network'; fi
}

# --- 2. IPv4-only publishing ------------------------------------------------------------------
check_ports() {
  local ok=1 lines mapping
  mapping=$(docker port yams-hub 8080/tcp 2>/dev/null || true)
  if [[ -z $mapping ]]; then
    fail '2 ports: yams-hub publishes nothing on 8080/tcp'
    return
  fi
  while IFS= read -r line; do
    [[ $line == 0.0.0.0:8090 ]] || {
      fail "2 ports: unexpected mapping $line"
      ok=0
    }
  done <<<"$mapping"
  if command -v ss >/dev/null; then
    lines=$(ss -Hltn 'sport = :8090' 2>/dev/null || true)
    if ! grep -q '0\.0\.0\.0:8090' <<<"$lines"; then
      fail '2 ports: nothing listens on 0.0.0.0:8090'
      ok=0
    fi
    if grep -qE '\[::\]:8090|\*:8090' <<<"$lines"; then
      fail '2 ports: 8090 also listens on IPv6 ([::]:8090)'
      ok=0
    fi
  else
    note 'ss not found; checked the docker port mapping only'
  fi
  if ((ok)); then pass '2 ports: 8090 is published on 0.0.0.0 only (no [::]:8090)'; fi
  note 'also check from outside the LAN: an IPv6 connection to the NAS global address on 8090 must fail'
}

# --- 3. no secrets in Config.Env --------------------------------------------------------------
check_env() {
  local ok=1 name env_dump var secrets line key value
  for name in "${HUB_CONTAINERS[@]}"; do
    if ! env_dump=$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null); then
      fail "3 env: cannot inspect $name"
      ok=0
      continue
    fi
    while IFS= read -r line; do
      [[ -z $line ]] && continue
      var=${line%%=*}
      case "$var" in
        YAMS_HUB_SECRETS_FILE | UPDATER_TOKEN_FILE | PATH | SSL_CERT_FILE) continue ;;
      esac
      # Permission flags such as the socket proxy image's own SECRETS=0 / AUTH=0 are not secrets.
      [[ ${line#*=} =~ ^[01]?$ ]] && continue
      if [[ $var =~ (KEY|TOKEN|PASS|SECRET|HASH|CREDENTIAL) ]]; then
        fail "3 env: $name has $var in Config.Env"
        ok=0
      fi
    done <<<"$env_dump"
    # Compare with the real values (read through a pipe, never printed).
    if [[ $name == yams-hub && -e $SECRETS_DIR/yams-hub.env ]]; then
      secrets=$(docker run --rm --network none --user "$HUB_UID:$HUB_UID" \
        -v "$SECRETS_DIR/yams-hub.env:/f:ro" "$ALPINE_IMAGE" cat /f 2>/dev/null || true)
      while IFS= read -r line; do
        [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'(.*)\'$ ]] || continue
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        ((${#value} >= 8)) || continue
        if [[ $env_dump == *"$value"* ]]; then
          fail "3 env: the value of $key appears in the Config.Env of $name"
          ok=0
        fi
      done <<<"$secrets"
      secrets='' value=''
    fi
  done
  if ((ok)); then pass '3 env: no key, token, password or hash in the Config.Env of the hub containers'; fi
}

# --- 4. host NIC counters and hwmon -----------------------------------------------------------
check_host_mounts() {
  local ok=1 inside host_ifaces in_ifaces hw
  if ! running yams-hub; then
    fail '4 host: yams-hub is not running'
    return
  fi
  # A throwaway container with exactly the gateway's mounts (the gateway image has no shell).
  inside=$(docker run --rm --network none --user "$HUB_UID:$HUB_UID" --volumes-from yams-hub:ro \
    "$ALPINE_IMAGE" cat /host/proc/1/net/dev 2>/dev/null || true)
  in_ifaces=" $(awk -F: 'NR > 2 {gsub(/ /, "", $1); print $1}' <<<"$inside" | sort | tr '\n' ' ')"
  host_ifaces=" $(awk -F: 'NR > 2 {gsub(/ /, "", $1); print $1}' /proc/net/dev 2>/dev/null | sort | tr '\n' ' ')"
  # The probe container has --network none: its own netns has only lo, so eth0 and docker0
  # prove the single-file bind shows the HOST network namespace.
  local want
  for want in eth0 docker0; do
    if [[ $host_ifaces == *" $want "* && $in_ifaces != *" $want "* ]]; then
      fail "4 host: /host/proc/1/net/dev does not list $want (sees:${in_ifaces:- nothing})"
      ok=0
    fi
  done
  if ((!ok)); then
    note 'fallback (ARCHITECTURE §6): mount /proc:/host/proc:ro, keep HOST_NET_DEV=/host/proc/1/net/dev, record it'
  fi
  if [[ $host_ifaces != *' tailscale0 '* ]]; then
    note 'tailscale0 does not exist on the host yet (Tailscale logged out); re-run after logging in'
  elif [[ $in_ifaces != *' tailscale0 '* ]]; then
    fail '4 host: tailscale0 is missing from /host/proc/1/net/dev'
    ok=0
  fi
  hw=$(docker run --rm --network none --user "$HUB_UID:$HUB_UID" "$ALPINE_IMAGE" \
    sh -c 'cat /sys/class/hwmon/*/name' 2>/dev/null || true)
  if ! grep -qx coretemp <<<"$hw"; then
    fail '4 host: /sys/class/hwmon/*/name has no coretemp inside a container'
    ok=0
  fi
  if ((ok)); then pass "4 host: host NIC counters (${in_ifaces# }) and coretemp visible in containers"; fi
}

# --- 5. /api/v1/health --------------------------------------------------------------------------
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

health_status() { # json service-id -> status
  if command -v jq >/dev/null; then
    jq -r --arg id "$2" '.services[]? | select(.id == $id) | .status' <<<"$1" | head -n1
  else
    grep -oP "\\{\"id\":\"$2\"[^{}]*" <<<"$1" | grep -oP '"status":"\K[a-zA-Z]+' | head -n1 || true
  fi
}

check_health() {
  if ((skip_health)); then
    skip '5 health: --skip-health'
    return
  fi
  if ((!have_curl)); then
    fail '5 health: curl not found on the host'
    return
  fi
  local token=${YAMS_HUB_TOKEN:-} logged_in=0 password body json docker_s shelf_s
  if [[ -z $token ]]; then
    if [[ ! -t 0 ]]; then
      skip '5 health: no terminal for the password prompt (set YAMS_HUB_TOKEN or use --skip-health)'
      return
    fi
    IFS= read -rsp "Hub password for $HUB_USER (check 5): " password
    printf '\n'
    [[ $password != *[[:cntrl:]]* ]] || {
      fail '5 health: the password contains control characters'
      return
    }
    # Credentials go through stdin, never argv.
    body=$(printf '{"username":"%s","password":"%s","deviceName":"verify.sh","platform":"other","transport":"token"}' \
      "$(json_escape "$HUB_USER")" "$(json_escape "$password")" |
      curl -sS -m 15 -H 'content-type: application/json' --data-binary @- "$HUB_URL/api/v1/auth/login" 2>/dev/null || true)
    password=''
    token=$(grep -oP '"accessToken":"\K[^"]+' <<<"$body" || true)
    body=''
    if [[ -z $token ]]; then
      fail "5 health: login as $HUB_USER failed"
      return
    fi
    logged_in=1
  fi
  json=$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS -m 60 -K - "$HUB_URL/api/v1/health" 2>/dev/null || true)
  if ((logged_in)); then
    printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl -sS -m 10 -K - -X POST -o /dev/null "$HUB_URL/api/v1/auth/logout" 2>/dev/null || true
  fi
  token=''
  docker_s=$(health_status "$json" docker)
  shelf_s=$(health_status "$json" shelfmark)
  if [[ $docker_s == up && $shelf_s == up ]]; then
    pass '5 health: docker up (proxy self-test passed), shelfmark up'
  else
    fail "5 health: docker ${docker_s:-unknown}, shelfmark ${shelf_s:-unknown} (both must be up)"
  fi
  if command -v jq >/dev/null && [[ -n $json ]]; then
    note "services: $(jq -r '[.services[]? | "\(.id)=\(.status)"] | join(" ")' <<<"$json")"
  fi
}

# --- 6. OpenStdin -----------------------------------------------------------------------------
check_open_stdin() {
  local ids open
  mapfile -t ids < <(docker ps -q)
  if ((${#ids[@]} == 0)); then
    fail '6 stdin: no running containers'
    return
  fi
  open=$(docker inspect --format '{{.Name}} {{.Config.OpenStdin}}' "${ids[@]}" | awk '$2 != "false" {sub(/^\//, "", $1); print $1}' | tr '\n' ' ')
  if [[ -n $open ]]; then
    fail "6 stdin: Config.OpenStdin is true for: $open(attach/ws residual, ARCHITECTURE §5.16)"
  else
    pass "6 stdin: Config.OpenStdin is false for all ${#ids[@]} running containers"
  fi
}

# --- 7. /api/v1/ping on LAN and Tailscale -----------------------------------------------------
ping_ok() { curl -fsS -m 5 "$1/api/v1/ping" 2>/dev/null | grep -q '"name":"yams-hub"'; }

check_ping() {
  if ((!have_curl)); then
    fail '7 ping: curl not found on the host'
    return
  fi
  local ok=1 ts_ip
  if ping_ok "$HUB_URL"; then
    note "ping OK on $HUB_URL"
  else
    fail "7 ping: no answer on $HUB_URL/api/v1/ping"
    ok=0
  fi
  if [[ -z $TAILSCALE_URL ]]; then
    ts_ip=$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}' || true)
    [[ -n $ts_ip ]] && TAILSCALE_URL="http://$ts_ip:8090"
  fi
  if [[ -z $TAILSCALE_URL ]]; then
    skip '7 ping: Tailscale is not up on the NAS (no tailscale0); re-run with --tailscale-url after logging in'
    return
  fi
  if ping_ok "$TAILSCALE_URL"; then
    note "ping OK on $TAILSCALE_URL"
  else
    fail "7 ping: no answer on $TAILSCALE_URL/api/v1/ping"
    ok=0
  fi
  if ((ok)); then pass "7 ping: answers on $HUB_URL and $TAILSCALE_URL"; fi
}

check_isolation
check_ports
check_env
check_host_mounts
check_health
check_open_stdin
check_ping

printf '\n%d passed, %d failed, %d skipped\n' "$passes" "$fails" "$skips"
((fails == 0))
