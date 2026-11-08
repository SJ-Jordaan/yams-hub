#!/usr/bin/env python3
"""Summarises a Chromium trace recorded by bench.py (tool/perf).

  trace_summary.py TRACE.json [--top 30] [--sourcemap main.dart.js.map]

Reports, for the page's renderer main thread:
  - busy time by DevTools-like category (scripting / rendering / painting /
    image decode / GC / other) from trace events (self time),
  - the top trace events by self time,
  - the top JS functions by self time from the V8 CPU profile samples
    (dart2js names; with --sourcemap each frame is mapped to its Dart source
    file:line, which makes the profile build fully readable),
and busy time per thread for the renderer and GPU processes (raster, image
decode workers, compositor).
"""

from __future__ import annotations

import argparse
import bisect
import json
import os
import re
from collections import defaultdict
from pathlib import Path

CATEGORIES = [
    "devtools.timeline",
    "disabled-by-default-devtools.timeline",
    "disabled-by-default-devtools.timeline.frame",
    "toplevel",
    "v8.execute",
    "v8",
    "disabled-by-default-v8.cpu_profiler",
    "disabled-by-default-v8.gc",
    "blink.user_timing",
    "blink",
    "cc",
    "gpu",
]

GROUPS = [
    ("image_decode", re.compile(r"Decode|ImageDecoder|ImageBitmap", re.I)),
    ("gc", re.compile(r"GC|Sweep|Mark|Scavenge|Compact|BlinkGC", re.I)),
    ("scripting", re.compile(r"^(FunctionCall|EvaluateScript|v8\.|V8\.|RunMicrotasks|TimerFire|FireAnimationFrame|"
                             r"EventDispatch|XHRReadyStateChange|XHRLoad|FireIdleCallback|v8.run|v8.compile|"
                             r"CompileScript|CompileCode|ParseHTML|v8.callFunction|WebAssembly|wasm)", re.I)),
    ("rendering", re.compile(r"^(UpdateLayoutTree|Layout|HitTest|PrePaint|ScheduleStyleRecalculation|"
                             r"RecalcStyle|UpdateLayerTree|IntersectionObserver|Layerize)", re.I)),
    ("painting", re.compile(r"^(Paint|PaintImage|CompositeLayers|Commit|Rasterize|RasterTask|"
                            r"GPUTask|Draw|Composite|Activate|BeginMainThreadFrame|UpdateLayer)", re.I)),
]


def group_of(name: str) -> str:
    for g, rx in GROUPS:
        if rx.search(name):
            return g
    return "other"


def load_events(path: Path):
    with open(path, "rb") as f:
        data = json.load(f)
    return data["traceEvents"] if isinstance(data, dict) else data


