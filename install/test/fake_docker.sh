#!/usr/bin/env bash
# Fake `docker` for install_test.sh (in the style of deploy/test/fake_docker.sh). State under $FAKE_DOCKER_STATE:
#   c/NAME/state      a container and its state (running, exited); c/NAME/gen its id generation (bumped on recreate)
#   c/NAME/labels     "project|working_dir|config_files" (compose labels)
#   c/NAME/netmode    HostConfig.NetworkMode;  c/NAME/networks  its networks, one per line
#   c/NAME/env        Config.Env lines;        c/NAME/mounts    "DESTINATION SOURCE" lines
#   c/NAME/health     State.Health.Status (default healthy)
#   nets/NAME.subnet  a network's subnet(s); nets/NAME.gateway; nets/NAME.containers "NAME IP/PREFIX" lines
#   images/TAG        a built or pulled image
#   recreate_also     containers that `compose up` also recreates (a misbehaving compose)
# Every call is appended to $FAKE_DOCKER_STATE/calls; hash-password's stdin is never logged.
set -euo pipefail
st=${FAKE_DOCKER_STATE:?}
mkdir -p "$st/c" "$st/nets" "$st/images"
printf '%s\n' "$*" >>"$st/calls"

img() { printf '%s/images/%s' "$st" "${1//[:\/@]/_}"; }
bump() { echo $(($(cat "$st/c/$1/gen" 2>/dev/null || echo 0) + 1)) >"$st/c/$1/gen"; }
hub=(yams-hub socket-proxy-hub yams-hub-updater)

case "$1" in
  info | version) echo 'fake docker 29' ;;
  ps)
    if [[ " $* " == *' --no-trunc '* ]]; then
      for d in "$st"/c/*/; do
        [[ -d $d ]] || continue
        n=$(basename "$d")
        echo "cid-$n-$(cat "$d/gen" 2>/dev/null || echo 0) $n"
      done
    else
      for d in "$st"/c/*/; do
        [[ -d $d ]] || continue
        printf '%s\t%s\n' "$(basename "$d")" "$(cat "$d/state")"
      done
    fi
    ;;
  inspect)
    fmt=$3 name=$4
    d=$st/c/$name
    if [[ $name == cid-gluetun ]]; then d=$st/c/gluetun; fi
    [[ -d $d ]] || { echo "No such object: $name" >&2; exit 1; }
    case $fmt in
      *project.config_files*) cat "$d/labels" ;;
      *NetworkMode*) cat "$d/netmode" 2>/dev/null || echo bridge ;;
      *NetworkSettings.Networks*) cat "$d/networks" 2>/dev/null || true ;;
      *Config.Env*) cat "$d/env" 2>/dev/null || true ;;
      *.Mounts*)
        [[ $fmt =~ \.Destination\ \"([^\"]+)\" ]] || exit 1
        awk -v dest="${BASH_REMATCH[1]}" '$1 == dest { printf "%s", $2 }' "$d/mounts" 2>/dev/null || true
        echo
        ;;
      *State.Health*) cat "$d/health" 2>/dev/null || echo healthy ;;
      '{{.Name}}') echo "/$(basename "$d")" ;;
      *) echo "fake docker: unsupported inspect format $fmt" >&2; exit 1 ;;
    esac
    ;;
  network)
    case "$2" in
      ls)
        for f in "$st"/nets/*.subnet; do
          [[ -e $f ]] || continue
          n=${f##*/}
          echo "${n%.subnet}"
        done
        ;;
      inspect)
        fmt=$4 name=$5
        [[ -f $st/nets/$name.subnet ]] || { echo "network $name not found" >&2; exit 1; }
        case $fmt in
          *.Gateway*) echo "$(cat "$st/nets/$name.gateway" 2>/dev/null || true) " ;;
          *.Subnet*) echo "$(cat "$st/nets/$name.subnet") " ;;
          *.Containers*) cat "$st/nets/$name.containers" 2>/dev/null || true ;;
        esac
        ;;
      *) echo "fake docker: unsupported: $*" >&2; exit 1 ;;
    esac
    ;;
  run)
    shift
    host='' entry=''
    while (($#)); do
      case "$1" in
        --rm | -i) shift ;;
        --network) shift 2 ;;
        --entrypoint) entry=$2; shift 2 ;;
        -v) host=${2%%:/m*}; shift 2 ;;
        *) break ;;
      esac
    done
    shift # image
    if [[ $entry == /app/yams-hub && $1 == hash-password ]]; then
      IFS= read -r pw || true
      echo "hash-password stdin=${#pw}" >>"$st/hashed"
      # shellcheck disable=SC2016 # a literal hash
      echo 'pbkdf2-sha256$600000$c2FsdHNhbHQ$aGFzaGhhc2g'
      exit 0
    fi
    [[ -n $host && $1 == sh && $2 == -euc ]] || { echo "fake docker: unsupported run" >&2; exit 1; }
    script=${3//\/m\//$host/}
    shift 3
    # chown needs root; record it instead.
    sh -euc "chown() { echo \"chown \$*\" >>'$st/chowns'; }; $script" "$@"
    ;;
  build)
    tag=''
    while (($#)); do
      [[ $1 == -t ]] && tag=$2
      shift
    done
    echo built >"$(img "$tag")"
    echo "built $tag"
    ;;
  pull) echo pulled >"$(img "$2")" ;;
  image)
    case "$2" in
      inspect) [[ -f $(img "$3") ]] || { echo "No such image: $3" >&2; exit 1; } ;;
      rm) for r in "${@:3}"; do rm -f "$(img "$r")"; done ;;
    esac
    ;;
  compose)
    [[ $2 == version ]] && { echo 'Docker Compose version v2.40.0'; exit 0; }
    file=''
    for ((i = 1; i <= $#; i++)); do
      if [[ ${!i} == -f ]]; then j=$((i + 1)); file=${!j}; fi
    done
    [[ -f $file ]] || { echo "compose file $file not found" >&2; exit 1; }
    if [[ " $* " == *' config -q'* ]]; then
      [[ ! -e $st/compose_invalid ]] || { echo 'invalid compose file' >&2; exit 1; }
    elif [[ " $* " == *' up '* ]]; then
      svcs=("${hub[@]}")
      [[ " $* " == *' --no-deps '* ]] && svcs=("${!#}")
      for s in "${svcs[@]}"; do
        mkdir -p "$st/c/$s"
        echo running >"$st/c/$s/state"
        bump "$s"
      done
      if [[ -f $st/nets/yams_network.subnet && ! -f $st/nets/yams-hub_ctl.subnet ]]; then
        echo 172.30.250.0/29 >"$st/nets/yams-hub_ctl.subnet"
      fi
      for o in $(cat "$st/recreate_also" 2>/dev/null || true); do bump "$o"; done
    elif [[ " $* " == *' down'* ]]; then
      for s in "${hub[@]}"; do rm -rf "${st:?}/c/$s"; done
      rm -f "$st/nets/yams-hub_ctl.subnet"
    fi
    ;;
  logs) ;;
  *)
    echo "fake docker: unsupported: $*" >&2
    exit 1
    ;;
esac
