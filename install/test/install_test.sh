#!/usr/bin/env bash
# Tests for install.sh without a server: a fake `docker` (fake_docker.sh) with a stock YAMS install in a temp dir,
# plus fake ip, ss, df, curl and sleep.
#
#   bash install/test/install_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

pass=0 fail=0
failed=()

# --- fixture --------------------------------------------------------------------------------------
bin="$work/bin"
mkdir -p "$bin"
cp "$HERE/fake_docker.sh" "$bin/docker"
cat >"$bin/ip" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' route get '*) echo '1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.10 uid 1000' ;;
  *) cat "$FAKE_DOCKER_STATE/routes" 2>/dev/null || true ;;
esac
SH
cat >"$bin/ss" <<'SH'
#!/usr/bin/env bash
cat "$FAKE_DOCKER_STATE/listening" 2>/dev/null || true
SH
cat >"$bin/df" <<'SH'
#!/usr/bin/env bash
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo "/dev/sdb1 1000 500 500 50% ${!#}"
SH
cat >"$bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >>"$FAKE_DOCKER_STATE/calls"
[[ ! -e $FAKE_DOCKER_STATE/ping_fails ]]
SH
printf '#!/bin/sh\nexit 0\n' >"$bin/sleep"
printf '#!/bin/sh\necho MediaBox\n' >"$bin/hostname"
chmod +x "$bin"/*

# A repo copy with a web build (install.sh and the files it reads).
repo="$work/repo"
mkdir -p "$repo/install" "$repo/deploy/socket-proxy-hub" "$repo/app/build/web" "$repo/gateway" "$repo/updater"
cp "$REPO/install.sh" "$repo/"
cp "$REPO/install/compose.yaml" "$repo/install/"
cp "$REPO/deploy/socket-proxy-hub/haproxy.cfg" "$repo/deploy/socket-proxy-hub/"
echo '<!doctype html>' >"$repo/app/build/web/index.html"

SONARR_KEY=0123456789abcdef0123456789abcdef
RADARR_KEY=abcdefabcdefabcdefabcdefabcdef01
PROWLARR_KEY=fedcba9876543210fedcba9876543210
BAZARR_KEY=b4a2a7c0ffee0000b4a2a7c0ffee0000
SEERR_KEY=MTczMDAwMDAwMDAwMGFiY2RlZjEyMzQ1Ng==
PASSWORD='correct horse battery'

# container NAME [STATE]: a YAMS container on yams_network with the compose labels.
container() {
  local n=$1 d=$st/c/$1
  mkdir -p "$d"
  echo "${2:-running}" >"$d/state"
  echo "yams|$yams|$yams/docker-compose.yaml,$yams/docker-compose.custom.yaml" >"$d/labels"
  echo yams_network >"$d/networks"
  echo yams_network >"$d/netmode"
  echo "/config $media/config/$n" >"$d/mounts"
  echo "$n 172.28.0.$((10 + $(find "$st/c" -mindepth 1 -maxdepth 1 | wc -l)))/24" >>"$st/nets/yams_network.containers"
}

# new_case: a stock YAMS install (core services, VPN on) with config files; sets $st, $yams, $media.
new_case() {
  local c="$work/case$((pass + fail))"
  rm -rf "$c"
  st="$c/docker" yams="$c/opt/yams" media="$c/media"
  mkdir -p "$st/c" "$st/nets" "$yams" "$media/config"
  export FAKE_DOCKER_STATE=$st
  cat >"$yams/.env" <<EOF
PUID=1000
PGID=1000
MEDIA_DIRECTORY=$media
INSTALL_DIRECTORY=$yams
MEDIA_SERVICE=jellyfin
TZ="Africa/Johannesburg"
VPN_ENABLED=y
EOF
  cat >"$yams/docker-compose.yaml" <<'EOF'
services:
  sonarr:
    networks:
      yams_network:
        ipv4_address: 172.28.0.13
  watchtower:
    networks:
      yams_network:
        ipv4_address: 172.28.0.250
EOF
  echo 172.28.0.0/24 >"$st/nets/yams_network.subnet"
  echo 172.28.0.1 >"$st/nets/yams_network.gateway"
  echo 172.17.0.0/16 >"$st/nets/bridge.subnet"
  for n in sonarr radarr prowlarr bazarr jellyfin gluetun qbittorrent sabnzbd portainer watchtower; do container "$n"; done
  echo 'homepage 172.28.0.249/24' >>"$st/nets/yams_network.containers" # a user's extra with a high address
  echo "container:cid-gluetun" >"$st/c/qbittorrent/netmode"
  # Stock YAMS gives jellyfin no `networks:` key, so compose puts it on the project's default network.
  echo 172.18.0.0/16 >"$st/nets/yams_default.subnet"
  echo yams_default >"$st/c/jellyfin/networks"
  echo yams_default >"$st/c/jellyfin/netmode"
  printf 'PUID=1000\nWEBUI_PORT=8081\n' >"$st/c/qbittorrent/env"
  local svc key
  for svc in sonarr radarr prowlarr; do
    key=${svc^^}_KEY
    mkdir -p "$media/config/$svc"
    printf '<Config>\n  <Port>8989</Port>\n  <ApiKey>%s</ApiKey>\n</Config>\n' "${!key}" >"$media/config/$svc/config.xml"
  done
  mkdir -p "$media/config/bazarr/config"
  printf 'general:\n  apikey: wrong\nauth:\n  type: null\n  apikey: %s\n  password: ""\n' "$BAZARR_KEY" \
    >"$media/config/bazarr/config/config.yaml"
}

# Answers of a first run on the stock fixture, one per line: Jellyfin key, qBittorrent user and password,
# port, admin username, admin password.
first_answers() { printf '%s\n' jellyfin-key-1 qbuser 'qb pass' '' '' "$PASSWORD"; }

install() { # ARGS... (stdin: the answers)
  set +e
  out=$(cd "$repo" && PATH="$bin:$PATH" bash ./install.sh "$@" 2>&1)
  status=$?
  set -e
  printf '%s\n' "$out" >"$work/out"
}

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
hubfile() { cat "$yams/yams-hub/$1" 2>/dev/null || true; }

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
    printf '    --- install output ---\n'
    sed 's/^/    /' "$work/out" 2>/dev/null || true
  fi
}

# --- tests ----------------------------------------------------------------------------------------
test_first_install_on_stock_yams() {
  install <<<"$(first_answers)"
  local compose env updater
  compose=$(hubfile compose.yaml) env=$(hubfile secrets/yams-hub.env) updater=$(hubfile secrets/updater.env)
  check 'exit 0' test "$status" -eq 0
  check 'own project' contains "$(calls)" "compose -p yams-hub -f $yams/yams-hub/compose.yaml up -d"
  check 'built the gateway' contains "$(calls)" "build -f $repo/gateway/Dockerfile -t yams-hub:latest $repo"
  check 'built the updater' contains "$(calls)" "build -f $repo/updater/Dockerfile -t yams-hub-updater:latest $repo/updater"
  check 'pulled the pinned proxy' contains "$(calls)" 'pull lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105@sha256:823dda97'
  # detection
  check 'sonarr' contains "$compose" '- SONARR_URL=http://sonarr:8989'
  check 'qbittorrent via gluetun' contains "$compose" '- QBIT_URL=http://gluetun:8081'
  check 'gluetun' contains "$compose" '- GLUETUN_URL=http://gluetun:8000'
  check 'jellyfin' contains "$compose" '- JELLYFIN_URL=http://jellyfin:8096'
  check 'no seerr' grep -qx '      - SEERR_URL=' <<<"$compose"
  check 'no jellystat' grep -qx '      - JELLYSTAT_URL=' <<<"$compose"
  check 'watchtower off' grep -qx '      - WATCHTOWER_URL=' <<<"$compose"
  check 'no uptime kuma' grep -qx '      - UPTIME_KUMA_URL=' <<<"$compose"
  # rendering
  check 'external YAMS network' contains "$compose" $'    external: true\n    name: yams_network'
  check 'joins yams_default for jellyfin' contains "$compose" $'  net_yams_default:\n    external: true\n    name: yams_default'
  check 'hub on yams_default' contains "$compose" $'        ipv4_address: 172.28.0.248\n      net_yams_default: {}'
  check 'fixed control subnet' contains "$compose" '- subnet: 172.30.250.0/29'
  check 'free high address (not .250 of the compose file, not .249 in use)' contains "$compose" $'      yams:\n        ipv4_address: 172.28.0.248'
  check 'volume label' contains "$compose" "- HOST_VOLUME_MOUNT=$media"
  check 'disk device' contains "$compose" '- HOST_DISK_DEVICE=sdb1'
  check 'TZ from .env' contains "$compose" '- TZ=Africa/Johannesburg'
  check 'TZ offset' contains "$compose" '- YAMS_HUB_TZ_OFFSET=+02:00'
  check 'port' contains "$compose" '"0.0.0.0:8090:8080"'
  check 'host name allowed' contains "$compose" '- YAMS_HUB_ALLOWED_HOSTS=mediabox,mediabox.local'
  check 'data dir' contains "$compose" "- $media/config/yams-hub:/data"
  check 'updater project' contains "$compose" '- UPDATER_PROJECT_NAME=yams'
  check 'updater dir' contains "$compose" "- UPDATER_PROJECT_DIR=$yams"
  check 'only existing compose files' grep -qx "      - UPDATER_COMPOSE_FILES=$yams/docker-compose.yaml" <<<"$compose"
  check 'warned about the missing custom file' contains "$out" 'docker-compose.custom.yaml is in'
  check 'YAMS dir read-only' contains "$compose" "- $yams:$yams:ro"
  check 'no recyclarr mount' not_contains "$compose" 'recyclarr'
  check 'no placeholder left' not_contains "$compose" '@@'
  check 'haproxy cfg installed' cmp -s "$repo/deploy/socket-proxy-hub/haproxy.cfg" "$yams/yams-hub/socket-proxy-hub.haproxy.cfg"
  # secrets
  check 'sonarr key from config.xml' grep -qx "SONARR_API_KEY='$SONARR_KEY'" <<<"$env"
  check 'radarr key' grep -qx "RADARR_API_KEY='$RADARR_KEY'" <<<"$env"
  check 'prowlarr key' grep -qx "PROWLARR_API_KEY='$PROWLARR_KEY'" <<<"$env"
  check 'bazarr auth.apikey' grep -qx "BAZARR_API_KEY='$BAZARR_KEY'" <<<"$env"
  check 'jellyfin key entered' grep -qx "JELLYFIN_API_KEY='jellyfin-key-1'" <<<"$env"
  check 'qbit login' grep -qx "QBIT_USERNAME='qbuser'" <<<"$env"
  check 'qbit password with a space' grep -qx "QBIT_PASSWORD='qb pass'" <<<"$env"
  check 'admin username' grep -qx "YAMS_HUB_ADMIN_USERNAME='admin'" <<<"$env"
  check 'admin hash' grep -qx "YAMS_HUB_ADMIN_PASSWORD_HASH='pbkdf2-sha256\$600000\$c2FsdHNhbHQ\$aGFzaGhhc2g'" <<<"$env"
  check 'no jellyfin admin id (the gateway detects it)' not_contains "$env" JELLYFIN_ADMIN_USER_ID
  check 'updater token' grep -qE "^UPDATER_TOKEN='[A-Za-z0-9_-]{64}'$" <<<"$env"
  check 'same token for the updater' test "$(grep UPDATER_TOKEN <<<"$env")" == "$(grep UPDATER_TOKEN <<<"$updater")"
  check 'updater file has the token only' test "$(grep -vc '^#' <<<"$updater")" -eq 1
  check 'password hashed from stdin' grep -qx "hash-password stdin=${#PASSWORD}" "$st/hashed"
  check 'password not in argv' not_contains "$(calls)" "$PASSWORD"
  check 'no secret in argv' not_contains "$(calls)" "$SONARR_KEY"
  check 'no secret printed' not_contains "$out" "$SONARR_KEY"
  check 'password not printed' not_contains "$out" "$PASSWORD"
  check 'hub env owner' grep -q "chown 64090:64090 .*/secrets/yams-hub.env" "$st/chowns"
  check 'updater env owner' grep -q "chown 0:0 .*/secrets/updater.env" "$st/chowns"
  check 'data dir owner' grep -q "chown 64090:64090 $media/config/yams-hub" "$st/chowns"
  check 'hub env 0400' test "$(stat -c %a "$yams/yams-hub/secrets/yams-hub.env")" = 400
  check 'data dir 0700' test "$(stat -c %a "$media/config/yams-hub")" = 700
  check 'pinged' contains "$(calls)" 'curl -fsS -m 5 -o /dev/null http://127.0.0.1:8090/api/v1/ping'
  check 'prints the LAN URL' contains "$out" 'YAMS Hub is running: http://192.168.1.10:8090'
}

