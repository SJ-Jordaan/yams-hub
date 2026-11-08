# Mobile web benchmark (`tool/perf`)

A reproducible benchmark of the gateway-served Flutter web build on an emulated phone. It runs the **real gateway**
against **mock upstreams** (no NAS, no live services), drives the **release** web build in Chromium with Pixel 7
emulation and 4x CPU throttling, and records startup, jank, navigation and the poster-grid image behaviour. A second
pass on the **profile** build records Chromium traces with readable Dart names.

```sh
tool/perf/run.sh --label baseline      # writes tool/perf/baseline.json + results/baseline.json
tool/perf/run.sh --label after         # after a fix: results/after.json, compared with baseline.json
```

Options: `--repeat N` (default 3 release runs, medians are reported), `--skip-build` (reuse the builds in `PERF_OUT`),
`--no-profile`, `--no-safari-path`, `--cpu 4`, `--gpu hw|swiftshader`. A full run takes ~15 minutes.

`run.sh` always builds the **current working tree** (`flutter build web --release --no-web-resources-cdn`, the
same flags as `deploy/deploy.sh`, plus `--profile --source-maps`) and recompiles the gateway, so a re-run after a fix
measures the fix. Builds, traces, screenshots and logs go to `PERF_OUT` (default `${TMPDIR:-/tmp}/yams-hub-perf`),
one directory per label.

## Set-up

`run.sh` calls `setup.sh`, which (idempotently) creates `~/development/perf-venv` (`playwright`, `pillow`) and
installs Playwright's Chromium into `~/development/ms-playwright`. Flutter/Dart come from `~/development/env.sh`.

## Pieces

| File | What it does |
|---|---|
| `run.sh` | One command: build, start the stack, run the bench N times + variants, aggregate, compare |
| `stack.sh start\|stop <dir> [web-dir]` | Mock upstreams + a local gateway (`127.0.0.1:18090`, fresh data dir, dummy secrets, bootstrap admin `admin` / `perf-bench-pass`) |
| `mock_upstreams.py` | Sonarr, Radarr, Prowlarr, Bazarr, Seerr, Jellyfin, Jellystat, qBittorrent, Gluetun, Docker proxy, Watchtower, Uptime Kuma, Audiobookshelf, Shelfmark on ports 18100-18113, answering from `fixtures/` |
| `bench.py` | The Playwright driver and the measurements |
| `trace_summary.py` | Chromium trace -> main-thread categories, top JS functions/files (source-mapped), Flutter timeline phases, per-thread busy time |
| `aggregate.py` | Medians over the runs, `results/<label>.json`, comparison with `baseline.json` |

Poke at the app by hand: `tool/perf/stack.sh start /tmp/stack /path/to/web-build`, open `http://127.0.0.1:18090/`
(log in as `admin` / `perf-bench-pass`), `tool/perf/stack.sh stop /tmp/stack`.

### Mock data

The fixtures hold ~5 records per list; the mock amplifies the main lists by cloning records with new ids
(`--scale 1`: 120 movies, 60 series, 20 Discover results per page over 10 pages, 60 requests). Seerr clones get real
TMDB poster paths from the fixtures, so the gateway's image proxy fetches real images from `image.tmdb.org` (the
machine needs internet for those; everything else is local). *arr `MediaCover` images are generated JPEGs: by default
every poster variant is 1000x1500 (~300 KB, `--poster-mode full`); `--poster-mode arr` serves what a real *arr
serves (`poster-500.jpg` is 500x750). Jellyfin images honour `fillHeight`/`maxWidth`. Unknown upstream requests are
logged as `UNMATCHED` in `<stack-dir>/unmatched.log` and answered with `[]`. Pass mock options with
`PERF_MOCK_ARGS="--scale 2"`.

## What is measured

Chromium (Playwright's build, new headless) with the Pixel 7 profile (412x839 CSS px viewport, DPR 2.625, touch,
mobile UA), `Emulation.setCPUThrottlingRate(4)`, the host GPU through ANGLE/GL (`--gpu swiftshader` for software
GL; headless screenshots of the Flutter canvas work with both). A fresh browser context and a fresh gateway data dir
per run (cold caches).

Frame timing comes from an init script: its own `requestAnimationFrame` loop while sampling (rAF deltas = the frame
rate the user sees) and a wrapper around `window.requestAnimationFrame` that times each Flutter frame callback
(build + layout + paint + CanvasKit submission). Long tasks come from `PerformanceObserver('longtask')`, CPU time from
CDP `Performance.getMetrics`, network from CDP `Network.*` (it sees memory/disk-cache hits and cancellations), image
decodes from wrappers around WebCodecs `ImageDecoder.decode` and `HTMLImageElement.decode`.

