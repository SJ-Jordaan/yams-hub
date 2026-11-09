#!/usr/bin/env python3
"""Smoke test of the hub installed into the sandbox (run by `run.sh test`). Python 3 stdlib only.

Logs in with the bearer flow (and checks the cookie flow), calls the API of every app page, and asserts:
  - no upstream errors (no `upstream_*` error code, no dashboard card or section in status "error");
  - every expected service is configured in /server and "up" in /health;
  - this month's calendar has items, the library has the seeded shows and movies, qBittorrent answers;
  - VPN on: /vpn reads the gluetun stand-in; VPN off: gluetun is not configured and restarts forever (stock YAMS),
    and /containers and /dashboard still show no errors.
Then the check for issue #2 (Sonarr "Allowed Hosts" without the container name): before Sonarr restarts the hub must
warn (health and dashboard), after the restart it must name the cause and the fix (health, calendar, library card,
dashboard alert), and after the restore it must recover.

Prints a table, writes $SANDBOX_ARTIFACTS/smoke-<variant>.json, and on failure prints `docker logs yams-hub`.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sbx import ARTIFACTS, HUB_PORT, Client, Fatal, arr_key, base, docker, secrets, wait_until  # noqa: E402

VARIANT = os.environ.get("SANDBOX_VARIANT", "vpn-off")
HUB = f"http://127.0.0.1:{HUB_PORT}"
CLIENT = {"X-YAMS-Client": "yams-hub-sandbox/1.0 (smoke)"}
SHOWS = ["The Daily Show", "Coronation Street", "Breaking Bad"]
MOVIES = ["The Matrix", "Inception", "Spirited Away"]
EXPECTED = ["sonarr", "radarr", "prowlarr", "bazarr", "seerr", "jellyfin", "qbittorrent", "docker", "updater"]
if VARIANT == "vpn-on":
    EXPECTED.append("gluetun")
NOT_EXPECTED = ["gluetun"] if VARIANT == "vpn-off" else []

rows: list[tuple[str, str, str, str]] = []  # (check, http, ms, result)
failures: list[str] = []
notes: list[str] = []


def record(check: str, ok: bool, detail: str, status: int | str = "", ms: str = "") -> None:
    rows.append((check, str(status), ms, ("ok   " if ok else "FAIL ") + detail))
    if not ok:
        failures.append(f"{check}: {detail}")


def upstream_errors(obj, path="") -> list[str]:
    """Every ApiError with an upstream_* code, and every section {status: error}, anywhere in a response."""
    out = []
    if isinstance(obj, dict):
        code = obj.get("code")
        if isinstance(code, str) and code.startswith("upstream_"):
            out.append(f"{path or '/'}: {code} {obj.get('service', '')} {obj.get('message', '')}".strip())
        if obj.get("status") == "error":
            err = obj.get("error") or {}
            out.append(f"{path or '/'}: section error {err.get('code', '')} {err.get('message', '')}".strip())
        for k, v in obj.items():
            if k != "error" or obj.get("status") != "error":
                out.extend(upstream_errors(v, f"{path}/{k}"))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out.extend(upstream_errors(v, f"{path}[{i}]"))
    return out


class Hub:
    def __init__(self, token: str):
        self.c = Client(HUB + "/api/v1", {"Authorization": f"Bearer {token}", **CLIENT})

    def get(self, check: str, path: str, query: dict | None = None, *, expect: int = 200,
            allow_upstream_errors: bool = False):
        t0 = time.monotonic()
        r = self.c.get(path, query=query, timeout=60)
        ms = f"{(time.monotonic() - t0) * 1000:.0f}"
        body = r.json()
        if r.status != expect:
            err = (body or {}).get("error", {}) if isinstance(body, dict) else {}
            record(check, False, f"GET {path}: expected {expect}, got {r.status} {err.get('code', '')} "
                                 f"{err.get('message', r.text()[:120])}", r.status, ms)
            return None
        errs = [] if allow_upstream_errors else upstream_errors(body)
        if errs:
            record(check, False, f"GET {path}: " + "; ".join(errs[:4]), r.status, ms)
            return body
        rows.append((check, str(r.status), ms, "ok   "))
        return body

    def amend(self, ok: bool, detail: str) -> None:
        """Adds a detail (and possibly a failure) to the last row."""
        check, status, ms, result = rows[-1]
        if not ok and result.startswith("ok"):
            result = "FAIL "
        if not ok:
            failures.append(f"{check}: {detail}")
        rows[-1] = (check, status, ms, (result + " " + detail).strip())


def login(sec: dict[str, str]) -> str:
    c = Client(HUB + "/api/v1", CLIENT)
    body = {"username": sec["SBX_ADMIN_USER"], "password": sec["SBX_ADMIN_PASSWORD"],
            "deviceName": "sandbox smoke", "platform": "other", "transport": "token"}
    r = c.post("/auth/login", body)
    if not r.ok or not (r.json() or {}).get("tokens"):
        raise Fatal(f"bearer login: HTTP {r.status} {r.text()[:200]}")
    user = r.json()["user"]
    record("login (bearer)", True, f"user {user['username']} ({user['role']})", r.status)
    token = r.json()["tokens"]["accessToken"]

    # The web app's flow: cookie transport on /yh/api/v1, X-YAMS-Client on every call.
    web = Client(HUB + "/yh/api/v1", CLIENT, cookies=True)
    r = web.post("/auth/login", {**body, "deviceName": "sandbox smoke (web)", "platform": "web",
                                 "transport": "cookie"})
    names = sorted(ck.name for ck in web.jar or [])
    me = web.get("/auth/me")
    record("login (cookie)", r.ok and "yh_at" in names and me.ok and "tokens" not in (r.json() or {}),
           f"cookies {names}, /auth/me {me.status}", r.status)
    bare = Client(HUB + "/yh/api/v1")  # same cookies, no X-YAMS-Client header
    bare.opener = web.opener
    csrf = bare.get("/auth/me")
    record("cookie CSRF guard", csrf.status == 403, f"/auth/me without X-YAMS-Client -> {csrf.status} (want 403)",
           csrf.status)
    return token


def month() -> tuple[str, str]:
    today = dt.date.today()
    first = today.replace(day=1)
    last = (first + dt.timedelta(days=32)).replace(day=1) - dt.timedelta(days=1)
    return first.isoformat(), last.isoformat()


def wait_healthy(hub: Hub) -> None:
    """The hub probes every service at start; wait until the expected ones are up (or 3 min pass)."""
    def ready():
        r = hub.c.get("/health", timeout=30)
        if not r.ok:
            return False
        status = {s["id"]: s["status"] for s in r.json().get("services", [])}
        return all(status.get(s) == "up" for s in EXPECTED)
    try:
        wait_until("every expected service up in /health", ready, timeout=180, interval=5)
    except Fatal as e:
        print(f"note: {e}; checking anyway", file=sys.stderr)


def titles(items) -> list[str]:
    return [i.get("title", "") for i in items or []]


def run_checks(hub: Hub) -> None:
    hub.get("ping", "/ping")

    server = hub.get("server: services", "/server")
    if server:
        configured = {s["id"] for s in server.get("services", []) if s.get("configured")}
        missing = [s for s in EXPECTED if s not in configured]
        extra = [s for s in NOT_EXPECTED if s in configured]
        hub.amend(not missing and not extra,
                  f"configured: {', '.join(sorted(configured))}"
                  + (f"; MISSING {missing}" if missing else "") + (f"; UNEXPECTED {extra}" if extra else ""))

    health = hub.get("health", "/health")
    if health:
        by_id = {s["id"]: s for s in health.get("services", [])}
        bad = [f"{s}={by_id.get(s, {}).get('status', 'absent')}"
               f"{' (' + by_id[s]['message'] + ')' if by_id.get(s, {}).get('message') else ''}"
               for s in EXPECTED if by_id.get(s, {}).get("status") != "up"]
        versions = ", ".join(f"{s} {by_id[s].get('version') or '?'}" for s in EXPECTED if s in by_id)
        hub.amend(not bad, f"overall {health.get('overall')}; " + (f"NOT UP: {bad}" if bad else versions))

    dash = hub.get("dashboard", "/dashboard")
    if dash:
        cards = dash.get("cards", {})
        hub.amend(True, ", ".join(f"{k}={v.get('status')}" for k, v in sorted(cards.items())))
        alerts = [a.get("id") for a in dash.get("alerts", [])]
        if alerts:
            notes.append("dashboard alerts: " + ", ".join(alerts))

    start, end = month()
    cal = hub.get("calendar (this month)", "/calendar", {"start": start, "end": end})
    if cal:
        items = cal.get("items", [])
        kinds = {k: sum(1 for i in items if i.get("kind") == k) for k in ("episode", "movie")}
        hub.amend(len(items) > 0, f"{len(items)} items ({kinds['episode']} episodes, {kinds['movie']} movies) "
                                  f"{start}..{end}")

    tv = hub.get("library: series", "/library/tv")
    if tv is not None:
        got = titles(tv.get("items"))
        missing = [t for t in SHOWS if not any(t.lower() in g.lower() for g in got)]
        hub.amend(not missing, f"{len(got)} series" + (f"; MISSING {missing}" if missing else ""))
    movies = hub.get("library: movies", "/library/movies")
    if movies is not None:
        got = titles(movies.get("items"))
        missing = [t for t in MOVIES if not any(t.lower() in g.lower() for g in got)]
        hub.amend(not missing, f"{len(got)} movies" + (f"; MISSING {missing}" if missing else ""))
    for svc in ("sonarr", "radarr"):
        w = hub.get(f"library: wanted ({svc})", "/library/wanted/missing", {"service": svc})
        if w is not None:
            hub.amend(True, f"{w.get('total')} missing")

    q = hub.get("downloads: queue", "/activity/queue")
    if q:
        src = {"qbittorrent": q.get("qbittorrent", {}).get("status"),
               **{k: v.get("status") for k, v in q.get("arr", {}).items()}}
        hub.amend(all(v == "ok" for v in src.values()), ", ".join(f"{k}={v}" for k, v in src.items()))
    hub.get("downloads: torrents", "/torrents")
    tr = hub.get("downloads: transfer (qBittorrent)", "/transfer")
    if tr:
        hub.amend(True, f"connection {tr.get('connectionStatus', '?')}")

    if VARIANT == "vpn-on":
        vpn = hub.get("downloads: vpn", "/vpn")
        if vpn:
            hub.amend(vpn.get("publicIp") == "203.0.113.7",
                      f"status {vpn.get('status')}, ip {vpn.get('publicIp')}, forwarded {vpn.get('forwardedPort')}, "
                      f"gluetun {vpn.get('gluetunHealth')}")
    else:
        hub.get("downloads: vpn (off)", "/vpn", expect=503)

    idx = hub.get("indexers", "/indexers")
    if idx is not None:
        hub.amend(True, f"{len(idx.get('items', []))} indexers")
    sub = hub.get("subtitles", "/subtitles/summary")
    if sub:
        hub.amend(True, f"bazarr {sub.get('version')}, signalr {sub.get('signalr')}")
    req = hub.get("requests", "/requests")
    if req is not None:
        hub.amend(True, f"{req.get('total', len(req.get('items', [])))} requests")
    hub.get("requests: counts", "/requests/counts")
    host = hub.get("system: host", "/system/host")
    if host:
        hub.amend(True, f"{host.get('cpu', {}).get('cores')} cores, uptime {host.get('uptimeSeconds')} s")
    cont = hub.get("containers", "/containers")
    if cont:
        by_name = {c.get("name"): c for c in cont.get("items", [])}
        want = ["sonarr", "radarr", "jellyfin", "qbittorrent", "gluetun", "yams-hub"]
        missing = [n for n in want if n not in by_name]
        hub.amend(not missing, f"{len(by_name)} containers" + (f"; MISSING {missing}" if missing else ""))
        g = by_name.get("gluetun") or {}
        # VPN off, gluetun restarts forever (as in stock YAMS); VPN on, the stand-in runs.
        want_states = ("running",) if VARIANT == "vpn-on" else ("restarting", "exited")
        hub.get("containers: gluetun detail", "/containers/gluetun")
        hub.amend(g.get("state") in want_states,
                  f"state {g.get('state')} ({g.get('statusText')}), want {'/'.join(want_states)}")
    hub.get("media: now playing", "/media/now-playing")


# ----------------------------------------------------------------------------------------------------------------
# Issue #2: Sonarr's "Allowed Hosts" (config/host `allowedHosts`, config.xml <AllowedHosts>) without "sonarr".
# ASP.NET's host filtering is set up at start, so Sonarr must restart for a change to apply; it then answers
# "400 Bad Request - Invalid Hostname" (HTML) to every request whose Host is not listed (127.0.0.1 still works).
# ----------------------------------------------------------------------------------------------------------------
HOSTS_FIX = "Settings → General → Allowed Hosts"


def issue2(hub: Hub) -> dict:
    """Breaks Sonarr for the hub the way issue #2 did, in three phases, and records what the hub says in each:

    1. saved, Sonarr not restarted: Sonarr still accepts the hub; health and the dashboard must warn (pending);
    2. restarted: Sonarr rejects the hub; health, a fresh calendar window and the library card must name the cause
       (`upstream_host_rejected`, the Allowed Hosts fix) and the dashboard must raise the error alert;
    3. restored and restarted: the hub must recover by itself.
    issue2_rows() turns the result into checks.
    """
    result: dict = {"setting": "Sonarr Settings > General > Allowed Hosts (API config/host allowedHosts)"}
    key = arr_key("sonarr")
    sonarr = Client(base("sonarr"), {"X-Api-Key": key})
    cfg = sonarr.get("/api/v3/config/host").json()
    if not cfg or "allowedHosts" not in cfg:
        result["error"] = "Sonarr's config/host has no allowedHosts field"
        return result
    original = cfg.get("allowedHosts", "")

    def save_hosts(value: str) -> None:
        r = sonarr.put("/api/v3/config/host", {**cfg, "allowedHosts": value})
        if not r.ok:
            raise Fatal(f"Sonarr PUT config/host: HTTP {r.status} {r.text()[:200]}")

    def restart_sonarr() -> None:
        docker("restart", "sonarr")
        wait_until("Sonarr after restart", lambda: sonarr.get("/api/v3/system/status").ok, timeout=180)

    def as_hub() -> int:
        """Sonarr's answer to the Host header the hub sends (http://sonarr:8989)."""
        return sonarr.get("/api/v3/system/status", headers={"Host": "sonarr:8989"}).status

    def sonarr_health() -> dict:
        r = hub.c.get("/health", timeout=60)
        return next((x for x in (r.json() or {}).get("services", []) if x["id"] == "sonarr"), {})

    def health_says(*parts: str):
        """Polls /health (cached 30 s; the Allowed Hosts check 1 min) until Sonarr is degraded with all parts."""
        def check():
            x = sonarr_health()
            msg = x.get("message") or ""
            return x.get("status") == "degraded" and all(p in msg for p in parts) and x
        try:
            return wait_until(f"the hub's health of Sonarr to say {parts!r}", check, timeout=150, interval=5)
        except Fatal:
            return sonarr_health()

    def dashboard_library() -> dict:
        r = hub.c.get("/dashboard", query={"cards": "library"}, timeout=60)
        body = r.json() if isinstance(r.json(), dict) else {}
        alert = next((a for a in body.get("alerts", []) if a.get("id") == "sonarr.allowedHosts"), None)
        card = (body.get("cards") or {}).get("library") or {}
        health = (((card.get("data") or {}).get("sonarr") or {}).get("health")) or []
        return {"alert": None if alert is None else {k: alert.get(k) for k in ("severity", "title", "message")},
                "sonarr_health": [h.get("message") for h in health if h.get("type") == "error"],
                "card_status": card.get("status")}

    def dashboard_alert(severity: str) -> dict:
        """Polls the dashboard until the alert has [severity] (and, for the error, the library card the cause)."""
        def check():
            d = dashboard_library()
            card_ok = severity != "error" or any("rejects the hub" in m for m in d["sonarr_health"])
            return d["alert"] and d["alert"]["severity"] == severity and card_ok and d
        try:
            return wait_until(f"the dashboard's sonarr.allowedHosts {severity} alert", check, timeout=90, interval=5)
        except Fatal:
            return dashboard_library()

    windows = iter(range(1000))

    def fresh_calendar_source() -> dict:
        """sources.sonarr of a calendar window nobody asked for yet (the hub caches the calendar per window)."""
        start = dt.date.today() + dt.timedelta(days=60 + 7 * next(windows))
        r = hub.c.get("/calendar", query={"start": start.isoformat(),
                                          "end": (start + dt.timedelta(days=6)).isoformat()}, timeout=60)
        return (r.json() or {}).get("sources", {}).get("sonarr") or {"status": f"absent (HTTP {r.status})"}

    restored = False
    try:
        # Phase 1: saved, not restarted.
        save_hosts("localhost")
        result["pending_sonarr_as_hub_http"] = as_hub()
        sh = health_says("Allowed Hosts", "leaves out 'sonarr'", "after its next restart", HOSTS_FIX)
        result["pending_health_sonarr"] = {"status": sh.get("status"), "message": sh.get("message")}
        result["pending_dashboard"] = dashboard_alert("warning")

        # Phase 2: restarted, the setting applies.
        restart_sonarr()
        result["applied"] = "allowedHosts=localhost, Sonarr restarted"
        result["sonarr_as_hub_http"] = as_hub()
        result["setting_effective"] = result["sonarr_as_hub_http"] == 400
        sh = health_says("rejects the hub's hostname 'sonarr'", HOSTS_FIX, "then restart Sonarr")
        result["health_sonarr"] = {"status": sh.get("status"), "message": sh.get("message")}
        cal = fresh_calendar_source()
        result["calendar_sonarr_source"] = cal
        result["rejected_dashboard"] = dashboard_alert("error")
        # /library/tv serves its cached list while Sonarr fails (ItemList has no stale flag); recorded only.
        lib = hub.c.get("/library/tv", timeout=60)
        body = lib.json() if isinstance(lib.json(), dict) else {}
        err = body.get("error") or {}
        result["library_tv"] = {"status": lib.status, "code": err.get("code"), "message": err.get("message"),
                                "stale": body.get("stale"), "items": len(body.get("items") or [])}
    finally:
        save_hosts(original)
        restart_sonarr()
        restored = True
        result["restored"] = f"allowedHosts={original!r}, Sonarr restarted"
    # Phase 3: the hub must recover by itself once Sonarr accepts it again: health up without a message, a fresh
    # calendar window reads it, and the dashboard alert is gone.
    result["sonarr_as_hub_http_after_restore"] = as_hub()
    try:
        wait_until("the hub's health of Sonarr to be up again",
                   lambda: (x := sonarr_health()).get("status") == "up" and not x.get("message"),
                   timeout=120, interval=5)
        src = wait_until("a fresh calendar window to read Sonarr again",
                         lambda: (x := fresh_calendar_source()).get("status") == "ok" and x, timeout=60, interval=5)
        wait_until("the dashboard's sonarr.allowedHosts alert to clear",
                   lambda: dashboard_library()["alert"] is None, timeout=90, interval=5)
        result["recovered"] = True
        result["calendar_sonarr_source_after"] = {"status": src.get("status")}
    except Fatal as e:
        result["recovered"] = False
        result["recovery_error"] = str(e)
    result["restored_ok"] = restored
    return result


