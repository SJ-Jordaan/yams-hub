#!/usr/bin/env bash
# Fake `docker` for deploy_test.sh: a tiny image/tag/container store under $FAKE_DOCKER_STATE.
# Every call is appended to $FAKE_DOCKER_STATE/calls. Only what deploy.sh uses is implemented.
set -euo pipefail
st=${FAKE_DOCKER_STATE:?}
mkdir -p "$st/tags" "$st/ids" "$st/containers"
printf '%s\n' "$*" >>"$st/calls"

tagfile() { printf '%s/tags/%s' "$st" "${1//[:\/]/__}"; }
resolve() {
  if [[ $1 == sha256:* ]]; then
    [[ -f $st/ids/${1#sha256:} ]] && printf '%s\n' "$1" && return 0
    return 1
  fi
  local ref=$1
  [[ $ref == *:* ]] || ref="$ref:latest"
  [[ -f $(tagfile "$ref") ]] && cat "$(tagfile "$ref")" && return 0
  return 1
}

case "$1" in
  version) echo 'docker 29.4.3' ;;
  network) ;; # no yams_network: the address check is skipped
  compose)
    if [[ " $* " == *" config --services "* ]]; then
      printf '%s\n' sonarr radarr yams-hub socket-proxy-hub yams-hub-updater
    elif [[ " $* " == *" up "* ]]; then
      all="$*"
      svcs=${all##* --no-deps }
      printf '%s\n' "$svcs" >>"$st/up"
      # Recreate each listed container whose image is not the current :latest.
      for s in $svcs; do
        if id=$(resolve "$s:latest"); then
          printf '%s\n' "$id" >"$st/containers/$s"
        elif [[ ! -f $st/containers/$s ]]; then
          echo 'sha256:pulled' >"$st/containers/$s" # e.g. socket-proxy-hub (a registry image)
        fi
      done
    fi
    ;;
  build)
    shift
    tag='' labels=()
    while (($#)); do
      case "$1" in
        -t) tag=$2; shift ;;
        --label) labels+=("$2"); shift ;;
      esac
      shift
    done
    n=$(($(cat "$st/counter" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$st/counter"
    id=$(printf 'sha256:%064x' "$n")
    printf '%s\n' "${labels[@]}" >"$st/ids/${id#sha256:}"
    printf '%s\n' "$id" >"$(tagfile "$tag")"
    echo "built $tag"
    ;;
  image)
    case "$2" in
      inspect)
        fmt=$4 ref=$5
        id=$(resolve "$ref") || { echo "No such image: $ref" >&2; exit 1; }
        if [[ $fmt == '{{.Id}}' ]]; then
          echo "$id"
        elif [[ $fmt =~ index\ .Config.Labels\ \"([^\"]+)\" ]]; then
          key=${BASH_REMATCH[1]}
          v=$(sed -n "s/^$key=//p" "$st/ids/${id#sha256:}")
          echo "${v:-<no value>}"
        fi
        ;;
      tag)
        id=$(resolve "$3") || { echo "No such image: $3" >&2; exit 1; }
        printf '%s\n' "$id" >"$(tagfile "$4")"
        ;;
      rm)
        if [[ $3 == sha256:* ]]; then
          if grep -qx -- "$3" "$st"/containers/* 2>/dev/null; then
            echo "image is being used by a container" >&2
            exit 1
          fi
          echo "$3" >>"$st/removed"
        else
          ref=$3
          [[ $ref == *:* ]] || ref="$ref:latest"
          rm -f "$(tagfile "$ref")"
        fi
        ;;
    esac
    ;;
  inspect)
    fmt=$3 name=$4
    [[ -f $st/containers/$name ]] || { echo "No such object: $name" >&2; exit 1; }
    if [[ $fmt == '{{.Image}}' ]]; then cat "$st/containers/$name"; else echo healthy; fi
    ;;
  top)
    [[ -f $st/containers/$2 ]] || exit 1
    echo 'UID PID PPID C STIME TTY TIME CMD'
    echo 'root 4100 4080 0 10:00 ? 00:00:01 /app/updater serve'
    busy=$(cat "$st/busy" 2>/dev/null || echo 0)
    if [[ $busy == forever ]] || ((busy > 0)); then
      [[ $busy == forever ]] || echo $((busy - 1)) >"$st/busy"
      echo 'root 4200 4100 0 10:01 ? 00:00:00 /usr/local/bin/docker compose -p yams up -d --no-deps -- sonarr'
    fi
    ;;
  ps) printf '%s\n' 'aaa sonarr' 'bbb radarr' 'ccc yams-hub' ;;
  logs) ;;
  *)
    echo "fake docker: unsupported: $*" >&2
    exit 1
    ;;
esac