| Phase | Measures |
|---|---|
| `boot` | cold load -> first Flutter frame -> login screen idle; transfer sizes of main.dart.js / CanvasKit |
| `login` | keyboard login (Tab, type, Enter): login response, `/dashboard` response, first dashboard frame, settled (no Flutter frame for 1 s and no request in flight), jank and requests meanwhile |
| `dashboard` | touch scroll top -> bottom -> top (3 + 3 swipes, ~6 s): rAF p50/p90/p99, frames > 32/50/100 ms, Flutter frame cost, long tasks, script time |
| `tabs` | Requests, Library, Activity (bottom-bar taps), System (router navigation), Home: first frame, time to settle, jank while settling, then a short scroll |
| `images` | Library poster grids, scrolled to the bottom and back to the top; screenshots before / 0 s / 2 s / 6 s after, pixel diff of the grid area, network requests on the way back, decode counts. Scenarios: `movies_fast` (fast flings over posters that are still loading), `tv` (60 posters, fit Flutter's 100 MB ImageCache), `movies` (120 posters, more than the cache holds) |

Variants run by `run.sh`:

* **Safari/iOS image path** (`bench.py --no-image-decoder`): hides WebCodecs `ImageDecoder`, so the Flutter engine
  decodes images through `<img>` exactly as it does on Safari/iOS (and Firefox). Playwright's WebKit does not run on
  this host (missing system libraries), so this is the closest available stand-in for an iPhone.
* **Profile build + traces**: `dashboard` and the `movies` grid are traced (Chromium `devtools.timeline` + V8 CPU
  profiler); `trace_summary.py` maps `main.dart.js` frames through the source map and CanvasKit wasm frames through
  `canvaskit.js.symbols`, and extracts Flutter's own timeline phases (BUILD / LAYOUT / PAINT / COMPOSITING). The
  profile build adds `performance.mark/measure` overhead (`mark`/`measure` native frames); ignore those.

### Caveats

* 4x throttling of a fast desktop CPU approximates a mid-range phone's main thread; the desktop GPU is much faster than
  a phone GPU, so raster/texture-upload costs are underestimated. Compare runs with each other, not with a device.
* Login includes the gateway's PBKDF2 verification (~1.5 s for a 600 000-iteration hash on this host);
  `login.dashboard_frame_after_login_ms` and `login.client_after_login_to_settled_ms` exclude it.
* TMDB images come from the internet; the first run after a fresh data dir pays their latency.
* Fonts: the gateway's CSP blocks Flutter's fallback-font fetches from `fonts.gstatic.com` (counted in
  `console_summary.font_fallback_fetch_failures`); the same happens in production.

## Baseline (2026-11-08)

`run.sh --label baseline --repeat 3` on Chromium 156 (Playwright), Pixel 7 emulation, 4x CPU throttle, host GPU,
release build of the current tree, `--scale 1` mock data, 1000x1500 MediaCover posters. Medians of 3 runs (they agree
within a few %); everything is in `baseline.json`.

**Images (issue 1).** Reproduced, on the Safari/iOS decode path only:

* Safari/iOS path (`--no-image-decoder`): after the Movies grid is scrolled away and back, the top posters stay on the
  placeholder (grid pixel diff vs before 37.7 after 6 s; 0 requests for the previously loaded URLs, matching the
  hub's access log). TV (60 posters) recovers; Movies after fast flings and after a slow round trip does not.
  Cause, confirmed by hooking CanvasKit: on re-entry `cached_network_image` 3.4.1's `MultiImageStreamCompleter.addListener`
  calls `codec.getNextFrame()` again whenever its listener count goes 0 -> 1 (Flutter's own completer only does
  that when it has no current image). On the `<img>` codec the first frame was already resized (`memCacheHeight` ->
  `CkResizingCodec`) and the original image disposed, which sets the shared `<img>`'s `src` to `''`; the second
  `getNextFrame` reads a 0x0 element, `MakeLazyImageFromTextureSource` returns null (60 such calls on one scroll back)
  and the good image is replaced by nothing. `cached_network_image` 4.x guards this (`_framesEmitted == 0 ||
  frameCount > 1`).
* Chromium path (WebCodecs `ImageDecoder`, i.e. Android Chrome): posters reappear, but every re-entry re-decodes the
  full 1000x1500 JPEG and re-scales it: 186 decodes (~280 Mpix) for one round trip over the 120-poster grid with
  0 network requests.

**Smoothness (issue 2).** On this emulated phone the Chromium build is mostly smooth while scrolling; the cost is in
big one-off frames and in image decoding:

| Metric | Baseline |
|---|---|
| boot: Flutter view / first frame / login screen idle | 1598 / 1620 / 2315 ms |
| login: first dashboard frame after the login response | 476 ms |
| login: settled after the login response | 2028 ms, 5 frames > 50 ms, 797 ms of long tasks, worst Flutter frame 365 ms |
| dashboard scroll (6 s) | 58.2 fps, rAF p50/p90/p99 16.7/17.7/28.9 ms, 3 frames > 32 ms, 0 > 100 ms, 184 ms long tasks, 3.1 s script |
| tab first frame / settled | Requests 169/1551, Library 111/1273, Activity 103/542, System 125/522, Home 119/546 ms |
| worst frame when opening a tab | Requests 121, Library 109, System 140, Home 92 ms |
| poster grid scroll (Chromium path) | 57-60 fps, 0-1 frames > 32 ms |
| poster grid scroll (Safari path) | 19 fps (fast flings), 36.5 fps (TV), p90 62-89 ms, `<img>` decode p50 42-57 ms |
| JS heap at the end | 59 MB |

Profile-build traces (`profile_build_traces` in `baseline.json`): the dashboard's first frame after login is one
~500 ms Flutter frame (LAYOUT 401 ms, BUILD 190 ms) because the dashboard builds and lays out every card in a
non-lazy `Column`; during the dashboard scroll the main thread is 71 % busy, mostly CanvasKit (wasm 25 %,
`canvaskit.js` 14 %, text-blob drawing at the top) plus Flutter paint/composite (Frame p90 11.5 ms of which
COMPOSITING ~4 ms, PAINT ~6 ms); in the Library grid scroll `drawImage` (re-scaling the re-decoded posters) and
`createImageBitmap` are the largest single native costs and LAYOUT runs ~5.5 ms per frame. 15 fallback-font fetches
per session are blocked by the CSP (Noto Sans Symbols 2 / SC / TC).
