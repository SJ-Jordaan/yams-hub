#!/usr/bin/env bash
# Builds the YAMS Hub secrets files on the NAS (ARCHITECTURE §9):
#   /opt/yams/monitoring/secrets/yams-hub.env          gateway secrets  (uid 64090, 0400)
#   /opt/yams/monitoring/secrets/yams-hub-updater.env  UPDATER_TOKEN    (root, 0400)
#
# Run it ON THE NAS as the docker-group user (no sudo needed). It prints key names, sources and
# counts only, never a value. Secret values never appear in command arguments: they are read
# with grep into shell variables and written with the printf builtin to a mktemp file in the
# secrets directory, which is then renamed over the target (atomic).
#
# Usage: make_hub_env.sh [options]
#   --set-admin-password  prompt for the hub admin password and store its PBKDF2 hash
#                         (YAMS_HUB_ADMIN_PASSWORD_HASH; only used while the hub has no users,
#                         and by `yams-hub reset-admin`). Prompted automatically on the first run.
#   --set-kavita-key      prompt for the Kavita Auth Key (Kavita > User settings > Auth Keys)
#   --drop-bootstrap      remove YAMS_HUB_ADMIN_PASSWORD_HASH (after the first successful start)
#   --rotate-updater-token  generate a new UPDATER_TOKEN (restart yams-hub and yams-hub-updater after)
#   --no-check            skip the final `yams-hub check-config`
#   -h, --help            show this help
#
# Environment overrides (defaults in brackets): YAMS_SECRETS_DIR [/opt/yams/monitoring/secrets],
# YAMS_CONFIG_ROOT [/volume1/mediashare/config], YAMS_HUB_IMAGE [yams-hub:latest],
# ALPINE_IMAGE [alpine:3.22].
set -euo pipefail
umask 077

SECRETS_DIR=${YAMS_SECRETS_DIR:-/opt/yams/monitoring/secrets}
CONFIG_ROOT=${YAMS_CONFIG_ROOT:-/volume1/mediashare/config}
HUB_IMAGE=${YAMS_HUB_IMAGE:-yams-hub:latest}
ALPINE_IMAGE=${ALPINE_IMAGE:-alpine:3.22}

HOMEPAGE_ENV=$SECRETS_DIR/homepage.env
HUB_ENV=$SECRETS_DIR/yams-hub.env
UPDATER_ENV=$SECRETS_DIR/yams-hub-updater.env
DATA_DIR=$CONFIG_ROOT/yams-hub
HUB_UID=64090
DEFAULT_JELLYFIN_ADMIN_USER_ID=4c0628aacef24bdfacd40f946ea33ee7

set_admin_password=0
set_kavita_key=0
drop_bootstrap=0
rotate_updater_token=0
run_check=1

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
  case "$arg" in
    --set-admin-password) set_admin_password=1 ;;
    --set-kavita-key) set_kavita_key=1 ;;
    --drop-bootstrap) drop_bootstrap=1 ;;
    --rotate-updater-token) rotate_updater_token=1 ;;
    --no-check) run_check=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done
if ((set_admin_password && drop_bootstrap)); then
  echo '--set-admin-password and --drop-bootstrap exclude each other' >&2
  exit 2
fi

