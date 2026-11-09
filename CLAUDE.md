# YAMS Hub: notes for Claude

A Dart gateway (`gateway/`), a privileged updater sidecar (`updater/`), shared models (`packages/yams_models/`) and a
Flutter app (`app/`) that run next to a YAMS media server. Design docs: `docs/` (start with `docs/DEVELOPMENT.md`;
the API contract is `docs/API.md`).

## Toolchain

Every shell needs `source ~/development/env.sh` (Flutter 3.47.9, Dart 3.13.7). In CI, subosito/flutter-action
provides the same versions. Never run `pub upgrade`; the lock files are committed.

## Tests

```sh
(cd packages/yams_models && dart analyze --fatal-infos && dart test)
(cd gateway && dart analyze --fatal-infos && dart test)
(cd updater && dart analyze --fatal-infos && dart test)
(cd app && flutter analyze && flutter test)
bash install/test/install_test.sh      # install.sh against a fake docker (runs shellcheck when installed)
  # no local shellcheck? CI=true fails on a skipped one; or: docker run --rm -v "$PWD:/mnt:ro" -w /mnt \
  #   koalaman/shellcheck:v0.11.0 -x install.sh build.sh install/test/*.sh tool/sandbox/run.sh
bash deploy/test/deploy_test.sh        # the maintainer's deploy scripts against fakes
tool/check_all.sh                      # all the Dart/Flutter checks plus the Docker image smoke builds
./build.sh && tool/sandbox/run.sh      # end to end: real install.sh + hub against a disposable stock YAMS
tool/sandbox/run.sh --variant vpn-on   # the same with qBittorrent behind gluetun
```

All of these must stay green. The sandbox (`tool/sandbox/`, see "Testing changes" in `docs/DEVELOPMENT.md`) needs
Docker; `KEEP=1` leaves it running, `tool/sandbox/run.sh down` removes it. CI runs it for pull requests
(`.github/workflows/sandbox.yml`).

## Rules

- Do not touch `deploy/`: it is the maintainer's own NAS deployment. Never ssh anywhere.
- No secrets in the repo, in argv or in logs. Never read or touch `~/development/keys` (the Android signing key) or
  any `*.env` / `secrets/` file. Sandbox passwords are throwaway values generated into its cache dir.
- Keep changes backwards compatible with the maintainer's NAS deploy (`deploy/`) and with existing installs made by
  `install.sh` (re-runs keep secrets, admin and port; YAMS's own compose files and containers are never changed).
- Fix bugs with a test that fails before the fix.
- Commits end with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Work on a branch and open
  a pull request; do not push to `main` directly.
