#!/usr/bin/env python3
"""Aggregates bench.py runs into one results file and compares with a baseline.

  aggregate.py --label L --runs DIR1 DIR2 ... [--noid DIR] [--profile DIR]
               --out results/L.json [--baseline baseline.json]

Key metrics are the median over the repeated release runs; the full per-run
results stay next to the traces in the run directories.
"""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

# (path in result.json, lower is better?)  -- None: informational
METRICS = [
    ("boot.flutter_view_ms", True),
    ("boot.first_flutter_frame_ms", True),
    ("boot.login_screen_idle_ms", True),
    ("login.dashboard_frame_after_login_ms", True),
    ("login.client_after_login_to_settled_ms", True),
    ("login.jank.frames_over_50ms", True),
    ("login.jank.longtask_ms_total", True),
    ("login.jank.flutter_frame_ms_max", True),
    ("login.img_requests.count", None),
    ("dashboard_scroll.jank.fps", False),
    ("dashboard_scroll.jank.frame_ms_p50", True),
    ("dashboard_scroll.jank.frame_ms_p90", True),
    ("dashboard_scroll.jank.frame_ms_p99", True),
    ("dashboard_scroll.jank.frames_over_32ms", True),
    ("dashboard_scroll.jank.frames_over_100ms", True),
    ("dashboard_scroll.jank.flutter_frame_ms_p90", True),
    ("dashboard_scroll.jank.longtask_ms_total", True),
    ("dashboard_scroll.cdp.ScriptDuration_ms", True),
]
for tab in ("requests", "library", "activity", "system", "home_again"):
    METRICS += [
        (f"tabs.{tab}.first_frame_ms", True),
        (f"tabs.{tab}.settled_ms", True),
        (f"tabs.{tab}.jank.longtask_ms_total", True),
        (f"tabs.{tab}.jank.frames_over_50ms", True),
        (f"tabs.{tab}.jank.flutter_frame_ms_max", True),
        (f"tabs.{tab}.scroll_jank.fps", False),
        (f"tabs.{tab}.scroll_jank.frames_over_32ms", True),
    ]
for sc in ("movies_fast", "tv", "movies"):
    METRICS += [
        (f"images.{sc}.images_reappear", None),
        (f"images.{sc}.jank_down.fps", False),
        (f"images.{sc}.jank_down.frame_ms_p90", True),
        (f"images.{sc}.jank_down.frames_over_32ms", True),
        (f"images.{sc}.jank_down.image_decodes", True),
        (f"images.{sc}.img_requests_scrolling_down.count", None),
        (f"images.{sc}.diff_before_vs_after_6s", True),
    ]
METRICS += [("final_js_heap_mb", True), ("console_summary.font_fallback_fetch_failures", True)]


def get(d, path):
    cur = d
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def derive(r):
    lg = r.get("login") or {}
    if lg.get("first_dashboard_frame_ms") is not None and lg.get("login_response_ms") is not None:
        lg["dashboard_frame_after_login_ms"] = round(lg["first_dashboard_frame_ms"] - lg["login_response_ms"], 1)
    return r


def median(vals):
    vals = [v for v in vals if v is not None]
    if not vals:
        return None
    if all(isinstance(v, bool) for v in vals):
        return all(vals)
    return round(statistics.median(vals), 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--runs", nargs="+", required=True)
    ap.add_argument("--noid")
    ap.add_argument("--profile")
    ap.add_argument("--out", required=True)
    ap.add_argument("--baseline")
    ap.add_argument("--meta", default="{}")
    a = ap.parse_args()

    runs = [derive(json.loads((Path(d) / "result.json").read_text())) for d in a.runs
            if (Path(d) / "result.json").exists()]
    if not runs:
        raise SystemExit("no results")
    out = {
        "label": a.label,
        "meta": json.loads(a.meta),
        "environment": {k: runs[0].get(k) for k in ("browser", "gpu", "webgl_renderer", "device", "cpu_throttle")},
        "repeats": len(runs),
        "metrics_median": {},
        "metrics_runs": {},
    }
    for path, _ in METRICS:
        vals = [get(r, path) for r in runs]
        out["metrics_median"][path] = median(vals)
        out["metrics_runs"][path] = vals

    if a.noid and (Path(a.noid) / "result.json").exists():
        n = json.loads((Path(a.noid) / "result.json").read_text())
        im = n.get("images") or {}
        out["safari_decode_path_images"] = {
            "note": "Chromium with WebCodecs ImageDecoder hidden: Flutter decodes through <img> like Safari/iOS and Firefox",
            "images_reappear": im.get("images_reappear"),
            **{sc: {k: v.get(k) for k in ("images_reappear", "diff_before_vs_after_0s", "diff_before_vs_after_6s",
                                          "img_requests_returning", "returning_requests_for_previously_loaded_urls")}
               | {"jank_down": {k: v["jank_down"].get(k) for k in ("fps", "frame_ms_p90", "frames_over_32ms",
                                                                   "frames_over_100ms", "image_decodes",
                                                                   "image_decode_ms_p50")}}
               for sc, v in im.items() if isinstance(v, dict)},
        }
    if a.profile and (Path(a.profile) / "result.json").exists():
        pr = json.loads((Path(a.profile) / "result.json").read_text())
        out["profile_build_traces"] = {k: v for k, v in pr.items() if k.endswith("_summary")}
        out["profile_build_traced_jank"] = {k: v.get("jank") for k, v in pr.items()
                                            if k.endswith("_traced") and isinstance(v, dict)}

    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps(out, indent=1))

    base = None
    if a.baseline and Path(a.baseline).exists() and Path(a.baseline).resolve() != Path(a.out).resolve():
        base = json.loads(Path(a.baseline).read_text())

    print(f"\n== {a.label}: median of {len(runs)} run(s) ==")
    width = max(len(p) for p, _ in METRICS)
    for path, lower in METRICS:
        v = out["metrics_median"][path]
        line = f"  {path:<{width}}  {v!s:>10}"
        if base is not None:
            b = base.get("metrics_median", {}).get(path)
            line += f"   baseline {b!s:>10}"
            if isinstance(v, (int, float)) and isinstance(b, (int, float)) and not isinstance(v, bool) and b and lower is not None:
                ch = (v - b) / abs(b) * 100
                better = (ch < 0) if lower else (ch > 0)
                line += f"  {ch:+6.1f}% {'better' if better and abs(ch) >= 5 else ('worse' if abs(ch) >= 5 else '')}"
        print(line)
    if "safari_decode_path_images" in out:
        print(f"  safari-path images_reappear: {out['safari_decode_path_images']['images_reappear']}")
    pt = out.get("profile_build_traces", {})
    for name, s in pt.items():
        if not isinstance(s, dict) or "main_thread_by_category_ms" not in s:
            continue
        print(f"\n  {name}: main thread busy {s['main_thread_busy_ms']} ms of {s['trace_span_ms']} ms; "
              f"categories {s['main_thread_by_category_ms']}")
        jp = s.get("js_profile") or {}
        for row in (jp.get("top_files_self_ms") or [])[:8]:
            print(f"     {row[1]:>8} ms {row[2]:>5}%  {row[0]}")
    print(f"\nwritten {a.out}")


if __name__ == "__main__":
    main()