test_seerr_extras_and_no_vpn() {
  container jellyseerr
  container kavita
  container recyclarr
  container uptime-kuma
  echo 'services: {}' >"$yams/docker-compose.custom.yaml"
  echo "/app/config $media/config/jellyseerr" >"$st/c/jellyseerr/mounts"
  mkdir -p "$media/config/jellyseerr" "$media/config/recyclarr/logs"
  cat >"$media/config/jellyseerr/settings.json" <<EOF
{
  "clientId": "x",
  "main": {
    "apiKey": "$SEERR_KEY",
    "defaultQuotas": { "movie": {} }
  },
  "radarr": [ { "apiKey": "not-this-one" } ]
}
EOF
  # VPN disabled: no network_mode for qBittorrent, so it is on yams_default; gluetun is defined but restarts.
  sed -i 's/^VPN_ENABLED=.*/VPN_ENABLED=n/' "$yams/.env"
  echo yams_default >"$st/c/qbittorrent/netmode"
  echo yams_default >"$st/c/qbittorrent/networks"
  echo restarting >"$st/c/gluetun/state"
  printf 'WEBUI_PORT=8080\n' >"$st/c/qbittorrent/env"
  # Jellyfin key, qBittorrent user + password, Uptime Kuma slug, Kavita key, port, admin, password.
  install <<<"$(printf '%s\n' '' qbuser qbpass home kavita-key 9000 ada "$PASSWORD")"
  local compose env
  compose=$(hubfile compose.yaml) env=$(hubfile secrets/yams-hub.env)
  check 'exit 0' test "$status" -eq 0
  check 'seerr' contains "$compose" '- SEERR_URL=http://jellyseerr:5055'
  check 'seerr main.apiKey' grep -qx "SEERR_API_KEY='$SEERR_KEY'" <<<"$env"
  check 'qbittorrent direct' contains "$compose" '- QBIT_URL=http://qbittorrent:8080'
  check 'no gluetun without the VPN' grep -qx '      - GLUETUN_URL=' <<<"$compose"
  check 'joins yams_default once' test "$(grep -c '^  net_yams_default:' <<<"$compose")" -eq 1
  check 'kavita' contains "$compose" '- KAVITA_URL=http://kavita:5000'
  check 'kavita key' grep -qx "KAVITA_API_KEY='kavita-key'" <<<"$env"
  check 'uptime kuma slug' contains "$compose" '- UPTIME_KUMA_SLUG=home'
  check 'uptime kuma' contains "$compose" '- UPTIME_KUMA_URL=http://uptime-kuma:3001'
  check 'skipped jellyfin key' not_contains "$env" JELLYFIN_API_KEY
  check 'recyclarr logs' contains "$compose" "- $media/config/recyclarr/logs:/host/recyclarr-logs:ro"
  check 'both compose files' grep -qx "      - UPDATER_COMPOSE_FILES=$yams/docker-compose.yaml,$yams/docker-compose.custom.yaml" <<<"$compose"
  check 'port 9000' contains "$compose" '"0.0.0.0:9000:8080"'
  check 'admin ada' grep -qx "YAMS_HUB_ADMIN_USERNAME='ada'" <<<"$env"
}

