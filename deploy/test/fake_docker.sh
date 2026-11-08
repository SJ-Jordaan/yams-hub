#!/usr/bin/env bash
# Fake `docker` for deploy_test.sh: a tiny image/tag/container store under $FAKE_DOCKER_STATE.
# Every call is appended to $FAKE_DOCKER_STATE/calls. Only what deploy.sh uses is implemented.
#   nets/NAME.subnet   a network and its subnet(s); nets/NAME.members its running containers and
#                      nets/NAME.stopped its stopped ones (one per line); nets/NAME.gateway its gateway
#   containers/NAME    a container and the image id it runs; cids/NAME its container id generation
#                      (bumped whenever it is (re)created); stopped/NAME marks it stopped
#   rendered           socket-proxy-hub's /run/haproxy/haproxy.cfg (rendered from $HAPROXY_CFG with
#                      $FAKE_BIND, default :2375, whenever compose creates or starts the proxy)
#   recreate_also      containers that `compose up` also recreates (a misbehaving compose)
#   compose_config     what `compose config SERVICE...` prints (default: the fixed control network)
#   force              services passed to `up --force-recreate`; up: those passed to a plain `up`
set -euo pipefail
st=${FAKE_DOCKER_STATE:?}
mkdir -p "$st/tags" "$st/ids" "$st/containers" "$st/nets" "$st/cids" "$st/stopped"
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
cid() { printf 'cid-%s-%s' "$1" "$(cat "$st/cids/$1" 2>/dev/null || echo 0)"; }
bump() { echo $(($(cat "$st/cids/$1" 2>/dev/null || echo 0) + 1)) >"$st/cids/$1"; }
render() {
  if [[ -f ${HAPROXY_CFG:-} ]]; then
    sed "s/@@BIND_PROTO@@/${FAKE_BIND:-:2375}/g" "$HAPROXY_CFG" >"$st/rendered"
  else
    : >"$st/rendered"
  fi
}

case "$1" in
  version) echo 'docker 29.4.3' ;;
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
        if [[ $fmt == *.Gateway* ]]; then
          printf '%s \n' "$(cat "$st/nets/$name.gateway" 2>/dev/null || true)"
        elif [[ $fmt == *IPAM.Config* ]]; then
          printf '%s \n' "$(cat "$st/nets/$name.subnet")"
        elif [[ $fmt == *.Options* ]]; then
          echo '<no value>'
        elif [[ $fmt == '{{.Id}}' ]]; then
          echo 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
        elif [[ $fmt == *.Containers* ]]; then
          cat "$st/nets/$name.members" 2>/dev/null || true
        fi
        ;;
      rm)
        [[ -f $st/nets/$3.subnet ]] || { echo "network $3 not found" >&2; exit 1; }
        if [[ -s $st/nets/$3.members ]]; then
          echo "error while removing network: network $3 has active endpoints" >&2
          exit 1
        fi
        rm -f "$st/nets/$3.subnet" "$st/nets/$3.members" "$st/nets/$3.stopped" "$st/nets/$3.gateway"
        ;;
      *)
        echo "fake docker: unsupported: $*" >&2
        exit 1
        ;;
    esac
    ;;
  compose)
    if [[ " $* " == *" config --services "* ]]; then
      printf '%s\n' sonarr radarr yams-hub socket-proxy-hub yams-hub-updater
    elif [[ " $* " == *" config "* ]]; then
      if [[ -f $st/compose_config ]]; then
        cat "$st/compose_config"
      else
        cat <<EOF
name: yams
services:
  socket-proxy-hub:
    image: lscr.io/linuxserver/socket-proxy:3.4.7-r0-ls105@sha256:0000000000000000000000000000000000000000000000000000000000000abc
    environment:
      DISABLE_IPV6: "1"
      POST: "0"
    networks:
      yams_hub_ctl:
        ipv4_address: 172.30.250.3
    volumes:
      - type: bind
        source: ${HAPROXY_CFG:?}
        target: /templates/haproxy.cfg
        read_only: true
  yams-hub:
    networks:
      yams_hub_ctl:
        ipv4_address: 172.30.250.2
      yams_network:
        ipv4_address: 172.28.0.49
  yams-hub-updater:
    environment:
      UPDATER_ALLOWED_SOURCES: 172.30.250.2
      UPDATER_TOKEN_FILE: /run/secrets/updater.env
    networks:
      yams_hub_ctl:
        ipv4_address: 172.30.250.4