die() {
  printf 'make_hub_env.sh: ERROR: %s\n' "$*" >&2
  exit 1
}
info() { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------------------------
# Root-owned file changes go through a throwaway alpine container (no sudo on Zenith). The
# command strings passed to it contain only paths and numeric ids, never a secret.
# ---------------------------------------------------------------------------------------------
in_secrets_dir() {
  docker run --rm --network none -v "$SECRETS_DIR:/s" "$ALPINE_IMAGE" sh -euc "$1"
}

unlocked=0
tmp_files=()

# Makes both secrets files readable and writable by the invoking user (re-runs).
unlock_files() {
  local me
  me="$(id -u):$(id -g)"
  in_secrets_dir "for f in yams-hub.env yams-hub-updater.env; do
      if [ -f /s/\$f ]; then chown $me /s/\$f; chmod 0600 /s/\$f; fi
    done"
  unlocked=1
}

# Restores the owners and modes of ARCHITECTURE §9.
lock_files() {
  in_secrets_dir "if [ -f /s/yams-hub.env ]; then chown $HUB_UID:$HUB_UID /s/yams-hub.env; chmod 0400 /s/yams-hub.env; fi
    if [ -f /s/yams-hub-updater.env ]; then chown 0:0 /s/yams-hub-updater.env; chmod 0400 /s/yams-hub-updater.env; fi"
  unlocked=0
}

cleanup() {
  local status=$?
  local f
  for f in ${tmp_files[@]+"${tmp_files[@]}"}; do
    rm -f -- "$f"
  done
  if ((unlocked)); then
    lock_files || warn 'could not restore the owner/mode of the secrets files; re-run this script'
  fi
  exit "$status"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------------------------
# Reading KEY='value' lines. Sets REPLY; returns 1 when the key is absent or empty.
# ---------------------------------------------------------------------------------------------
read_quoted() {
  local file=$1 key=$2 count
  REPLY=''
  [[ -r $file ]] || return 1
  count=$(grep -c -- "^${key}=" "$file" || true)
  ((count > 0)) || return 1
  ((count == 1)) || die "$key appears $count times in $(basename "$file"); keep one line"
  REPLY=$(grep -oP -- "^${key}='\\K[^']*(?='\\s*\$)" "$file" || true)
  if [[ -z $REPLY ]]; then
    if grep -qP -- "^${key}=''\\s*\$" "$file"; then
      return 1
    fi
    die "$key in $(basename "$file") is not a single-quoted value without quotes inside"
  fi
  return 0
}

# Reads <ApiKey> from an *arr config.xml. Sets REPLY; returns 1 when unavailable.
read_arr_key() {
  local file=$1
  REPLY=''
  [[ -r $file ]] || return 1
  REPLY=$(grep -oP -m1 '<ApiKey>\K[A-Za-z0-9]+(?=</ApiKey>)' "$file" || true)
  [[ -n $REPLY ]]
}

# Refuses values the gateway's KEY='value' parser cannot represent (like make_secrets.sh).
check_value() {
  local key=$1 value=$2
  [[ $value != *"'"* ]] || die "$key contains a single quote; refusing"
  [[ $value != *$'\n'* && $value != *$'\r'* ]] || die "$key contains a newline; refusing"
}

declare -A out=() source_of=()
# Output order: the gateway's variable list (ARCHITECTURE §5.2).
order=(
  YAMS_HUB_ADMIN_USERNAME YAMS_HUB_ADMIN_PASSWORD_HASH
  SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY BAZARR_API_KEY SEERR_API_KEY
  JELLYFIN_API_KEY JELLYFIN_ADMIN_USER_ID JELLYSTAT_API_KEY
  QBIT_USERNAME QBIT_PASSWORD WATCHTOWER_TOKEN UPDATER_TOKEN ABS_API_KEY KAVITA_API_KEY
)

put() {
  check_value "$1" "$2"
  out[$1]=$2
  source_of[$1]=$3
}

# ---------------------------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------------------------
command -v docker >/dev/null || die 'docker not found'
docker info >/dev/null 2>&1 || die 'cannot talk to the Docker daemon (is this user in the docker group?)'
if ! grep -qP 'x' <<<'x' 2>/dev/null; then die 'GNU grep with -P is required'; fi
[[ -d $SECRETS_DIR ]] || die "$SECRETS_DIR does not exist"
[[ -w $SECRETS_DIR ]] || die "$SECRETS_DIR is not writable by $(id -un)"
[[ -r $HOMEPAGE_ENV ]] || die "$HOMEPAGE_ENV is not readable"

# A bind mount of a missing file makes Docker create an (empty, root-owned) directory there.
for f in "$HUB_ENV" "$UPDATER_ENV"; do
  if [[ -d $f ]]; then
    warn "$(basename "$f") is a directory (created by a docker bind mount); removing it"
    in_secrets_dir "rmdir /s/$(basename "$f")" || die "$f is a non-empty directory; inspect it by hand"
  fi
done

# The data dir: uid 64090, 0700 (ARCHITECTURE §6). Idempotent.
docker run --rm --network none -v "$CONFIG_ROOT:/c" "$ALPINE_IMAGE" \
  sh -euc "mkdir -p /c/yams-hub && chown $HUB_UID:$HUB_UID /c/yams-hub && chmod 700 /c/yams-hub"
info "data dir:  $DATA_DIR (uid $HUB_UID, 0700)"

if ((drop_bootstrap)); then
  docker run --rm --network none -v "$DATA_DIR:/d:ro" "$ALPINE_IMAGE" test -s /d/users.json ||
    die 'the hub has not created users.json yet; start it once with the bootstrap hash first'
fi

# ---------------------------------------------------------------------------------------------
# Existing values (kept on re-runs)
# ---------------------------------------------------------------------------------------------
if [[ -e $HUB_ENV || -e $UPDATER_ENV ]]; then
  unlock_files
fi

declare -A existing=()
extra_keys=()
if [[ -f $HUB_ENV ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
    [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]] || die "$(basename "$HUB_ENV") has a line that is not KEY='value'"
    key=${BASH_REMATCH[1]}
    if read_quoted "$HUB_ENV" "$key"; then
      existing[$key]=$REPLY
    fi
  done <"$HUB_ENV"
  unset line key
fi
if [[ -z ${existing[UPDATER_TOKEN]-} ]] && read_quoted "$UPDATER_ENV" UPDATER_TOKEN; then
  existing[UPDATER_TOKEN]=$REPLY
fi

for key in "${!existing[@]}"; do
  known=0
  for k in "${order[@]}"; do
    if [[ $k == "$key" ]]; then
      known=1
      break
    fi
  done
  if ((!known)); then
    extra_keys+=("$key")
    order+=("$key")
    put "$key" "${existing[$key]}" kept
  fi
done
unset key k known

# ---------------------------------------------------------------------------------------------
# Service secrets: *arr keys from config.xml, everything else from homepage.env
# ---------------------------------------------------------------------------------------------
for svc in sonarr radarr prowlarr; do
  var="${svc^^}_API_KEY"
  if read_arr_key "$CONFIG_ROOT/$svc/config.xml"; then
    put "$var" "$REPLY" "$svc/config.xml"
  elif read_quoted "$HOMEPAGE_ENV" "HOMEPAGE_VAR_${svc^^}_KEY"; then
    put "$var" "$REPLY" homepage.env
  fi
done
unset svc var

declare -A from_homepage=(
  [BAZARR_API_KEY]=BAZARR_KEY
  [SEERR_API_KEY]=SEERR_KEY
  [JELLYFIN_API_KEY]=JELLYFIN_KEY
  [JELLYSTAT_API_KEY]=JELLYSTAT_KEY
  [QBIT_USERNAME]=QBIT_USER
  [QBIT_PASSWORD]=QBIT_PASS
  [WATCHTOWER_TOKEN]=WATCHTOWER_TOKEN
  [ABS_API_KEY]=ABS_KEY
)
for var in "${!from_homepage[@]}"; do
  if read_quoted "$HOMEPAGE_ENV" "HOMEPAGE_VAR_${from_homepage[$var]}"; then
    put "$var" "$REPLY" homepage.env
  fi
done
unset var

# A source that is missing now (unreadable config.xml, key removed from homepage.env) must not
# silently disable a service that worked before: keep the value already in the file.
for var in SONARR_API_KEY RADARR_API_KEY PROWLARR_API_KEY "${!from_homepage[@]}"; do
  if [[ -z ${out[$var]-} && -n ${existing[$var]-} ]]; then
    put "$var" "${existing[$var]}" 'kept (no current source)'
    warn "$var: no current source; keeping the value already in $(basename "$HUB_ENV")"
  fi
done
unset var

# Values that only this file holds.
if [[ -n ${existing[JELLYFIN_ADMIN_USER_ID]-} ]]; then
  put JELLYFIN_ADMIN_USER_ID "${existing[JELLYFIN_ADMIN_USER_ID]}" kept
else
  put JELLYFIN_ADMIN_USER_ID "$DEFAULT_JELLYFIN_ADMIN_USER_ID" default
fi

for key in YAMS_HUB_ADMIN_USERNAME YAMS_HUB_ADMIN_PASSWORD_HASH KAVITA_API_KEY; do
  if [[ -n ${existing[$key]-} ]]; then
    put "$key" "${existing[$key]}" kept
  fi
done
unset key

if [[ -n ${existing[UPDATER_TOKEN]-} ]] && ((!rotate_updater_token)); then
  put UPDATER_TOKEN "${existing[UPDATER_TOKEN]}" kept
else
  # 48 random bytes, base64url without padding (64 characters).
  token=$(head -c 48 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
  ((${#token} == 64)) || die 'could not generate UPDATER_TOKEN'
  put UPDATER_TOKEN "$token" generated
  unset token
fi

# ---------------------------------------------------------------------------------------------
# Interactive values
# ---------------------------------------------------------------------------------------------
read_secret() { # prompt -> REPLY (no echo on a terminal)
  REPLY=''
  if [[ -t 0 ]]; then
    IFS= read -rsp "$1" REPLY || true
    printf '\n' >&2
  else
    IFS= read -r REPLY || true
  fi
}

if ((drop_bootstrap)); then
  unset 'out[YAMS_HUB_ADMIN_PASSWORD_HASH]'
  info 'bootstrap admin hash: dropped'
elif ((!set_admin_password)) && [[ -z ${out[YAMS_HUB_ADMIN_PASSWORD_HASH]-} ]]; then
  if docker run --rm --network none -v "$DATA_DIR:/d:ro" "$ALPINE_IMAGE" test -s /d/users.json; then
    info 'bootstrap admin hash: not needed (the hub already has users)'
  elif [[ -t 0 ]]; then
    info 'The hub has no users yet: choose the password of its first admin account.'
    set_admin_password=1
  else
    warn 'no bootstrap admin hash and no terminal: re-run with --set-admin-password before the first start'
  fi
fi

if ((set_admin_password)); then
  docker image inspect "$HUB_IMAGE" >/dev/null 2>&1 || die "$HUB_IMAGE is not built yet (run deploy.sh first)"
  read_secret 'Hub admin password (at least 10 characters): '
  password=$REPLY
  if [[ -t 0 ]]; then
    read_secret 'Repeat: '
    [[ $REPLY == "$password" ]] || die 'the passwords do not match'
  fi
  REPLY=''
  ((${#password} >= 10)) || die 'the password must have at least 10 characters'
  # The password travels through a pipe (printf is a builtin), never through argv.
  hash=$(printf '%s\n' "$password" |
    docker run --rm -i --network none --entrypoint /app/yams-hub "$HUB_IMAGE" hash-password) ||
    die 'hash-password failed'
  unset password
  [[ $hash =~ ^pbkdf2-sha256\$[0-9]+\$[A-Za-z0-9_=+/-]+\$[A-Za-z0-9_=+/-]+$ ]] ||
    die 'unexpected hash-password output'
  put YAMS_HUB_ADMIN_PASSWORD_HASH "$hash" entered
  unset hash
fi

if ((set_kavita_key)); then
  read_secret 'Kavita Auth Key: '
  [[ -n $REPLY && $REPLY != *[[:space:]]* ]] || die 'empty or malformed Kavita key'
  put KAVITA_API_KEY "$REPLY" entered
  REPLY=''
fi

# ---------------------------------------------------------------------------------------------
# Write both files (temp file in the target directory, then rename)
# ---------------------------------------------------------------------------------------------
write_file() { # target, keys...
  local target=$1 tmp k
  shift
  tmp=$(mktemp "$SECRETS_DIR/.$(basename "$target").XXXXXX")
  tmp_files+=("$tmp")
  {
    printf "# Written by make_hub_env.sh on %s. KEY='value' lines; see deploy/README.md.\n" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for k in "$@"; do
      if [[ -n ${out[$k]-} ]]; then
        printf "%s='%s'\n" "$k" "${out[$k]}"
      fi
    done
  } >"$tmp"
  mv -f -- "$tmp" "$target"
}

# From here on the EXIT trap restores owners and modes even if a write fails half way (first
# run included: the new files are owned by this user until lock_files).
unlocked=1
write_file "$HUB_ENV" "${order[@]}"
write_file "$UPDATER_ENV" UPDATER_TOKEN
lock_files

# ---------------------------------------------------------------------------------------------
# Summary: names and sources only
# ---------------------------------------------------------------------------------------------
written=0
missing=()
info ''
info "$(basename "$HUB_ENV") (owner $HUB_UID, 0400):"
for k in "${order[@]}"; do
  if [[ -n ${out[$k]-} ]]; then
    written=$((written + 1))
    printf '  %-30s %s\n' "$k" "${source_of[$k]}"
  else
    missing+=("$k")
  fi
done
info "  $written keys written"
if ((${#extra_keys[@]})); then
  info "  kept ${#extra_keys[@]} unmanaged key(s): ${extra_keys[*]}"
fi
info "$(basename "$UPDATER_ENV") (owner root, 0400): UPDATER_TOKEN (${source_of[UPDATER_TOKEN]})"
if ((${#missing[@]})); then
  info ''
  info "not set (${#missing[@]}): ${missing[*]}"
  for k in "${missing[@]}"; do
    case "$k" in
      KAVITA_API_KEY) info '  KAVITA_API_KEY: create an Auth Key in Kavita, then re-run with --set-kavita-key' ;;
      YAMS_HUB_ADMIN_USERNAME) ;; # optional, defaults to "admin"
      YAMS_HUB_ADMIN_PASSWORD_HASH) ;;
      *) info "  $k: missing in homepage.env; the matching service shows as disabled in the hub" ;;
    esac
  done
fi
if [[ ${source_of[UPDATER_TOKEN]} == generated && -n ${existing[UPDATER_TOKEN]-} ]]; then
  info ''
  info 'UPDATER_TOKEN was rotated: restart yams-hub and yams-hub-updater.'
fi

# ---------------------------------------------------------------------------------------------
# Final check with the gateway's own loader (prints no values)
# ---------------------------------------------------------------------------------------------
if ((run_check)); then
  info ''
  if ! docker image inspect "$HUB_IMAGE" >/dev/null 2>&1; then
    warn "$HUB_IMAGE is not built yet; skipping check-config"
    exit 0
  fi
  info "check-config ($HUB_IMAGE):"
  if ! docker run --rm --network none --read-only --user "$HUB_UID:$HUB_UID" \
    -e YAMS_HUB_SECRETS_FILE=/run/secrets/yams-hub.env -e YAMS_HUB_DATA_DIR=/data \
    -v "$HUB_ENV:/run/secrets/yams-hub.env:ro" -v "$DATA_DIR:/data:ro" \
    --entrypoint /app/yams-hub "$HUB_IMAGE" check-config | sed 's/^/  /'; then
    die 'check-config reported an invalid configuration'
  fi
fi