test_rerun_keeps_secrets_without_prompts() {
  install <<<"$(first_answers)"
  check 'first run ok' test "$status" -eq 0
  local env1 env2
  env1=$(hubfile secrets/yams-hub.env)
  rm -f "$st/hashed"
  install </dev/null
  env2=$(hubfile secrets/yams-hub.env)
  check 'second run ok' test "$status" -eq 0
  check 'same secrets' test "$(grep -v '^#' <<<"$env1")" == "$(grep -v '^#' <<<"$env2")"
  check 'no new hash' test ! -e "$st/hashed"
  check 'same port' contains "$(hubfile compose.yaml)" '"0.0.0.0:8090:8080"'
  check 'no forced recreate' not_contains "$(calls)" '--force-recreate yams-hub'
}

test_update_rebuilds_and_recreates_the_hub_only() {
  install --update </dev/null
  check 'refused before an install' test "$status" -eq 1
  check 'says to install first' contains "$out" 'not installed yet'
  install <<<"$(first_answers)"
  : >"$st/calls"
  install --update </dev/null
  check 'exit 0' test "$status" -eq 0
  check 'rebuilt' contains "$(calls)" 'build -f'
  check 'up -d' contains "$(calls)" 'compose -p yams-hub'
  check 'kept the qbit login' grep -qx "QBIT_USERNAME='qbuser'" <<<"$(hubfile secrets/yams-hub.env)"
}