class SourceMap:
    """Minimal source map v3 reader: (line, col) -> (source, line, name)."""

    B64 = {c: i for i, c in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")}

    def __init__(self, path):
        sm = json.loads(Path(path).read_text())
        self.sources = sm["sources"]
        self.names = sm.get("names", [])
        self.lines: list[tuple[list[int], list[tuple]]] = []
        src = sline = scol = name = 0
        for line in sm["mappings"].split(";"):
            cols, segs = [], []
            gcol = 0
            for seg in line.split(","):
                if not seg:
                    continue
                vals = self._vlq(seg)
                gcol += vals[0]
                if len(vals) >= 4:
                    src += vals[1]
                    sline += vals[2]
                    scol += vals[3]
                    nm = None
                    if len(vals) >= 5:
                        name += vals[4]
                        nm = name
                    cols.append(gcol)
                    segs.append((src, sline, nm))
            self.lines.append((cols, segs))

    def _vlq(self, s):
        out, shift, val = [], 0, 0
        for ch in s:
            d = self.B64[ch]
            val += (d & 31) << shift
            if d & 32:
                shift += 5
            else:
                neg = val & 1
                val >>= 1
                out.append(-val if neg else val)
                val = shift = 0
        return out

    def lookup(self, line0: int, col0: int):
        if line0 < 0 or line0 >= len(self.lines):
            return None
        cols, segs = self.lines[line0]
        i = bisect.bisect_right(cols, col0) - 1
        if i < 0:
            return None
        src, sline, nm = segs[i]
        s = self.sources[src]
        s = re.sub(r"^org-dartlang-sdk:///", "sdk:", s)
        s = re.sub(r".*/packages/flutter/lib/src/", "flutter:", s)
        s = re.sub(r".*/\.pub-cache/hosted/[^/]+/", "pkg:", s)
        s = re.sub(r".*/yams_models/lib/", "yams_models:", s)
        s = re.sub(r".*/app/lib/", "app:", s)
        return f"{s}:{sline + 1}", (self.names[nm] if nm is not None and nm < len(self.names) else None)


def thread_names(events):
    names, procs = {}, {}
    for e in events:
        if e.get("ph") == "M":
            if e.get("name") == "thread_name":
                names[(e["pid"], e["tid"])] = e["args"]["name"]
            elif e.get("name") == "process_name":
                procs[e["pid"]] = e["args"]["name"]
    return names, procs


def self_times(evs):
    """Self time per event name for one thread (X events + B/E pairs), µs."""
    spans = []
    stack_be = defaultdict(list)
    for e in evs:
        ph = e.get("ph")
        if ph == "X" and "dur" in e:
            spans.append((e["ts"], e["ts"] + e["dur"], e["name"]))
        elif ph == "B":
            stack_be[e["name"]].append(e["ts"])
        elif ph == "E":
            st = stack_be.get(e.get("name"))
            if st:
                spans.append((st.pop(), e["ts"], e["name"]))
    spans.sort(key=lambda s: (s[0], -(s[1] - s[0])))
    selft = defaultdict(float)
    top_level = 0.0
    stack: list[list] = []  # [end, name, child_total]
    for start, end, name in spans:
        while stack and stack[-1][0] <= start:
            s_end, s_name, s_child, s_dur = stack.pop()
            selft[s_name] += max(0.0, s_dur - s_child)
        if stack:
            stack[-1][2] += end - start
        else:
            top_level += end - start
        stack.append([end, name, 0.0, end - start])
    while stack:
        s_end, s_name, s_child, s_dur = stack.pop()
        selft[s_name] += max(0.0, s_dur - s_child)
    return selft, top_level


def cpu_profile(events, pid, tid, sm: SourceMap | None, top: int, window=None, wasm_names=None):
    nodes = {}
    samples, deltas = [], []
    start = None
    for e in events:
        if e.get("pid") != pid:
            continue
        if e.get("name") == "Profile" and start is None:
            start = e.get("args", {}).get("data", {}).get("startTime")
        if e.get("name") != "ProfileChunk":
            continue
        d = e.get("args", {}).get("data", {})
        cp = d.get("cpuProfile", {})
        for n in cp.get("nodes", []) or []:
            nodes[n["id"]] = n
        samples += cp.get("samples", []) or []
        deltas += d.get("timeDeltas", []) or []
    if not samples:
        return None
    selft = defaultdict(float)
    t = start or 0
    for i, sid in enumerate(samples):
        t += deltas[i] if i < len(deltas) else 0
        dt = deltas[i + 1] if i + 1 < len(deltas) else 0
        if window and start is not None and not (window[0] <= t <= window[1]):
            continue
        selft[sid] += max(dt, 0)
    by_fn = defaultdict(float)
    total = 0.0
    for sid, us in selft.items():
        n = nodes.get(sid)
        if not n:
            continue
        cf = n.get("callFrame", {})
        fn = cf.get("functionName") or "(anonymous)"
        url = cf.get("url") or ""
        if wasm_names and fn.startswith("wasm-function["):
            m = re.match(r"wasm-function\[(\d+)\]", fn)
            if m and m.group(1) in wasm_names:
                fn = "wasm:" + wasm_names[m.group(1)][:90]
        base = os.path.basename(url.split("?")[0])
        loc = ""
        if sm and base == "main.dart.js" and cf.get("lineNumber", -1) >= 0:
            r = sm.lookup(cf["lineNumber"], cf.get("columnNumber", 0))
            if r:
                loc, _ = r
        key = f"{fn}  [{loc or base or 'native'}]"
        by_fn[key] += us
        total += us
    idle = sum(v for k, v in by_fn.items() if k.startswith("(idle)"))
    program = sum(v for k, v in by_fn.items() if k.startswith("(program)"))
    busy = total - idle - program
    rows = sorted(((k, v) for k, v in by_fn.items() if not k.startswith(("(idle)", "(program)"))),
                  key=lambda kv: -kv[1])[:top]
    # Aggregate by source file (profile builds with a source map) or by URL.
    by_file = defaultdict(float)
    for k, v in by_fn.items():
        if k.startswith(("(idle)", "(program)")):
            continue
        m = re.search(r"\[([^\[\]]*)\]$", k)
        f = re.sub(r":\d+$", "", m.group(1)) if m else "?"
        by_file[f] += v
    return {
        "sampled_ms": round(total / 1000, 1),
        "idle_ms": round(idle / 1000, 1),
        "program_ms": round(program / 1000, 1),
        "js_and_native_ms": round(busy / 1000, 1),
        "top_functions_self_ms": [[k, round(v / 1000, 1), round(100 * v / busy, 1) if busy else 0] for k, v in rows],
        "top_files_self_ms": [[k, round(v / 1000, 1), round(100 * v / busy, 1) if busy else 0]
                              for k, v in sorted(by_file.items(), key=lambda kv: -kv[1])[:top]],
    }


WINDOW_START, WINDOW_END = "perf:window-start", "perf:window-end"


def flutter_phases(events, window):
    """Flutter profile-mode timeline (performance.measure -> async b/e)."""
    open_ = {}
    durs = defaultdict(list)
    for e in events:
        if "user_timing" not in e.get("cat", "") or e.get("ph") not in ("b", "e"):
            continue
        key = (e["name"], e.get("id") or e.get("id2", {}).get("local"))
        if e["ph"] == "b":
            open_[key] = e["ts"]
        elif key in open_:
            t0 = open_.pop(key)
            if window and not (window[0] <= t0 <= window[1]):
                continue
            durs[e["name"]].append((e["ts"] - t0) / 1000)
    if not durs:
        return None
    out = {}
    for name, ds in sorted(durs.items(), key=lambda kv: -sum(kv[1])):
        ds.sort()
        out[name] = {"count": len(ds), "total_ms": round(sum(ds), 1),
                     "p50_ms": round(ds[len(ds) // 2], 2), "p90_ms": round(ds[int(len(ds) * 0.9)], 2),
                     "max_ms": round(ds[-1], 1)}
    return out


def load_wasm_names(sourcemap):
    if not sourcemap:
        return None
    for rel in ("canvaskit/chromium/canvaskit.js.symbols", "canvaskit/canvaskit.js.symbols"):
        p = Path(sourcemap).parent / rel
        if p.exists():
            names = {}
            for line in p.read_text(errors="ignore").splitlines():
                k, _, v = line.partition(":")
                names[k] = re.sub(r"\\([0-9a-f]{2})", lambda m: chr(int(m.group(1), 16)), v)
            return names
    return None


def summarize(path, top=30, sourcemap=None):
    events = load_events(Path(path))
    names, procs = thread_names(events)
    # Measurement window marked by bench.py (performance.mark); without it the
    # whole trace (including the profiler start-up) is used.
    marks = {e["name"]: e["ts"] for e in events if e.get("name") in (WINDOW_START, WINDOW_END)}
    window = (marks[WINDOW_START], marks[WINDOW_END]) if len(marks) == 2 else None
    by_thread = defaultdict(list)
    for e in events:
        if e.get("ph") in ("X", "B", "E") and "ts" in e:
            if window and not (window[0] <= e["ts"] <= window[1]):
                continue
            by_thread[(e["pid"], e["tid"])].append(e)
    if window:
        span_ms = (window[1] - window[0]) / 1000
    else:
        ts = [e["ts"] for e in events if "ts" in e and e.get("ph") in ("X", "B", "E")]
        span_ms = (max(ts) - min(ts)) / 1000 if ts else 0

    # renderer main thread with the most work
    mains = [(k, v) for k, v in by_thread.items() if names.get(k) == "CrRendererMain"]
    if not mains:
        return {"error": "no CrRendererMain thread in trace"}
    main_key, main_evs = max(mains, key=lambda kv: sum(e.get("dur", 0) for e in kv[1]))
    selft, top_level = self_times(main_evs)
    groups = defaultdict(float)
    for n, us in selft.items():
        groups[group_of(n)] += us

    threads = {}
    for k, evs in by_thread.items():
        pname = procs.get(k[0], "?")
        if k[0] != main_key[0] and "GPU" not in pname.upper():
            continue
        st, tl = self_times(evs)
        decode = sum(us for n, us in st.items() if group_of(n) == "image_decode")
        label = f"{pname}/{names.get(k, k[1])}"
        cur = threads.setdefault(label, {"busy_ms": 0.0, "image_decode_ms": 0.0})
        cur["busy_ms"] += tl / 1000
        cur["image_decode_ms"] += decode / 1000
    threads = {k: {kk: round(vv, 1) for kk, vv in v.items()} for k, v in
               sorted(threads.items(), key=lambda kv: -kv[1]["busy_ms"]) if v["busy_ms"] >= 1}

    sm = SourceMap(sourcemap) if sourcemap and Path(sourcemap).exists() else None
    return {
        "trace_span_ms": round(span_ms, 1),
        "main_thread_busy_ms": round(top_level / 1000, 1),
        "main_thread_busy_pct": round(100 * top_level / 1000 / span_ms, 1) if span_ms else None,
        "main_thread_by_category_ms": {k: round(v / 1000, 1) for k, v in sorted(groups.items(), key=lambda kv: -kv[1])},
        "main_thread_top_events_self_ms": [[n, round(us / 1000, 1)] for n, us in
                                           sorted(selft.items(), key=lambda kv: -kv[1])[:top]],
        "threads_busy_ms": threads,
        "js_profile": cpu_profile(events, main_key[0], main_key[1], sm, top, window, load_wasm_names(sourcemap)),
        "flutter_timeline_phases": flutter_phases(events, window),
        "measurement_window": bool(window),
        "sourcemap": bool(sm),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--sourcemap")
    a = ap.parse_args()
    print(json.dumps(summarize(a.trace, a.top, a.sourcemap), indent=1))


if __name__ == "__main__":
    main()
