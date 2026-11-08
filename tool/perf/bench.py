#!/usr/bin/env python3
"""Mobile-web benchmark of the YAMS Hub Flutter web build (tool/perf).

Drives a gateway-served web build in Chromium with Pixel 7 emulation (412x839
CSS px viewport, DPR 2.625, touch, mobile UA) and CDP CPU throttling (4x by
default, ~ a mid-range phone) and measures:

  boot       cold load -> first Flutter frame -> login screen idle
  login      Enter on the login form -> /dashboard answered -> first dashboard
             frame -> settled (no Flutter frame for 1 s and no request in flight)
  dashboard  touch-scroll top -> bottom -> top (~5 s): rAF frame deltas,
             Flutter frame (rAF callback) cost, long tasks, CDP Performance
             metrics; optional Chromium trace
  tabs       Requests, Library, Activity (bottom bar taps), System (router
             navigation): time to settle + jank while settling
  images     Library poster grid: scroll far down and back to the top, then
             check (screenshots + pixel statistics + network log) whether the
             posters are painted again

Frame timing comes from an init script that (1) runs its own
requestAnimationFrame loop while sampling (deltas = what the user sees) and
(2) wraps window.requestAnimationFrame so each Flutter frame's callback time
(build + layout + paint + CanvasKit raster submission) is recorded.

Usage (normally via run.sh):
  bench.py --url http://127.0.0.1:18090/ --out DIR [--label L] [--cpu 4]
           [--trace] [--phases boot,login,dashboard,tabs,images]
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import statistics
import sys
import time
from pathlib import Path

from playwright.async_api import async_playwright

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import trace_summary  # noqa: E402

USERNAME = os.environ.get("PERF_USERNAME", "admin")
PASSWORD = os.environ.get("PERF_PASSWORD", "perf-bench-pass")

INIT_JS = r"""
(() => {
  if (window.__perf) return;
  const origRAF = window.requestAnimationFrame.bind(window);
  const P = window.__perf = {
    frames: [], flutter: [], longtasks: [], sampling: false, loopOn: false,
    lastFlutterEnd: 0, flutterCount: 0, errors: [],
  };
  window.requestAnimationFrame = function (cb) {
    return origRAF(function (ts) {
      const t0 = performance.now();
      try { return cb(ts); } finally {
        const t1 = performance.now();
        P.flutter.push([t0, t1 - t0]);
        P.lastFlutterEnd = t1;
        P.flutterCount++;
        if (P.flutter.length > 40000) P.flutter.splice(0, 20000);
      }
    });
  };
  let last = 0;
  function tick(ts) {
    if (!P.sampling) { P.loopOn = false; last = 0; return; }
    const now = performance.now();
    if (last) P.frames.push([now, now - last]);
    last = now;
    origRAF(tick);
  }
  // When the Flutter view element appears (engine initialised, runApp started).
  P.viewAt = 0;
  new MutationObserver((muts, obs) => {
    if (document.querySelector('flutter-view, flt-glass-pane')) { P.viewAt = performance.now(); obs.disconnect(); }
  }).observe(document, { childList: true, subtree: true });
  P.start = () => { P.sampling = true; if (!P.loopOn) { P.loopOn = true; last = 0; origRAF(tick); } };
  P.stop = () => { P.sampling = false; };
  try {
    new PerformanceObserver((l) => {
      for (const e of l.getEntries()) P.longtasks.push([e.startTime, e.duration]);
    }).observe({ type: 'longtask', buffered: true });
  } catch (e) {}
  window.addEventListener('error', (e) => P.errors.push(String(e.message || e)));
  // Image decoding: WebCodecs ImageDecoder (Chromium path) / <img>.decode()
  // (Safari / Firefox path). Records [start, ms, width, height].
  P.decodes = [];
  if (window.__perfNoImageDecoder) { try { delete window.ImageDecoder; window.ImageDecoder = undefined; } catch (e) {} }
  if (window.ImageDecoder) {
    const ID = window.ImageDecoder;
    const origDecode = ID.prototype.decode;
    ID.prototype.decode = function (opts) {
      const t0 = performance.now();
      return origDecode.call(this, opts).then((r) => {
        try { P.decodes.push([t0, performance.now() - t0, r.image.codedWidth, r.image.codedHeight, 'ImageDecoder']); } catch (e) {}
        return r;
      });
    };
  }
  const imgDecode = HTMLImageElement.prototype.decode;
  HTMLImageElement.prototype.decode = function () {
    const t0 = performance.now(); const el = this;
    return imgDecode.call(this).then((r) => { P.decodes.push([t0, performance.now() - t0, el.naturalWidth, el.naturalHeight, 'img']); return r; });
  };
})();
"""


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = (len(s) - 1) * p / 100
    f, c = math.floor(k), math.ceil(k)
    if f == c:
        return round(s[int(k)], 2)
    return round(s[f] + (s[c] - s[f]) * (k - f), 2)


class Net:
    """CDP network log (sees memory/disk-cache hits and cancellations)."""

    def __init__(self):
        self.reqs: dict[str, dict] = {}
        self.order: list[str] = []

    def attach(self, cdp):
        cdp.on("Network.requestWillBeSent", self._sent)
        cdp.on("Network.requestServedFromCache", self._cache)
        cdp.on("Network.responseReceived", self._resp)
        cdp.on("Network.loadingFinished", self._fin)
        cdp.on("Network.loadingFailed", self._fail)

    def _sent(self, e):
        rid = e["requestId"]
        self.reqs[rid] = {
            "url": e["request"]["url"], "method": e["request"]["method"],
            "t": e["timestamp"], "mono": time.monotonic(), "state": "pending", "cache": None,
            "status": None, "type": e.get("type"),
        }
        self.order.append(rid)

    def _cache(self, e):
        r = self.reqs.get(e["requestId"])
        if r:
            r["cache"] = "memory"

    def _resp(self, e):
        r = self.reqs.get(e["requestId"])
        if r:
            resp = e["response"]
            r["status"] = resp.get("status")
            if resp.get("fromDiskCache"):
                r["cache"] = "disk"
            if resp.get("fromServiceWorker"):
                r["cache"] = "sw"
            if resp.get("fromPrefetchCache"):
                r["cache"] = "prefetch"

    def _fin(self, e):
        r = self.reqs.get(e["requestId"])
        if r:
            r["state"] = "done"
            r["end"] = e["timestamp"]
            r["bytes"] = e.get("encodedDataLength")

    def _fail(self, e):
        r = self.reqs.get(e["requestId"])
        if r:
            r["state"] = "canceled" if e.get("canceled") else "failed"
            r["end"] = e["timestamp"]
            r["error"] = e.get("errorText")

    def inflight(self, pred=lambda u: True, stale_s=10.0):
        """Requests still loading. Error responses whose body the app never
        reads (they never finish in CDP) and requests older than stale_s are
        not counted."""
        now = time.monotonic()
        return sum(1 for r in self.reqs.values()
                   if r["state"] == "pending" and pred(r["url"]) and not r["url"].startswith("data:")
                   and not (r["status"] or 0) >= 400 and now - r["mono"] < stale_s)

    def mark(self):
        return len(self.order)

    def since(self, mark, pred=lambda u: True):
        return [self.reqs[rid] for rid in self.order[mark:] if pred(self.reqs[rid]["url"])]


def is_img(u: str) -> bool:
    return "/api/v1/img/" in u


def is_api(u: str) -> bool:
    return "/api/v1/" in u and not is_img(u)


def summarize_reqs(reqs):
    out = {"count": len(reqs), "done": 0, "canceled": 0, "failed": 0, "pending": 0,
           "from_cache": 0, "unique_urls": len({r["url"] for r in reqs}), "bytes": 0}
    for r in reqs:
        out[r["state"]] = out.get(r["state"], 0) + 1
        if r["cache"]:
            out["from_cache"] += 1
        out["bytes"] += r.get("bytes") or 0
    return out


class Bench:
    def __init__(self, args):
        self.a = args
        self.out = Path(args.out)
        self.out.mkdir(parents=True, exist_ok=True)
        self.res: dict = {"label": args.label, "cpu_throttle": args.cpu, "url": args.url}
        self.console: list[str] = []
        self.net = Net()

    # -- page helpers -------------------------------------------------------
    async def now(self) -> float:
        return await self.page.evaluate("performance.now()")

    async def start_sampling(self):
        await self.page.evaluate("window.__perf.start()")
        return await self.now()

    async def stop_sampling(self):
        await self.page.evaluate("window.__perf.stop()")
        return await self.now()

    async def perf_metrics(self):
        m = await self.cdp.send("Performance.getMetrics")
        return {x["name"]: x["value"] for x in m["metrics"]}

    async def window_stats(self, t0, t1):
        data = await self.page.evaluate(
            """([t0, t1]) => {
              const P = window.__perf;
              return {
                frames: P.frames.filter(f => f[0] >= t0 && f[0] <= t1).map(f => f[1]),
                flutter: P.flutter.filter(f => f[0] >= t0 && f[0] <= t1).map(f => f[1]),
                longtasks: P.longtasks.filter(l => l[0] + l[1] >= t0 && l[0] <= t1).map(l => l[1]),
                decodes: (P.decodes || []).filter(d => d[0] >= t0 && d[0] <= t1),
              };
            }""",
            [t0, t1],
        )
        fr, fl, lt = data["frames"], data["flutter"], data["longtasks"]
        dec = data.get("decodes") or []
        dur = (t1 - t0) / 1000
        return {
            "duration_ms": round(t1 - t0, 1),
            "raf_frames": len(fr),
            "fps": round(len(fr) / dur, 1) if dur > 0 else None,
            "frame_ms_p50": pct(fr, 50), "frame_ms_p90": pct(fr, 90), "frame_ms_p99": pct(fr, 99),
            "frame_ms_max": round(max(fr), 1) if fr else None,
            "frames_over_32ms": sum(1 for d in fr if d > 32),
            "frames_over_50ms": sum(1 for d in fr if d > 50),
            "frames_over_100ms": sum(1 for d in fr if d > 100),
            "time_in_frames_over_32ms_ms": round(sum(d for d in fr if d > 32), 1),
            "flutter_frames": len(fl),
            "flutter_frame_ms_p50": pct(fl, 50), "flutter_frame_ms_p90": pct(fl, 90),
            "flutter_frame_ms_p99": pct(fl, 99),
            "flutter_frame_ms_max": round(max(fl), 1) if fl else None,
            "flutter_frame_ms_total": round(sum(fl), 1),
            "longtasks": len(lt), "longtask_ms_total": round(sum(lt), 1),
            "longtask_ms_max": round(max(lt), 1) if lt else None,
            "image_decodes": len(dec),
            "image_decode_ms_p50": pct([d[1] for d in dec], 50),
            "image_decode_mpix_total": round(sum(d[2] * d[3] for d in dec) / 1e6, 1),
        }

    async def wait_settled(self, quiet_ms=1000, timeout_ms=20000, pred=lambda u: True):
        """Until no Flutter frame for quiet_ms and no matching request in flight."""
        t_start = await self.now()
        while True:
            st = await self.page.evaluate("[performance.now(), window.__perf.lastFlutterEnd]")
            now, last = st
            if now - max(last, t_start) >= quiet_ms and self.net.inflight(pred) == 0:
                return {"settled": True, "settled_at": max(last, t_start)}
            if now - t_start > timeout_ms:
                return {"settled": False, "settled_at": now}
            await asyncio.sleep(0.1)

    async def shot(self, name):
        p = self.out / f"{name}.png"
        await self.page.screenshot(path=str(p))
        return p

    async def tap(self, x, y):
        await self.page.touchscreen.tap(x, y)

    async def scroll(self, dy, x=None, y=None, speed=1800, fling=True):
        """Touch scroll gesture; dy > 0 scrolls the content down (finger up)."""
        vw, vh = self.vw, self.vh
        await self.cdp.send("Input.synthesizeScrollGesture", {
            "x": x if x is not None else vw // 2,
            "y": y if y is not None else int(vh * 0.6),
            "xDistance": 0, "yDistance": -dy, "speed": speed,
            "gestureSourceType": "touch", "preventFling": not fling,
        })

    async def first_flutter_frame_after(self, t):
        return await self.page.evaluate(
            "(t) => { const f = window.__perf.flutter.find(f => f[0] >= t); return f ? f[0] + f[1] : null; }", t)

    # -- phases -------------------------------------------------------------
    async def phase_boot(self):
        t_nav = time.time()
        await self.page.goto(self.a.url, wait_until="load")
        # the login screen: wait for the first Flutter frames, then idle
        await self.page.wait_for_function(
            "() => !!(window.__perf && window.__perf.viewAt && window.__perf.flutter.some(f => f[0] >= window.__perf.viewAt))",
            timeout=60000)
        view_at = await self.page.evaluate("window.__perf.viewAt")
        first = await self.first_flutter_frame_after(view_at)
        s = await self.wait_settled(quiet_ms=800, timeout_ms=30000)
        nav = await self.page.evaluate(
            "(() => { const n = performance.getEntriesByType('navigation')[0]; return n ? {dcl: n.domContentLoadedEventEnd, load: n.loadEventEnd, transfer: n.transferSize} : {}; })()")
        res_sizes = await self.page.evaluate(
            "performance.getEntriesByType('resource').filter(r => /main\\.dart\\.js|canvaskit|\\.wasm|\\.ttf|\\.otf/.test(r.name)).map(r => [r.name.split('/').slice(-2).join('/'), Math.round(r.duration), r.encodedBodySize])")
        self.res["boot"] = {
            "flutter_view_ms": round(view_at, 1),
            "first_flutter_frame_ms": round(first, 1),
            "login_screen_idle_ms": round(s["settled_at"], 1),
            "settled": s["settled"],
            "dom_content_loaded_ms": round(nav.get("dcl", 0), 1),
            "load_event_ms": round(nav.get("load", 0), 1),
            "resources": res_sizes,
            "wall_s": round(time.time() - t_nav, 2),
        }
        await self.shot("01-login")

    async def phase_login(self):
        page = self.page
        await page.keyboard.press("Tab")
        await page.keyboard.type(USERNAME)
        await page.keyboard.press("Tab")
        await page.keyboard.type(PASSWORD)
        await asyncio.sleep(0.3)
        await self.wait_settled(quiet_ms=300, timeout_ms=5000)
        if self.a.trace:
            await self.browser.start_tracing(page=page, path=str(self.out / "trace-login.json"),
                                             categories=trace_summary.CATEGORIES)
            await asyncio.sleep(2.0)  # let the profiler start-up cost pass
        mark = self.net.mark()
        m0 = await self.perf_metrics()
        t0 = await self.start_sampling()
        await page.evaluate("performance.mark('perf:window-start')")
        async with page.expect_response(lambda r: "/auth/login" in r.url, timeout=30000) as login_info:
            async with page.expect_response(lambda r: r.url.split("?")[0].endswith("/api/v1/dashboard"), timeout=60000) as dash_info:
                await page.keyboard.press("Enter")
                login_resp = await login_info.value
                t_login = await self.now()
            dash = await dash_info.value
            await dash.finished()
        t_dash = await self.now()
        s = await self.wait_settled(quiet_ms=1000, timeout_ms=30000)
        await page.evaluate("performance.mark('perf:window-end')")
        t1 = await self.stop_sampling()
        if self.a.trace:
            await self.browser.stop_tracing()
        first_dash_frame = await self.first_flutter_frame_after(t_dash)
        m1 = await self.perf_metrics()
        reqs = self.net.since(mark)
        self.res["login"] = {
            "login_status": login_resp.status,
            "login_response_ms": round(t_login - t0, 1),
            "dashboard_response_ms": round(t_dash - t0, 1),
            "first_dashboard_frame_ms": round(first_dash_frame - t0, 1) if first_dash_frame else None,
            "settled_ms": round(s["settled_at"] - t0, 1),
            "settled": s["settled"],
            "client_after_login_to_settled_ms": round(s["settled_at"] - t_login, 1),
            "api_requests": summarize_reqs([r for r in reqs if is_api(r["url"])]),
            "img_requests": summarize_reqs([r for r in reqs if is_img(r["url"])]),
            "jank": await self.window_stats(t0, t1),
            "cdp": diff_metrics(m0, m1),
        }
        await self.shot("02-dashboard")

    async def phase_dashboard(self, trace_path=None):
        # make sure we are at the top and idle
        await self.scroll(-6000, speed=6000)
        await self.wait_settled(quiet_ms=800, timeout_ms=10000)
        if trace_path:
            await self.browser.start_tracing(page=self.page, path=str(trace_path), categories=trace_summary.CATEGORIES)
            await asyncio.sleep(2.0)  # let the profiler start-up cost pass
        m0 = await self.perf_metrics()
        mark = self.net.mark()
        t0 = await self.start_sampling()
        await self.page.evaluate("performance.mark('perf:window-start')")
        for _ in range(3):
            await self.scroll(1400, speed=2200)
        await asyncio.sleep(0.6)
        await self.shot("03-dashboard-bottom") if not trace_path else None
        for _ in range(3):
            await self.scroll(-1400, speed=2200)
        await asyncio.sleep(0.8)
        await self.page.evaluate("performance.mark('perf:window-end')")
        t1 = await self.stop_sampling()
        m1 = await self.perf_metrics()
        if trace_path:
            await self.browser.stop_tracing()
        reqs = self.net.since(mark)
        self.res["dashboard_scroll" + ("_traced" if trace_path else "")] = {
            "jank": await self.window_stats(t0, t1),
            "cdp": diff_metrics(m0, m1),
            "img_requests": summarize_reqs([r for r in reqs if is_img(r["url"])]),
            "api_requests": summarize_reqs([r for r in reqs if is_api(r["url"])]),
        }

    async def nav_tab(self, name, action):
        await self.wait_settled(quiet_ms=500, timeout_ms=8000)
        mark = self.net.mark()
        m0 = await self.perf_metrics()
        t0 = await self.start_sampling()
        await action()
        t_act = await self.now()
        first = None
        s = await self.wait_settled(quiet_ms=1000, timeout_ms=15000)
        t1 = await self.stop_sampling()
        first = await self.first_flutter_frame_after(t_act)
        m1 = await self.perf_metrics()
        reqs = self.net.since(mark)
        r = {
            "first_frame_ms": round(first - t0, 1) if first else None,
            "settled_ms": round(s["settled_at"] - t0, 1),
            "settled": s["settled"],
            "jank": await self.window_stats(t0, t1),
            "cdp": diff_metrics(m0, m1),
            "api_requests": summarize_reqs([x for x in reqs if is_api(x["url"])]),
            "img_requests": summarize_reqs([x for x in reqs if is_img(x["url"])]),
        }
        await self.shot(f"04-tab-{name}")
        # scroll the tab a bit to measure its jank too
        t2 = await self.start_sampling()
        await self.scroll(1400, speed=2200)
        await self.scroll(-1400, speed=2200)
        await asyncio.sleep(0.6)
        t3 = await self.stop_sampling()
        r["scroll_jank"] = await self.window_stats(t2, t3)
        return r

    def bottom(self, i):
        return (int(self.vw * (i + 0.5) / 5), self.vh - 40)

    async def go_route(self, path):
        await self.page.evaluate(
            "(p) => { history.pushState({}, '', p); window.dispatchEvent(new PopStateEvent('popstate', {state: history.state})); }", path)

    async def phase_tabs(self):
        if self.a.trace:
            await self.browser.start_tracing(page=self.page, path=str(self.out / "trace-tabs.json"),
                                             categories=trace_summary.CATEGORIES)
            await asyncio.sleep(2.0)
            await self.page.evaluate("performance.mark('perf:window-start')")
        tabs = {}
        tabs["requests"] = await self.nav_tab("requests", lambda: self.tap(*self.bottom(1)))
        tabs["library"] = await self.nav_tab("library", lambda: self.tap(*self.bottom(2)))
        tabs["activity"] = await self.nav_tab("activity", lambda: self.tap(*self.bottom(3)))
        tabs["system"] = await self.nav_tab("system", lambda: self.go_route("/system"))
        tabs["home_again"] = await self.nav_tab("home", lambda: self.tap(*self.bottom(0)))
        self.res["tabs"] = tabs
        if self.a.trace:
            await self.page.evaluate("performance.mark('perf:window-end')")
            await self.browser.stop_tracing()

    async def phase_images(self, trace_path=None):
        """Library poster grids: do posters repaint after leaving the viewport?

        TV (60 series) stays under Flutter's 100 MB ImageCache budget; Movies
        (120 movies, ~1.2 MB decoded each) exceeds it, so evicted posters have
        to be reloaded when they come back into view."""
        res = {}
        movies, tv = (int(self.vw * 0.5), 79), (int(self.vw / 6), 79)
        if trace_path:
            await self.grid_roundtrip("movies", sub_tab=movies, swipes=8, trace_path=trace_path)
            return
        # 1. fast flings over posters that are not loaded yet: tiles leave the
        #    viewport while their image is still downloading / decoding
        res["movies_fast"] = await self.grid_roundtrip("movies_fast", sub_tab=movies, swipes=5,
                                                       swipe_px=2500, speed=7000, settle_bottom=0.2)
        # 2. TV: 60 posters, fits Flutter's ImageCache (100 MB)
        res["tv"] = await self.grid_roundtrip("tv", sub_tab=tv, swipes=4)
        # 3. Movies again, slowly: 120 posters, more than the ImageCache holds
        res["movies"] = await self.grid_roundtrip("movies", sub_tab=movies, swipes=8)
        res["images_reappear"] = all(r["images_reappear"] for r in res.values())
        self.res["images"] = res

    async def grid_roundtrip(self, name, sub_tab, swipes, trace_path=None, swipe_px=1500, speed=2500,
                             settle_bottom=1.0):
        from PIL import Image, ImageChops, ImageStat

        await self.tap(*self.bottom(2))
        await self.wait_settled(quiet_ms=800, timeout_ms=15000)
        await self.tap(*sub_tab)
        await self.wait_settled(quiet_ms=800, timeout_ms=15000)
        await self.scroll(-20000, speed=12000)  # to the top
        await self.wait_settled(quiet_ms=1500, timeout_ms=20000)
        if trace_path:
            await self.browser.start_tracing(page=self.page, path=str(trace_path), categories=trace_summary.CATEGORIES)
            await asyncio.sleep(2.0)  # let the profiler start-up cost pass
        a = None if trace_path else await self.shot(f"05-{name}-top-before")
        mark0 = self.net.mark()
        m0 = await self.perf_metrics()
        t0 = await self.start_sampling()
        await self.page.evaluate("performance.mark('perf:window-start')")
        for _ in range(swipes):  # to the bottom: the top posters leave the viewport
            await self.scroll(swipe_px, speed=speed)
        await asyncio.sleep(settle_bottom)
        t_mid = await self.now()
        b = None if trace_path else await self.shot(f"06-{name}-bottom")
        mark1 = self.net.mark()
        for _ in range(swipes):
            await self.scroll(-swipe_px, speed=speed)
        await self.scroll(-20000, speed=12000)  # clamp at the top
        await asyncio.sleep(0.3)
        await self.page.evaluate("performance.mark('perf:window-end')")
        t1 = await self.stop_sampling()
        m1 = await self.perf_metrics()
        if trace_path:
            await self.browser.stop_tracing()
            self.res[f"images_{name}_traced"] = {"jank": await self.window_stats(t0, t1), "cdp": diff_metrics(m0, m1)}
            return None
        c = await self.shot(f"07-{name}-top-after-0s")
        await asyncio.sleep(2.0)
        d = await self.shot(f"08-{name}-top-after-2s")
        await asyncio.sleep(4.0)
        e = await self.shot(f"09-{name}-top-after-6s")
        before = [self.net.reqs[k] for k in self.net.order[:mark0]]
        down = [self.net.reqs[k] for k in self.net.order[mark0:mark1]]
        back = self.net.since(mark1)

        def diff(p1, p2, box):
            i1 = Image.open(p1).convert("RGB").crop(box)
            i2 = Image.open(p2).convert("RGB").crop(box)
            st = ImageStat.Stat(ImageChops.difference(i1, i2))
            return round(sum(st.mean) / 3, 2)

        def stddev(p, box):  # posters are colourful; placeholder boxes are flat
            st = ImageStat.Stat(Image.open(p).convert("RGB").crop(box))
            return round(sum(st.stddev) / 3, 2)

        W, H = Image.open(a).size
        box = (0, int(H * 0.38), W, int(H * 0.88))  # grid area below header/filters, above the bar
        before_urls = {r["url"] for r in before if is_img(r["url"]) and r["state"] == "done"}
        r = {
            "grid_box_px": box,
            "diff_before_vs_after_0s": diff(a, c, box),
            "diff_before_vs_after_2s": diff(a, d, box),
            "diff_before_vs_after_6s": diff(a, e, box),
            "diff_before_vs_bottom": diff(a, b, box),
            "grid_stddev_before": stddev(a, box),
            "grid_stddev_after_6s": stddev(e, box),
            "img_requests_scrolling_down": summarize_reqs([x for x in down if is_img(x["url"])]),
            "img_requests_returning": summarize_reqs([x for x in back if is_img(x["url"])]),
            "img_urls_loaded_before": len(before_urls),
            "returning_requests_for_previously_loaded_urls": sum(1 for x in back if x["url"] in before_urls),
            "jank_down": await self.window_stats(t0, t_mid),
            "jank_roundtrip": await self.window_stats(t0, t1),
            "cdp": diff_metrics(m0, m1),
        }
        # After 6 s the top of the grid must look like it did before.
        r["images_reappear"] = r["diff_before_vs_after_6s"] < 6.0
        return r

    # -- driver ---------------------------------------------------------------
    async def run(self):
        phases = self.a.phases.split(",")
        async with async_playwright() as p:
            if self.a.gpu == "swiftshader":
                launch_args = ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"]
            else:  # the host GPU (closer to a phone than software GL; headless screenshots still work)
                launch_args = ["--enable-gpu", "--use-angle=gl", "--ignore-gpu-blocklist"]
            self.browser = await p.chromium.launch(
                channel="chromium", headless=not self.a.headed, args=launch_args)
            dev = dict(p.devices["Pixel 7"])
            ctx = await self.browser.new_context(**dev)
            self.vw, self.vh = dev["viewport"]["width"], dev["viewport"]["height"]
            if self.a.no_image_decoder:
                await ctx.add_init_script("window.__perfNoImageDecoder = true;")
            await ctx.add_init_script(INIT_JS)
            self.page = page = await ctx.new_page()
            page.on("console", lambda m: self.console.append(f"{m.type}: {m.text[:300]}"))
            page.on("pageerror", lambda e: self.console.append(f"pageerror: {e}"))
            self.cdp = await ctx.new_cdp_session(page)
            self.net.attach(self.cdp)
            await self.cdp.send("Network.enable")
            await self.cdp.send("Performance.enable")
            await self.cdp.send("Emulation.setCPUThrottlingRate", {"rate": self.a.cpu})
            self.res["browser"] = self.browser.version
            self.res["gpu"] = self.a.gpu
            self.res["no_image_decoder"] = self.a.no_image_decoder
            self.res["device"] = {"viewport": dev["viewport"], "dpr": dev["device_scale_factor"],
                                  "ua": dev["user_agent"]}
            try:
                if "boot" in phases or "login" in phases:
                    await self.phase_boot()
                if "login" in phases:
                    await self.phase_login()
                if "dashboard" in phases:
                    await self.phase_dashboard()
                    if self.a.trace:
                        await self.phase_dashboard(trace_path=self.out / "trace-dashboard.json")
                if "tabs" in phases:
                    await self.phase_tabs()
                if "images" in phases:
                    await self.phase_images()
                    if self.a.trace:
                        await self.phase_images(trace_path=self.out / "trace-library.json")
                self.res["webgl_renderer"] = await page.evaluate(
                    "(() => { const g = document.createElement('canvas').getContext('webgl2'); if (!g) return null;"
                    " const e = g.getExtension('WEBGL_debug_renderer_info');"
                    " return e ? g.getParameter(e.UNMASKED_RENDERER_WEBGL) : g.getParameter(g.RENDERER); })()")
            finally:
                heap = await self.perf_metrics()
                self.res["final_js_heap_mb"] = round(heap.get("JSHeapUsedSize", 0) / 1e6, 1)
                self.res["console_summary"] = summarize_console(self.console)
                (self.out / "console.log").write_text("\n".join(self.console))
                net_dump = [dict(v, id=k) for k, v in self.net.reqs.items()]
                (self.out / "network.json").write_text(json.dumps(net_dump, indent=1))
                await self.browser.close()
        if self.a.trace:
            for name in ("trace-login.json", "trace-dashboard.json", "trace-tabs.json", "trace-library.json"):
                tp = self.out / name
                if tp.exists():
                    self.res[name.replace(".json", "").replace("-", "_") + "_summary"] = trace_summary.summarize(
                        tp, top=self.a.trace_top, sourcemap=self.a.sourcemap)
        (self.out / "result.json").write_text(json.dumps(self.res, indent=2))
        return self.res


def diff_metrics(m0, m1):
    keys = ["TaskDuration", "ScriptDuration", "LayoutDuration", "RecalcStyleDuration",
            "LayoutCount", "RecalcStyleCount", "JSHeapUsedSize", "Nodes"]
    out = {}
    for k in keys:
        if k in m0 and k in m1:
            v = m1[k] - m0[k]
            if k.endswith("Duration"):
                out[k + "_ms"] = round(v * 1000, 1)
            elif k == "JSHeapUsedSize":
                out["JSHeapDelta_mb"] = round(v / 1e6, 2)
            else:
                out[k] = v
    if "JSHeapUsedSize" in m1:
        out["JSHeapUsed_mb"] = round(m1["JSHeapUsedSize"] / 1e6, 1)
    return out


def summarize_console(lines):
    out = {"total": len(lines), "errors": 0, "font_fallback_fetch_failures": 0, "samples": []}
    for l in lines:
        if l.startswith("error") or l.startswith("pageerror"):
            out["errors"] += 1
        if "fonts.gstatic.com" in l and ("Fetch API cannot load" in l):
            out["font_fallback_fetch_failures"] += 1
    seen = set()
    for l in lines:
        key = l[:80]
        if key not in seen and (l.startswith("error") or l.startswith("warning") or l.startswith("pageerror")):
            seen.add(key)
            out["samples"].append(l[:240])
        if len(out["samples"]) >= 12:
            break
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:18090/")
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="run")
    ap.add_argument("--cpu", type=float, default=4.0, help="CDP CPU throttling rate")
    ap.add_argument("--phases", default="boot,login,dashboard,tabs,images")
    ap.add_argument("--trace", action="store_true", help="record Chromium traces of the scroll phases")
    ap.add_argument("--trace-top", type=int, default=30)
    ap.add_argument("--sourcemap", help="main.dart.js.map for de-minifying trace function names")
    ap.add_argument("--headed", action="store_true")
    ap.add_argument("--no-image-decoder", action="store_true",
                    help="hide WebCodecs ImageDecoder so Flutter decodes via <img> (the Safari/Firefox path)")
    ap.add_argument("--gpu", choices=["hw", "swiftshader"], default=os.environ.get("PERF_GPU", "hw"),
                    help="hw: the host GPU via ANGLE/GL; swiftshader: software GL (CPU raster in the GPU process)")
    args = ap.parse_args()
    res = asyncio.run(Bench(args).run())
    print(json.dumps({k: v for k, v in res.items() if not k.endswith("_summary")}, indent=1)[:6000])


if __name__ == "__main__":
    main()