test_reconfigure_asks_again() {
  install <<<"$(first_answers)"
  # Jellyfin key: new value; qBittorrent user: keep; password: clear.
  : >"$st/calls"
  install --reconfigure <<<"$(printf '%s\n' jellyfin-key-2 '' -)"
  local env
  env=$(hubfile secrets/yams-hub.env)
  check 'exit 0' test "$status" -eq 0
  check 'new jellyfin key' grep -qx "JELLYFIN_API_KEY='jellyfin-key-2'" <<<"$env"
  check 'kept qbit user' grep -qx "QBIT_USERNAME='qbuser'" <<<"$env"
  check 'cleared qbit password' not_contains "$env" QBIT_PASSWORD
  check 'kept the admin' contains "$env" YAMS_HUB_ADMIN_PASSWORD_HASH
  check 'recreated the hub for the new key' contains "$(calls)" 'up -d --no-deps --force-recreate yams-hub'
  check 'updater left alone' not_contains "$(calls)" '--force-recreate yams-hub-updater'
}

test_control_subnet_overlap_aborts() {
  echo 172.30.250.0/24 >"$st/nets/vpn_net.subnet"
  install <<<"$(first_answers)"
  check 'exit 1' test "$status" -eq 1
  check 'names the network' contains "$out" 'vpn_net (172.30.250.0/24)'
  check 'nothing started' not_contains "$(calls)" ' up -d'
  check 'nothing written' test ! -e "$yams/yams-hub"
}