def issue2_rows(r: dict) -> None:
    if "error" in r:
        record("issue #2: Sonarr Allowed Hosts", False, r["error"])
        return
    # Phase 1: the proactive warning.
    ph = r.get("pending_health_sonarr") or {}
    pending_ok = (ph.get("status") == "degraded" and "after its next restart" in (ph.get("message") or "")
                  and HOSTS_FIX in (ph.get("message") or ""))
    record("issue #2: warns before restart (health)", pending_ok and r.get("pending_sonarr_as_hub_http") == 200,
           f"Sonarr still answers the hub {r.get('pending_sonarr_as_hub_http')}; health {ph.get('status')} "
           f"{ph.get('message')!r}", r.get("pending_sonarr_as_hub_http", ""))
    pa = (r.get("pending_dashboard") or {}).get("alert") or {}
    record("issue #2: warns before restart (dashboard)", pa.get("severity") == "warning"
           and "after its next restart" in (pa.get("title") or ""), f"alert {pa or None}")

    # Phase 2: the clear error everywhere.
    health = r.get("health_sonarr") or {}
    cal = r.get("calendar_sonarr_source") or {}
    cal_err = cal.get("error") or {}
    seen = f"health {health.get('status')} {health.get('message')!r}; calendar {cal.get('status')} " \
           f"{cal_err.get('code')} {cal_err.get('message')!r}"
    if not r.get("setting_effective"):
        # Sonarr no longer rejects the hub with this setting: nothing for the hub to name.
        rows.append(("issue #2: names the cause", str(r.get("sonarr_as_hub_http", "")), "",
                     f"note Sonarr answered Host sonarr:8989 with {r.get('sonarr_as_hub_http')} under "
                     f"allowedHosts=localhost after a restart (expected 400); {seen}"))
    else:
        want = "rejects the hub's hostname 'sonarr'"
        record("issue #2: names the cause (health)", health.get("status") == "degraded"
               and want in (health.get("message") or "") and HOSTS_FIX in (health.get("message") or ""),
               f"health {health.get('status')} {health.get('message')!r}", r.get("sonarr_as_hub_http", ""))
        record("issue #2: names the cause (calendar)", cal.get("status") == "error"
               and cal_err.get("code") == "upstream_host_rejected" and want in (cal_err.get("message") or ""),
               f"calendar {cal.get('status')} {cal_err.get('code')} {cal_err.get('message')!r}")
        rd = r.get("rejected_dashboard") or {}
        ra = rd.get("alert") or {}
        lib_msgs = rd.get("sonarr_health") or []
        record("issue #2: names the cause (dashboard)", ra.get("severity") == "error"
               and want in (ra.get("message") or "") and any(want in m for m in lib_msgs),
               f"alert {ra.get('severity')} {ra.get('title')!r}; library card {lib_msgs}")
    lib = r.get("library_tv") or {}
    rows.append(("issue #2: library/tv while rejected", str(lib.get("status", "")), "",
                 f"note served {lib.get('items')} cached items (ItemList has no stale flag; up to 10 min)"))

    # Phase 3: recovery.
    record("issue #2: hub recovers", bool(r.get("recovered")),
           "health up, a fresh calendar window ok and the alert gone after the restore" if r.get("recovered")
           else f"{r.get('recovery_error')} (Sonarr answers the hub's Host with "
                f"{r.get('sonarr_as_hub_http_after_restore')})",
           r.get("sonarr_as_hub_http_after_restore", ""))


