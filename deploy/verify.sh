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
#   1. the control plane refuses everyone but the gateway: from prowlarr (yams_network; it must
#      first reach the hub's own ping, so a broken probe cannot pass) and from the host,
#      socket-proxy-hub drops the connection (haproxy source ACL) and the updater says 403
#      (UPDATER_ALLOWED_SOURCES) or drops it; the proxy's rendered config binds :2375 with exactly
#      one `acl from_hub src 172.30.250.2 127.0.0.1` and the reject rule; yams_yams_hub_ctl has
#      172.30.250.0/29, the hub trio has its fixed addresses and is alone on it, and no container
#      shares a hub container's network namespace. `internal: true` is NOT relied upon (UGOS's
#      DOCKER-USER ACCEPT defeats it). The gateway's own path through both is proven by check 5.
#   2. port 8090 listens on 0.0.0.0 only, never on [::]
#   3. no key, token, password or hash in the Config.Env of the hub containers
#   4. the gateway's /host/proc/1/net/dev shows the host NICs; /sys/class/hwmon has coretemp
#   5. GET /api/v1/health: docker up (proxy reached and self-test passed), updater up and shelfmark up
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
# Must match deploy/docker-compose.hub.yaml and deploy.sh (deploy/test/deploy_test.sh checks it).
CTL_NET=yams_yams_hub_ctl
HUB_CTL_SUBNET=172.30.250.0/29
HUB_CTL_GATEWAY_IP=172.30.250.2
HUB_CTL_PROXY_IP=172.30.250.3
HUB_CTL_UPDATER_IP=172.30.250.4
HUB_LAN_IP=172.28.0.49

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"; }

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
# On Zenith, UGOS's `DOCKER-USER ! -i docker0 ! -o docker0 -j ACCEPT` lets every container route to
# yams_hub_ctl by IP, so this probes what actually answers instead of trusting `internal: true`.

# probe URL CURL...: runs CURL... (curl, or docker exec <c> curl) on URL and prints
# "<curl exit> <http status>" (status 000 = no HTTP response at all).
probe() {
  local url=$1 code rc=0
  shift
  code=$("$@" -s -m 3 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || rc=$?
  printf '%s %s\n' "$rc" "${code:-000}"
}
# refused RC CODE URL: the probe got no HTTP answer because the peer refused or dropped it (curl 7:
# connect failed, 28: timeout, 52: empty reply, 56: reset), or, for a by-name URL, because the name
# does not resolve there (6). Anything else (126/127: curl missing, exec failed) proves nothing.
refused() {
  [[ $2 == 000 ]] || return 1
  case $1 in
    7 | 28 | 52 | 56) return 0 ;;
    6) [[ $3 != http://[0-9]* ]] ;;
    *) return 1 ;;
  esac
}
ctl_ip() { docker inspect -f "{{with index .NetworkSettings.Networks \"$CTL_NET\"}}{{.IPAddress}}{{end}}" "$1" 2>/dev/null || true; }