test_host_route_overlap_aborts() {
  echo '172.30.0.0/16 dev wg0 proto kernel scope link src 172.30.0.1' >"$st/routes"
  install <<<"$(first_answers)"
  check 'exit 1' test "$status" -eq 1
  check 'names the route' contains "$out" 'host route: 172.30.0.0/16 dev wg0'
  check 'nothing started' not_contains "$(calls)" ' up -d'
}

test_other_container_changed_fails_loudly() {
  echo sonarr >"$st/recreate_also"
  install <<<"$(first_answers)"
  check 'exit 1' test "$status" -eq 1
  check 'names sonarr' contains "$out" 'containers outside the hub changed: sonarr'
}

test_dry_run_changes_nothing() {
  install --dry-run </dev/null
  check 'exit 0' test "$status" -eq 0
  check 'shows the compose file' contains "$out" '- SONARR_URL=http://sonarr:8989'
  check 'lists the key source' grep -qE "SONARR_API_KEY +$media/config/sonarr/config.xml" <<<"$out"
  check 'no key printed' not_contains "$out" "$SONARR_KEY"
  check 'nothing written' test ! -e "$yams/yams-hub"
  check 'no build' not_contains "$(calls)" 'build -f'
  check 'no up' not_contains "$(calls)" 'compose -p'
}

test_needs_a_web_build() {
  mv "$repo/app/build/web/index.html" "$work/index.html"
  install <<<"$(first_answers)"
  mv "$work/index.html" "$repo/app/build/web/index.html"
  check 'exit 1' test "$status" -eq 1
  check 'says build.sh' contains "$out" './build.sh'
}

