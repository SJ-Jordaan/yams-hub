#!/usr/bin/env bash
# Builds the YAMS Hub web app into app/build/web (and, with --apk, the Android APKs).
#
#   ./build.sh          web app (needed by install.sh)
#   ./build.sh --apk    web app + release APKs, one per ABI (needs the Android SDK and a JDK)
#
# Flutter: the `flutter` on PATH, else ~/development/env.sh, else the pinned Flutter SDK is
# downloaded once into ${XDG_CACHE_HOME:-~/.cache}/yams-hub/flutter (Linux x64 or macOS).
set -euo pipefail

FLUTTER_VERSION=3.47.9
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/yams-hub"
RELEASES=https://storage.googleapis.com/flutter_infra_release/releases

apk=0
for arg in "$@"; do
  case "$arg" in
    --apk) apk=1 ;;
    -h | --help)
      sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg (see --help)" >&2
      exit 2
      ;;
  esac
done

die() {
  printf 'build.sh: ERROR: %s\n' "$*" >&2
  exit 1
}

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# Downloads and unpacks the pinned SDK into $CACHE/flutter.
download_flutter() {
  local os arch archive hash tmp
  os=$(uname -s) arch=$(uname -m)
  case "$os/$arch" in
    Linux/x86_64)
      archive=linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz
      hash=25ed8c3c29d51a7353f2a944310b478af8214920639524b19c50a19e6c044c5a
      ;;
    Darwin/arm64)
      archive=macos/flutter_macos_arm64_${FLUTTER_VERSION}-stable.zip
      hash=6545b85938745dc5070e9faf2adf70233c1811009d87fe6d27bfcda5a04b7698
      ;;
    Darwin/x86_64)
      archive=macos/flutter_macos_${FLUTTER_VERSION}-stable.zip
      hash=0dc38b4038a0b002a6258696a5b327a58473c175c9e334b9f329ef7d79a4fdcd
      ;;
    *) die "no Flutter SDK download for $os/$arch: build on an x64 Linux or a macOS machine and copy app/build/web over" ;;
  esac
  # Checked before the download: curl fetches it, tar needs xz (Linux), and Flutter itself needs git and unzip.
  local t missing=()
  for t in curl git unzip; do command -v "$t" >/dev/null || missing+=("$t"); done
  if [[ $archive == *.tar.xz ]] && ! command -v xz >/dev/null; then missing+=(xz); fi
  ((${#missing[@]} == 0)) ||
    die "Flutter needs: ${missing[*]} (Debian/Ubuntu: apt install curl git unzip xz-utils)"
  echo "Flutter $FLUTTER_VERSION was not found; downloading the official SDK (about 1 GB, once):"
  echo "  $RELEASES/stable/$archive"
  echo "  -> $CACHE/flutter"
  mkdir -p "$CACHE"
  tmp=$(mktemp -d "$CACHE/download.XXXXXX")
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fL --progress-bar -o "$tmp/sdk" "$RELEASES/stable/$archive" || die 'download failed'
  [[ $(sha256 "$tmp/sdk") == "$hash" ]] || die 'the download does not match the pinned SHA-256; not using it'
  mkdir "$tmp/x"
  if [[ $archive == *.zip ]]; then
    unzip -q "$tmp/sdk" -d "$tmp/x"
  else
    # As root, tar would keep the archive's owner (uid 1000), and git then refuses the SDK checkout as "dubious".
    tar --no-same-owner -xJf "$tmp/sdk" -C "$tmp/x"
  fi
  rm -rf -- "$CACHE/flutter"
  mv "$tmp/x/flutter" "$CACHE/flutter"
  rm -rf -- "$tmp"
  trap - EXIT
}

# --- Flutter -------------------------------------------------------------------------------------
if ! command -v flutter >/dev/null && [[ -f $HOME/development/env.sh ]]; then
  set +eu
  # shellcheck disable=SC1091
  source "$HOME/development/env.sh"
  set -eu
fi
if ! command -v flutter >/dev/null; then
  [[ -x $CACHE/flutter/bin/flutter ]] || download_flutter
  export PATH="$CACHE/flutter/bin:$PATH"
fi
export FLUTTER_SUPPRESS_ANALYTICS=true
flutter --disable-analytics >/dev/null 2>&1 || true

version=$(flutter --version 2>/dev/null | sed -n 's/^Flutter \([0-9.]*\).*/\1/p' | head -n1)
if [[ $version != "$FLUTTER_VERSION" ]]; then
  echo "WARNING: $(command -v flutter) is Flutter ${version:-unknown}; this repo is tested with $FLUTTER_VERSION" >&2
fi

# --- Android preflight (before the slow web build) -----------------------------------------------
if ((apk)); then
  java_ok=0
  if [[ -n ${JAVA_HOME:-} && -x $JAVA_HOME/bin/java ]] || command -v java >/dev/null; then java_ok=1; fi
  sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
  if [[ -z $sdk ]]; then
    for d in "$HOME/Android/Sdk" "$HOME/Library/Android/sdk"; do
      if [[ -d $d ]]; then sdk=$d; fi
    done
  fi
  if ((!java_ok)) || [[ -z $sdk || ! -d $sdk ]]; then
    {
      echo 'build.sh: --apk needs a JDK (17 or 21) and the Android SDK, and this machine is missing:'
      ((java_ok)) || echo '  - a JDK: install one (e.g. openjdk-21-jdk) or set JAVA_HOME'
      [[ -n $sdk && -d $sdk ]] || echo '  - the Android SDK: install Android Studio (or the command-line tools) and set ANDROID_HOME'
      echo 'Alternatively, ask the maintainer for the APK.'
    } >&2
    exit 1
  fi
  export ANDROID_HOME=$sdk
fi

# --- Build ---------------------------------------------------------------------------------------
cd "$ROOT/app"
flutter pub get --enforce-lockfile
echo '==> flutter build web'
flutter build web --release --no-web-resources-cdn
find build/web -name '*.symbols' -delete

if ((apk)); then
  echo '==> flutter build apk --split-per-abi'
  # Signed with the release key when key.properties exists (app/android/app/build.gradle.kts),
  # otherwise with the debug key.
  flutter build apk --release --split-per-abi
fi

echo
echo 'Built:'
echo "  web app  $ROOT/app/build/web"
if ((apk)); then
  for f in "$ROOT"/app/build/app/outputs/flutter-apk/app-*-release.apk; do
    [[ -e $f ]] && echo "  APK      $f"
  done
  echo '  (most phones need app-arm64-v8a-release.apk)'
fi
echo
echo 'Next: ./install.sh on the YAMS server (or ./install.sh --update after a git pull).'