networks:
  yams_hub_ctl:
    name: yams_yams_hub_ctl
    internal: true
    ipam:
      config:
        - subnet: 172.30.250.0/29
          gateway: 172.30.250.1
EOF
      fi
    elif [[ " $* " == *" up "* ]]; then
      all="$*"
      svcs=${all##* --no-deps }
      if [[ " $* " == *" --force-recreate "* ]]; then
        printf '%s\n' "$svcs" >>"$st/force"
      else
        printf '%s\n' "$svcs" >>"$st/up"
      fi
      # Compose creates the project's control network when it is missing.
      if [[ ! -f $st/nets/yams_yams_hub_ctl.subnet ]]; then
        echo 172.30.250.0/29 >"$st/nets/yams_yams_hub_ctl.subnet"
        echo created >"$st/ctl_created"
      fi
      # (Re)create each listed container that is missing, forced, or not on the current :latest;
      # start a stopped one. The proxy's entrypoint renders its template whenever it starts.
      for s in $svcs; do
        cur=$(cat "$st/containers/$s" 2>/dev/null || true)
        img=$(resolve "$s:latest" || true)
        started=0
        if [[ " $* " == *" --force-recreate "* || -z $cur || (-n $img && $img != "$cur") ]]; then
          printf '%s\n' "${img:-${cur:-sha256:pulled}}" >"$st/containers/$s" # pulled: a registry image
          bump "$s"
          started=1
        elif [[ -e $st/stopped/$s ]]; then
          started=1
        fi
        rm -f "$st/stopped/$s"
        if ((started)) && [[ $s == socket-proxy-hub ]]; then render; fi
      done
      for o in $(cat "$st/recreate_also" 2>/dev/null || true); do bump "$o"; done
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
    if [[ $fmt == '{{.Image}}' ]]; then
      cat "$st/containers/$name"
    elif [[ $fmt == '{{.State.Running}}' ]]; then
      if [[ -e $st/stopped/$name ]]; then echo false; else echo true; fi
    else
      echo healthy
    fi
    ;;
  exec)
    [[ -f $st/containers/$2 && ! -e $st/stopped/$2 ]] || { echo "container $2 is not running" >&2; exit 1; }
    if [[ $2 == socket-proxy-hub && "${*:3}" == 'cat /run/haproxy/haproxy.cfg' ]]; then
      cat "$st/rendered" 2>/dev/null || { echo 'cat: /run/haproxy/haproxy.cfg: No such file' >&2; exit 1; }
    else
      echo "fake docker: unsupported: $*" >&2
      exit 1
    fi
    ;;
  run)
    # Only the haproxy template helper: run --rm -i --network none --user 0:0 --entrypoint sh
    # -v HOST:/m IMAGE -euc SCRIPT sh ARGS..., run here with /m pointing at HOST.
    shift
    host='' entry=''
    while (($#)); do
      case "$1" in
        --rm | -i) shift ;;
        --network | --user) shift 2 ;;
        --entrypoint) entry=$2; shift 2 ;;
        -v) host=${2%:/m}; shift 2 ;;
        *) break ;;
      esac
    done
    shift # image
    [[ $entry == sh && -n $host && $1 == -euc ]] || { echo "fake docker: unsupported run" >&2; exit 1; }
    script=${2//\/m\//$host/}
    shift 2
    sh -euc "$script" "$@"
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
  stop)
    [[ -f $st/containers/$2 ]] || { echo "No such container: $2" >&2; exit 1; }
    touch "$st/stopped/$2"
    ;;
  rm)
    [[ -f $st/containers/$2 ]] || { echo "No such container: $2" >&2; exit 1; }
    rm -f "$st/containers/$2" "$st/stopped/$2"
    for f in "$st"/nets/*.members; do
      [[ -e $f ]] || continue
      grep -vx -- "$2" "$f" >"$f.tmp" || true
      mv "$f.tmp" "$f"
    done
    ;;
  ps)
    n=''
    for a; do [[ $a == network=* ]] && n=${a#network=}; done
    if [[ -n $n ]]; then
      cat "$st/nets/$n.members" "$st/nets/$n.stopped" 2>/dev/null || true
    else
      for f in "$st"/containers/*; do
        [[ -e $f ]] || continue
        echo "$(cid "${f##*/}") ${f##*/}"
      done
    fi
    ;;
  logs) ;;
  *)
    echo "fake docker: unsupported: $*" >&2
    exit 1
    ;;
esac