test_port_in_use_aborts() {
  echo 'LISTEN 0 4096 0.0.0.0:8090 0.0.0.0:*' >"$st/listening"
  install <<<"$(first_answers)"
  check 'exit 1' test "$status" -eq 1
  check 'says so' contains "$out" 'port 8090 is already in use'
}

test_emby_disables_jellyfin() {
  sed -i 's/^MEDIA_SERVICE=.*/MEDIA_SERVICE=emby/' "$yams/.env"
  # qBittorrent user + password, port, admin, password (no Jellyfin question).
  install <<<"$(printf '%s\n' qbuser qbpass '' '' "$PASSWORD")"
  check 'exit 0' test "$status" -eq 0
  check 'jellyfin off' grep -qx '      - JELLYFIN_URL=' <<<"$(hubfile compose.yaml)"
  check 'qbit user still right' grep -qx "QBIT_USERNAME='qbuser'" <<<"$(hubfile secrets/yams-hub.env)"
}

test_unreachable_container_stays_off() {
  echo host >"$st/c/jellyfin/netmode" # e.g. network_mode: host
  : >"$st/c/jellyfin/networks"
  # qBittorrent user + password, port, admin, password (no Jellyfin question).
  install <<<"$(printf '%s\n' qbuser qbpass '' '' "$PASSWORD")"
  check 'exit 0' test "$status" -eq 0
  check 'warns' contains "$out" 'jellyfin uses network_mode host'
  check 'no extra network' not_contains "$(hubfile compose.yaml)" net_yams_default
  check 'jellyfin off' grep -qx '      - JELLYFIN_URL=' <<<"$(hubfile compose.yaml)"
}

# answers FILE KEY=value...: an answers file (0600) for --answers.
answers() {
  local f=$1
  shift
  rm -f -- "$f"
  (umask 077 && printf '%s\n' '# answers for install.sh' "$@" >"$f")
}

test_answers_file_first_install() {
  answers "$work/answers" JELLYFIN_API_KEY=jellyfin-key-a QBIT_USERNAME=qbuser "QBIT_PASSWORD='qb pass'" \
    PORT=9001 '' ADMIN_USERNAME=Ada "ADMIN_PASSWORD=$PASSWORD"
  # stdin must not be read in answers mode: these lines would be wrong answers.
  install --answers "$work/answers" <<<"$(printf '%s\n' wrong-1 wrong-2 wrong-3 wrong-4 wrong-5 wrong-6)"
  local compose env
  compose=$(hubfile compose.yaml) env=$(hubfile secrets/yams-hub.env)
  check 'exit 0' test "$status" -eq 0
  check 'jellyfin key' grep -qx "JELLYFIN_API_KEY='jellyfin-key-a'" <<<"$env"
  check 'qbit user' grep -qx "QBIT_USERNAME='qbuser'" <<<"$env"
  check 'qbit password, quotes stripped' grep -qx "QBIT_PASSWORD='qb pass'" <<<"$env"
  check 'port' contains "$compose" '"0.0.0.0:9001:8080"'
  check 'admin lower-cased' grep -qx "YAMS_HUB_ADMIN_USERNAME='ada'" <<<"$env"
  check 'password hashed from stdin' grep -qx "hash-password stdin=${#PASSWORD}" "$st/hashed"
  check 'auto keys still read' grep -qx "SONARR_API_KEY='$SONARR_KEY'" <<<"$env"
  check 'stdin not used' not_contains "$env" wrong-
  check 'password not in argv' not_contains "$(calls)" "$PASSWORD"
  check 'password not printed' not_contains "$out" "$PASSWORD"
  check 'qbit password not printed' not_contains "$out" 'qb pass'
}

test_answers_file_missing_keys_are_enter() {
  answers "$work/answers" "ADMIN_PASSWORD=$PASSWORD"
  install --answers="$work/answers" </dev/null
  local env
  env=$(hubfile secrets/yams-hub.env)
  check 'exit 0' test "$status" -eq 0
  check 'default port' contains "$(hubfile compose.yaml)" '"0.0.0.0:8090:8080"'
  check 'default admin' grep -qx "YAMS_HUB_ADMIN_USERNAME='admin'" <<<"$env"
  check 'jellyfin skipped' not_contains "$env" JELLYFIN_API_KEY
  check 'qbit skipped' not_contains "$env" QBIT_
}