def print_table() -> None:
    w = [max(len(r[i]) for r in rows + [("check", "http", "ms", "result")]) for i in range(3)]
    line = f"{'check':<{w[0]}}  {'http':>{w[1]}}  {'ms':>{w[2]}}  result"
    print("\n" + line + "\n" + "-" * min(len(line) + 60, 160))
    for c, s, ms, res in rows:
        print(f"{c:<{w[0]}}  {s:>{w[1]}}  {ms:>{w[2]}}  {res}")


def main() -> int:
    print(f"smoke test: hub {HUB}, variant {VARIANT}")
    sec = secrets()
    try:
        wait_until("the hub's /ping", lambda: Client(HUB).get("/api/v1/ping").ok, timeout=120)
        token = login(sec)
        hub = Hub(token)
        wait_healthy(hub)
        run_checks(hub)
    except Fatal as e:
        failures.append(str(e))
        hub = None

    report: dict = {"variant": VARIANT, "rows": rows, "failures": failures, "notes": notes}
    if hub is not None and not os.environ.get("SANDBOX_SKIP_ISSUE2"):
        try:
            r = issue2(hub)
        except Fatal as e:
            r = {"error": str(e)}
            failures.append(f"issue #2 check could not run or restore: {e}")
        report["issue2"] = r
        issue2_rows(r)

    print_table()
    for n in notes:
        print(f"note: {n}")
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    (ARTIFACTS / f"smoke-{VARIANT}.json").write_text(json.dumps(report, indent=2) + "\n")
    if failures:
        print(f"\nFAILED ({len(failures)}):", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print("\n--- docker logs yams-hub (last 200 lines) ---", file=sys.stderr)
        print(docker("logs", "--tail", "200", "yams-hub", check=False), file=sys.stderr)
        return 1
    print(f"\nsmoke test passed ({len(rows)} checks, {VARIANT})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
