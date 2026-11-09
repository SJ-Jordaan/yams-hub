#!/usr/bin/env python3
"""Screenshots of the hub's web app in the sandbox (run by `run.sh screens`; optional, needs Playwright + Chromium).

Login screen, then a real login through the form (Tab, type, Enter, as tool/perf/bench.py does), then the dashboard,
calendar and library pages by deep link. PNGs go to $SANDBOX_ARTIFACTS/screens-<variant>/.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sbx import ARTIFACTS, HUB_PORT, secrets  # noqa: E402

from playwright.sync_api import sync_playwright  # noqa: E402

VARIANT = os.environ.get("SANDBOX_VARIANT", "vpn-off")
HUB = f"http://127.0.0.1:{HUB_PORT}"
OUT = ARTIFACTS / f"screens-{VARIANT}"


def settle(page, ms: int = 2500) -> None:
    try:
        page.wait_for_load_state("networkidle", timeout=20000)
    except Exception:  # noqa: BLE001 - polling pages never go fully idle
        pass
    page.wait_for_timeout(ms)


def main() -> int:
    sec = secrets()
    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 412, "height": 915}, device_scale_factor=2)
        errors: list[str] = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(HUB + "/", wait_until="load")
        page.wait_for_selector("flutter-view, flt-glass-pane", state="attached", timeout=60000)
        settle(page)
        page.screenshot(path=str(OUT / "01-login.png"))

        page.keyboard.press("Tab")
        page.keyboard.type(sec["SBX_ADMIN_USER"])
        page.keyboard.press("Tab")
        page.keyboard.type(sec["SBX_ADMIN_PASSWORD"])
        with page.expect_response(lambda r: "/auth/login" in r.url, timeout=30000) as login:
            page.keyboard.press("Enter")
        if login.value.status != 200:
            print(f"screens: login answered {login.value.status}", file=sys.stderr)
            return 1
        settle(page, 4000)
        page.screenshot(path=str(OUT / "02-dashboard.png"))

        for i, route in enumerate(["/calendar", "/library"], start=3):
            page.goto(HUB + route, wait_until="load")
            page.wait_for_selector("flutter-view, flt-glass-pane", state="attached", timeout=60000)
            settle(page, 4000)
            page.screenshot(path=str(OUT / f"{i:02d}-{route.strip('/')}.png"))
        browser.close()
    for e in errors:
        print(f"screens: page error: {e}", file=sys.stderr)
    print(f"screens: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