test_answers_file_reconfigure_clears_and_keeps() {
  install <<<"$(first_answers)"
  answers "$work/answers" JELLYFIN_API_KEY=jellyfin-key-b QBIT_PASSWORD=-
  : >"$st/calls"
  install --reconfigure --answers "$work/answers" </dev/null
  local env
  env=$(hubfile secrets/yams-hub.env)
  check 'exit 0' test "$status" -eq 0
  check 'new jellyfin key' grep -qx "JELLYFIN_API_KEY='jellyfin-key-b'" <<<"$env"
  check 'kept qbit user' grep -qx "QBIT_USERNAME='qbuser'" <<<"$env"
  check 'cleared qbit password' not_contains "$env" QBIT_PASSWORD
  check 'kept the admin' contains "$env" YAMS_HUB_ADMIN_PASSWORD_HASH
  check 'recreated the hub' contains "$(calls)" 'up -d --no-deps --force-recreate yams-hub'
}

test_answers_file_is_checked() {
  answers "$work/answers" "ADMIN_PASSWORD=$PASSWORD"
  chmod 644 "$work/answers"
  install --answers "$work/answers" </dev/null
  check 'world-readable: exit 1' test "$status" -eq 1
  check 'says chmod' contains "$out" 'readable by others'
  check 'nothing written' test ! -e "$yams/yams-hub"

  chmod 640 "$work/answers"
  install --answers "$work/answers" </dev/null
  check 'group-readable: exit 1' test "$status" -eq 1
  check 'group-readable: says chmod 600' contains "$out" 'chmod 600'
  check 'still nothing written' test ! -e "$yams/yams-hub"

  answers "$work/answers" "ADMIN_PASWORD=$PASSWORD"
  install --answers "$work/answers" </dev/null
  check 'unknown key: exit 1' test "$status" -eq 1
  check 'names the key and line' contains "$out" 'line 2: unknown key ADMIN_PASWORD'
  check 'value not printed' not_contains "$out" "$PASSWORD"

  answers "$work/answers" 'not a pair'
  install --answers "$work/answers" </dev/null
  check 'bad line: exit 1' test "$status" -eq 1

  install --answers "$work/missing" </dev/null
  check 'missing file: exit 1' test "$status" -eq 1

  install --update --answers "$work/answers" </dev/null
  check 'not with --update' test "$status" -eq 2
  install --answers </dev/null
  check 'needs a file' test "$status" -eq 2
}

test_uninstall_keeps_data_and_purge_asks() {
  install <<<"$(first_answers)"
  install --uninstall </dev/null
  check 'exit 0' test "$status" -eq 0
  check 'compose down' contains "$(calls)" "compose -p yams-hub -f $yams/yams-hub/compose.yaml down"
  check 'hub containers gone' test ! -e "$st/c/yams-hub"
  check 'kept the files' test -f "$yams/yams-hub/compose.yaml"
  install --uninstall --purge <<<'no'
  check 'purge not confirmed' test "$status" -eq 1
  check 'still there' test -f "$yams/yams-hub/compose.yaml"
  install --uninstall --purge <<<'purge'
  check 'purge ok' test "$status" -eq 0
  check 'hub dir deleted' test ! -e "$yams/yams-hub"
  check 'data deleted' test ! -e "$media/config/yams-hub"
  check 'YAMS untouched' test -f "$yams/docker-compose.yaml"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do run_test "$t"; done

if command -v shellcheck >/dev/null; then
  if shellcheck -x "$REPO/install.sh" "$REPO/build.sh" "$HERE/install_test.sh" "$HERE/fake_docker.sh"; then
    printf 'ok   shellcheck\n'
    pass=$((pass + 1))
  else
    printf 'FAIL shellcheck\n'
    fail=$((fail + 1))
  fi
elif [[ ${CI:-} == true ]]; then
  printf 'FAIL shellcheck (not installed, and CI=true: it must run in CI)\n'
  fail=$((fail + 1))
else
  printf 'skip shellcheck (not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