check_isolation() {
  local ok=1 name nets rc code where
  # Layout: the fixed addresses the source ACLs are written for.
  local subnet
  subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$CTL_NET" 2>/dev/null || true)
  subnet=${subnet% }
  if [[ -z $subnet ]]; then
    fail "1 isolation: no network $CTL_NET"
    return
  fi
  if [[ $subnet != "$HUB_CTL_SUBNET" ]]; then
    fail "1 isolation: $CTL_NET has subnet $subnet, expected $HUB_CTL_SUBNET (deploy.sh --migrate-ctl-network)"
    ok=0
  fi
  local -A want=([yams-hub]=$HUB_CTL_GATEWAY_IP [socket-proxy-hub]=$HUB_CTL_PROXY_IP [yams-hub-updater]=$HUB_CTL_UPDATER_IP)
  for name in "${HUB_CONTAINERS[@]}"; do
    local got
    got=$(ctl_ip "$name")
    if [[ $got != "${want[$name]}" ]]; then
      fail "1 isolation: $name has ${got:-no address} on $CTL_NET, expected ${want[$name]}"
      ok=0
    fi
  done
  local lan
  lan=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{if ne $k "'"$CTL_NET"'"}}{{$v.IPAddress}} {{end}}{{end}}' yams-hub 2>/dev/null || true)
  if [[ ${lan% } != "$HUB_LAN_IP" ]]; then
    fail "1 isolation: yams-hub has ${lan:-no address} outside $CTL_NET, expected only $HUB_LAN_IP"
    ok=0
  fi
  # Proxy and updater only on the control network, which holds only the hub trio.
  for name in socket-proxy-hub yams-hub-updater; do
    nets=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$name" 2>/dev/null || true)
    nets=${nets% }
    if [[ -z $nets ]]; then
      fail "1 isolation: $name is not running"
      ok=0
    elif [[ $nets != "$CTL_NET" ]]; then
      fail "1 isolation: $name is attached to: $nets (expected only $CTL_NET)"
      ok=0
    fi
  done
  local members expected
  members=$(docker network inspect -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' "$CTL_NET" | sed '/^$/d' | sort | tr '\n' ' ')
  expected=$(printf '%s\n' "${HUB_CONTAINERS[@]}" | sort | tr '\n' ' ')
  if [[ $members != "$expected" ]]; then
    fail "1 isolation: $CTL_NET members are: ${members:-none} (expected: $expected)"
    ok=0
  fi
  # The rendered proxy config carries the ACL (a template mount that did not take is caught here),
  # binds plain IPv4 (DISABLE_IPV6 honoured: with a v4v6 bind, IPv4 patterns also match some IPv6
  # sources), and has exactly one from_hub line (haproxy ORs them) with exactly these sources.
  local rendered gw_rx=${HUB_CTL_GATEWAY_IP//./\\.}
  rendered=$(docker exec socket-proxy-hub cat /run/haproxy/haproxy.cfg 2>/dev/null || true)
  if [[ -z $rendered ]]; then
    fail '1 isolation: cannot read /run/haproxy/haproxy.cfg in socket-proxy-hub (not running?)'
    ok=0
  else
    if ! grep -qE '^[[:space:]]*tcp-request connection reject if !from_hub([[:space:]]+#.*)?$' <<<"$rendered"; then
      fail '1 isolation: /run/haproxy/haproxy.cfg in socket-proxy-hub has no source ACL reject rule (template mount?)'
      ok=0
    fi
    if [[ $(grep -cE '^[[:space:]]*acl[[:space:]]+from_hub([[:space:]]|$)' <<<"$rendered" || true) != 1 ]] ||
      ! grep -qE "^[[:space:]]*acl from_hub src $gw_rx 127\.0\.0\.1([[:space:]]+#.*)?\$" <<<"$rendered"; then
      fail "1 isolation: /run/haproxy/haproxy.cfg needs exactly one 'acl from_hub src $HUB_CTL_GATEWAY_IP 127.0.0.1'"
      ok=0
    fi
    if [[ $(grep -cE '^[[:space:]]*bind[[:space:]]' <<<"$rendered" || true) != 1 ]] ||
      ! grep -qE '^[[:space:]]*bind :2375[[:space:]]*$' <<<"$rendered"; then
      fail "1 isolation: socket-proxy-hub does not bind exactly ':2375' ($(grep -E '^[[:space:]]*bind[[:space:]]' <<<"$rendered" | sed 's/^[[:space:]]*//' | tr '\n' ';')) - DISABLE_IPV6=1 not honoured?"
      ok=0
    fi
  fi
  # A container in a hub container's network namespace (network_mode: container:...) would come from
  # 172.30.250.2, or from the updater's always-allowed loopback; it is not listed as a network member.
  local -A hub_ids=()
  local id mode
  for name in "${HUB_CONTAINERS[@]}"; do
    id=$(docker inspect -f '{{.Id}}' "$name" 2>/dev/null || true)
    if [[ -n $id ]]; then hub_ids[$name]=$id; fi
  done
  while read -r name mode; do
    [[ $mode == container:* ]] || continue
    local peer=${mode#container:} hub
    for hub in "${!hub_ids[@]}"; do
      if [[ $peer == "$hub" || $peer == "${hub_ids[$hub]}" || (${#peer} -ge 12 && ${hub_ids[$hub]} == "$peer"*) ]]; then
        fail "1 isolation: ${name#/} shares the network namespace of $hub (network_mode container:), so it passes the source ACLs"
        ok=0
      fi
    done
  done < <(docker ps -aq | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.NetworkMode}}' 2>/dev/null || true)

  # Reachability, from a container on yams_network and from the host (the bridge gateway .1).
  local -a from=()
  if ! running prowlarr; then
    fail '1 isolation: prowlarr is not running, cannot test from yams_network'
    ok=0
  else
    # Positive control: the same probe must reach the hub on yams_network, or a failing
    # `docker exec prowlarr curl` (curl gone after an image bump, prowlarr restarting) would pass.
    read -r rc code < <(probe "http://$HUB_LAN_IP:8080/api/v1/ping" docker exec prowlarr curl)
    if [[ $code == 200 ]]; then
      from+=(prowlarr)
    else
      fail "1 isolation: cannot probe from prowlarr (its curl got exit $rc, HTTP $code from the hub's own http://$HUB_LAN_IP:8080/api/v1/ping)"
      ok=0
    fi
  fi
  if ((have_curl)); then from+=(host); else note 'curl not found on the host; probed from prowlarr only'; fi
  for where in ${from[@]+"${from[@]}"}; do
    local -a curl_cmd=(curl)
    [[ $where == host ]] || curl_cmd=(docker exec "$where" curl)
    local target
    for target in "http://$HUB_CTL_PROXY_IP:2375/_ping" "http://$HUB_CTL_PROXY_IP:2375/containers/json" \
      http://socket-proxy-hub:2375/_ping; do
      read -r rc code < <(probe "$target" "${curl_cmd[@]}")
      # A refused connection never gets an HTTP status.
      if [[ $code != 000 ]]; then
        fail "1 isolation: $where reached socket-proxy-hub ($target answered HTTP $code)"
        ok=0
      elif ! refused "$rc" "$code" "$target"; then
        fail "1 isolation: probing $target from $where failed with curl exit $rc, which proves nothing"
        ok=0
      fi
    done
    for target in "http://$HUB_CTL_UPDATER_IP:8080/healthz" "http://$HUB_CTL_UPDATER_IP:8080/services" \
      http://yams-hub-updater:8080/healthz; do
      read -r rc code < <(probe "$target" "${curl_cmd[@]}")
      # 403 = UPDATER_ALLOWED_SOURCES refused it before the token; 000 = no connection at all.
      # 401 would mean only the token stands in the way.
      if [[ $code == 000 ]]; then
        if ! refused "$rc" "$code" "$target"; then
          fail "1 isolation: probing $target from $where failed with curl exit $rc, which proves nothing"
          ok=0
        fi
      elif [[ $code != 403 ]]; then
        fail "1 isolation: $where got HTTP $code from the updater ($target; expected 403 or no connection)"
        ok=0
      fi
    done
  done
  if ((ok)); then
    pass "1 isolation: socket-proxy-hub and the updater refuse ${from[*]:-nobody tested} (source ACLs; $CTL_NET has the fixed $HUB_CTL_SUBNET layout)"
  fi
  if ((skip_health)); then
    note "the gateway's own access to both (from $HUB_CTL_GATEWAY_IP) is NOT verified: check 5 is skipped"
  else
    note "the gateway's own access to both (from $HUB_CTL_GATEWAY_IP) is check 5: docker=up and updater=up"
  fi
  note "not relied upon: internal: true (UGOS's DOCKER-USER ACCEPT bypasses it), and $CTL_NET has internet egress"
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
  local token=${YAMS_HUB_TOKEN:-} logged_in=0 password body json docker_s shelf_s updater_s
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
  updater_s=$(health_status "$json" updater)
  shelf_s=$(health_status "$json" shelfmark)
  # docker=up: the gateway got through socket-proxy-hub's source ACL and the self-test passed;
  # updater=up: its GET /healthz passed UPDATER_ALLOWED_SOURCES and the token check.
  if [[ $docker_s == up && $updater_s == up && $shelf_s == up ]]; then
    pass '5 health: docker up (proxy reached through its source ACL, self-test passed), updater up (source allow-list and token accepted), shelfmark up'
  else
    fail "5 health: docker ${docker_s:-unknown}, updater ${updater_s:-unknown}, shelfmark ${shelf_s:-unknown} (all must be up)"
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
