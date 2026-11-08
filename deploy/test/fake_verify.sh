#!/usr/bin/env bash
# Fake `docker` and `curl` for the verify.sh check 1 cases in deploy_test.sh (installed under both
# names; it acts by its basename). The scenario is a directory, $VERIFY_STATE, of small files; a
# missing file means "as deployed correctly":
#   subnet            subnet of yams_yams_hub_ctl (172.30.250.0/29)
#   ip_NAME           NAME's address on yams_yams_hub_ctl (the fixed trio)
#   members           containers on yams_yams_hub_ctl (the trio)
#   rendered          socket-proxy-hub's /run/haproxy/haproxy.cfg (created by the test)
#   netmodes          "/NAME MODE" lines, the HostConfig.NetworkMode of every container
#   prowlarr_curl     "missing": docker exec prowlarr curl fails with 126
#   proxy             "open": 172.30.250.3:2375 answers 200 (default: connection dropped, curl 52)
#   updater           HTTP status of 172.30.250.4:8080 (default 403), or "drop" (curl 7)
# Everything verify.sh's other checks ask for gets an empty answer, so they fail or pass quietly.
set -euo pipefail
vs=${VERIFY_STATE:?}
get() { cat "$vs/$1" 2>/dev/null || printf '%s' "${2-}"; }
id_of() { printf '%s' "$1" | sha256sum | cut -c1-64; }

fake_curl() {
  local w=0 a url code rc
  for a; do [[ $a == -w ]] && w=1; done
  url=${!#}
  case $url in
    http://172.28.0.49:8080/api/v1/ping) code=200 rc=0 ;;
    http://socket-proxy-hub:* | http://yams-hub-updater:*) code=000 rc=6 ;;
    http://172.30.250.3:2375/*)
      if [[ $(get proxy) == open ]]; then code=200 rc=0; else code=000 rc=52; fi
      ;;
    http://172.30.250.4:8080/*)
      code=$(get updater 403) rc=0
      if [[ $code == drop ]]; then code=000 rc=7; fi
      ;;
    *) code=000 rc=7 ;;
  esac
  if ((w)); then printf '%s' "$code"; fi
  return "$rc"
}

if [[ ${0##*/} == curl ]]; then
  fake_curl "$@"
  exit $?
fi

case "$1" in
  network)
    [[ $2 == inspect ]] || exit 0
    fmt=$4
    if [[ $fmt == *IPAM.Config* ]]; then
      printf '%s \n' "$(get subnet 172.30.250.0/29)"
    elif [[ $fmt == *.Containers* ]]; then
      get members "$(printf '%s\n' yams-hub socket-proxy-hub yams-hub-updater)"
      echo
    fi
    ;;
  inspect)
    fmt=$3
    shift 3
    case $fmt in
      '{{.State.Running}}') echo true ;;
      '{{.Id}}') id_of "$1" ;;
      *'index .NetworkSettings.Networks "yams_yams_hub_ctl"'*)
        case $1 in
          yams-hub) get ip_yams-hub 172.30.250.2 ;;
          socket-proxy-hub) get ip_socket-proxy-hub 172.30.250.3 ;;
          yams-hub-updater) get ip_yams-hub-updater 172.30.250.4 ;;
        esac
        ;;
      *'{{if ne $k'*) echo '172.28.0.49 ' ;;
      *'{{$k}} {{end}}'*) echo 'yams_yams_hub_ctl ' ;;
      '{{.Name}} {{.HostConfig.NetworkMode}}')
        get netmodes "$(printf '%s\n' '/sonarr yams_network' '/yams-hub yams_network' \
          "/qbittorrent container:$(id_of gluetun)")"
        echo
        ;;
    esac
    ;;
  ps) printf '%s\n' c1 c2 c3 ;;
  exec)
    if [[ $2 == socket-proxy-hub && "${*:3}" == 'cat /run/haproxy/haproxy.cfg' ]]; then
      get rendered
    elif [[ $2 == prowlarr && $3 == curl ]]; then
      if [[ $(get prowlarr_curl) == missing ]]; then
        echo 'OCI runtime exec failed: exec: "curl": executable file not found in $PATH' >&2
        exit 126
      fi
      shift 3
      fake_curl "$@"
    else
      exit 1
    fi
    ;;
  *) ;;
esac
