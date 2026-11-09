#!/usr/bin/env python3
"""Seeds the sandbox YAMS stack through the apps' own HTTP APIs (run by `run.sh seed`). Idempotent: every step
reads the current state first and only adds what is missing, so it can run again at any time.

  Jellyfin     startup wizard (admin user), an API key named "YAMS Hub", Shows and Movies libraries
  qBittorrent  Web UI password (from the temporary password linuxserver prints in its log)
  Sonarr       root folder /data/tvshows and real shows found through lookup (needs internet)
  Radarr       root folder /data/movies and real movies found through lookup (needs internet)
  Prowlarr     the Sonarr and Radarr applications
  Bazarr       Sonarr and Radarr connections (best effort)
  Seerr        setup against Jellyfin, libraries, Sonarr/Radarr servers (best effort; skipped with a warning)

Writes state/jellyfin_api_key (0600), which `run.sh install` puts into install.sh's answers file.
"""

from __future__ import annotations

import datetime as dt
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sbx import Client, Fatal, arr_key, base, docker, log, secrets, state_get, state_put, wait_until, warn  # noqa: E402

VARIANT = os.environ.get("SANDBOX_VARIANT", "vpn-off")
JF_AUTH = 'MediaBrowser Client="yams-hub-sandbox", Device="sandbox", DeviceId="yams-hub-sandbox", Version="1.0"'

# Shows: two that air daily (so this month's calendar always has episodes) and one that ended.
SHOWS = [
    ("tvdb:71256", "The Daily Show"),
    ("tvdb:71565", "Coronation Street"),
    ("tvdb:81189", "Breaking Bad"),
]
# Fallbacks, tried in order when the calendar of this month is still empty.
CALENDAR_FALLBACKS = [
    ("tvdb:77715", "Emmerdale"),
    ("tvdb:270262", "The Tonight Show Starring Jimmy Fallon"),
]
MOVIES = [
    ("tmdb:603", "The Matrix"),
    ("tmdb:27205", "Inception"),
    ("tmdb:129", "Spirited Away"),
]


def month_window() -> tuple[str, str]:
    today = dt.date.today()
    first = today.replace(day=1)
    nxt = (first + dt.timedelta(days=32)).replace(day=1)
    return first.isoformat(), (nxt - dt.timedelta(days=1)).isoformat()


# ----------------------------------------------------------------------------------------------------------------
# Jellyfin
# ----------------------------------------------------------------------------------------------------------------
def seed_jellyfin(sec: dict[str, str]) -> None:
    jf = Client(base("jellyfin"), {"Authorization": JF_AUTH})
    info = wait_until("Jellyfin", lambda: (r := jf.get("/System/Info/Public")).ok and r.json(), timeout=240)
    log(f"jellyfin {info.get('Version')}: wizard {'done' if info.get('StartupWizardCompleted') else 'pending'}")
    user, password = sec["SBX_JELLYFIN_USER"], sec["SBX_JELLYFIN_PASSWORD"]
    if not info.get("StartupWizardCompleted"):
        steps = [
            ("POST", "/Startup/Configuration",
             {"UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"}),
            ("GET", "/Startup/User", None),  # creates the default user the next call renames
            ("POST", "/Startup/User", {"Name": user, "Password": password}),
            ("POST", "/Startup/RemoteAccess", {"EnableRemoteAccess": True, "EnableAutomaticPortMapping": False}),
            ("POST", "/Startup/Complete", None),
        ]
        for method, path, body in steps:
            # The first calls can answer 503 while Jellyfin finishes starting.
            r = wait_until(f"Jellyfin {path}", lambda: (x := jf.request(method, path, body)).status != 503 and x,
                           timeout=60)
            if not r.ok:
                raise Fatal(f"Jellyfin {method} {path}: HTTP {r.status} {r.text()[:200]}")
        log("  startup wizard completed")

    def login():
        r = jf.post("/Users/AuthenticateByName", {"Username": user, "Pw": password})
        return r.json() if r.ok else None

    auth = wait_until("Jellyfin login", login, timeout=60)
    token = auth["AccessToken"]
    admin = Client(base("jellyfin"), {"Authorization": f'{JF_AUTH}, Token="{token}"'})

    def hub_key():
        r = admin.get("/Auth/Keys")
        if not r.ok:
            raise Fatal(f"Jellyfin GET /Auth/Keys: HTTP {r.status}")
        for k in r.json().get("Items", []):
            if k.get("AppName") == "YAMS Hub":
                return k.get("AccessToken")
        return None

    key = hub_key()
    if not key:
        r = admin.post("/Auth/Keys", query={"app": "YAMS Hub"})
        if not r.ok:
            raise Fatal(f"Jellyfin POST /Auth/Keys: HTTP {r.status} {r.text()[:200]}")
        key = hub_key()
        log("  API key created")
    if not key:
        raise Fatal("Jellyfin created no API key")
    state_put("jellyfin_api_key", key)

    r = admin.get("/Library/VirtualFolders")
    have = {f.get("Name") for f in (r.json() or [])} if r.ok else set()
    for name, kind, path in [("Shows", "tvshows", "/data/tvshows"), ("Movies", "movies", "/data/movies")]:
        if name in have:
            continue
        r = admin.post("/Library/VirtualFolders",
                       {"LibraryOptions": {"EnableRealtimeMonitor": False, "EnableInternetProviders": False}},
                       query={"name": name, "collectionType": kind, "paths": path, "refreshLibrary": "false"})
        if not r.ok:
            raise Fatal(f"Jellyfin library {name}: HTTP {r.status} {r.text()[:200]}")
        log(f"  library {name} -> {path}")
    log("jellyfin: ok")


# ----------------------------------------------------------------------------------------------------------------
# qBittorrent
# ----------------------------------------------------------------------------------------------------------------
def seed_qbittorrent(sec: dict[str, str]) -> None:
    user, password = sec["SBX_QBIT_USER"], sec["SBX_QBIT_PASSWORD"]
    url = base("qbittorrent")
    # qBittorrent refuses requests whose Host header names another port than its own (the published port is 28081),
    # so the Host header names the container port.
    host = {"Host": "127.0.0.1:8081"}
    wait_until("qBittorrent", lambda: Client(url, host).get("/api/v2/app/version").status in (200, 401, 403),
               timeout=120)

    def login(pw: str) -> Client | None:
        c = Client(url, host, cookies=True)
        r = c.post("/api/v2/auth/login", form={"username": user, "password": pw})
        # qBittorrent 5 answers 204 (older: 200 "Ok."); a wrong password is 401 (older: 200 "Fails.").
        return c if r.ok and r.text().strip() != "Fails." else None

    c = login(password)
    if c is None:
        # linuxserver/qbittorrent prints a temporary password for the session until one is set.
        def temp_password():
            found = re.findall(r"temporary password is provided for this session: (\S+)",
                               docker("logs", "qbittorrent", check=False))
            return found[-1] if found else None

        temp = wait_until("qBittorrent's temporary password in its log", temp_password, timeout=60)
        c = login(temp)
        if c is None:
            raise Fatal("qBittorrent rejected both the sandbox password and the temporary one from its log "
                        "(too many failed logins ban the IP for a while: run.sh down && run.sh up)")
        r = c.post("/api/v2/app/setPreferences", form={"json": f'{{"web_ui_password": "{password}"}}'})
        if not r.ok:
            raise Fatal(f"qBittorrent setPreferences: HTTP {r.status}")
        c = login(password)
        if c is None:
            raise Fatal("qBittorrent: the new password does not work")
        log("  Web UI password set")
    r = c.post("/api/v2/app/setPreferences",
               form={"json": '{"save_path": "/data/downloads/torrents", "temp_path_enabled": false}'})
    if not r.ok:
        raise Fatal(f"qBittorrent setPreferences: HTTP {r.status}")
    log(f"qbittorrent {c.get('/api/v2/app/version').text().strip()}: ok")


# ----------------------------------------------------------------------------------------------------------------
# Sonarr / Radarr
# ----------------------------------------------------------------------------------------------------------------
def arr_client(service: str) -> Client:
    wait_until(f"{service}", lambda: Client(base(service)).get("/ping").ok, timeout=180)
    key = wait_until(f"{service}'s API key", lambda: arr_key(service), timeout=60)
    c = Client(base(service), {"X-Api-Key": key})
    wait_until(f"{service} API", lambda: c.get("/api/v3/system/status").ok, timeout=60)
    return c


def root_folder(c: Client, service: str, path: str) -> None:
    r = c.get("/api/v3/rootfolder")
    if r.ok and any(f.get("path", "").rstrip("/") == path for f in r.json()):
        return
    r = c.post("/api/v3/rootfolder", {"path": path})
    if not r.ok:
        raise Fatal(f"{service} root folder {path}: HTTP {r.status} {r.text()[:300]}")
    log(f"  root folder {path}")


def quality_profile(c: Client, service: str) -> int:
    r = c.get("/api/v3/qualityprofile")
    if not r.ok or not r.json():
        raise Fatal(f"{service} has no quality profile (HTTP {r.status})")
    return r.json()[0]["id"]


def lookup(c: Client, service: str, path: str, term: str, title: str) -> dict:
    r = c.get(path, query={"term": term}, timeout=60)
    if not r.ok or not isinstance(r.json(), list) or not r.json():
        raise Fatal(f"{service} lookup of {title} ({term}) failed: HTTP {r.status} {r.text()[:200]!r}. "
                    "Lookups need internet access (Sonarr: skyhook.sonarr.tv, Radarr: api.radarr.video).")
    return r.json()[0]


def add_show(c: Client, profile: int, term: str, title: str, have: set[int]) -> bool:
    item = lookup(c, "sonarr", "/api/v3/series/lookup", term, title)
    if item.get("tvdbId") in have:
        return False
    item.update({
        "qualityProfileId": profile,
        "rootFolderPath": "/data/tvshows",
        "monitored": True,
        "seasonFolder": True,
        "addOptions": {"monitor": "all", "searchForMissingEpisodes": False,
                       "searchForCutoffUnmetEpisodes": False},
    })
    r = c.post("/api/v3/series", item, timeout=60)
    if not r.ok:
        raise Fatal(f"sonarr add {title}: HTTP {r.status} {r.text()[:300]}")
    have.add(item.get("tvdbId"))
    log(f"  added show {item.get('title')} ({item.get('year')}, {item.get('status')})")
    return True


def calendar_count(c: Client) -> int:
    start, end = month_window()
    r = c.get("/api/v3/calendar", query={"start": start, "end": f"{end}T23:59:59Z", "unmonitored": "false"})
    return len(r.json() or []) if r.ok else 0


def seed_sonarr() -> None:
    c = arr_client("sonarr")
    root_folder(c, "sonarr", "/data/tvshows")
    profile = quality_profile(c, "sonarr")
    r = c.get("/api/v3/series")
    have = {s.get("tvdbId") for s in (r.json() or [])} if r.ok else set()
    for term, title in SHOWS:
        add_show(c, profile, term, title, have)
    # Sonarr fetches the episodes in the background after an add.
    count = 0
    for term, title in [(None, None), *CALENDAR_FALLBACKS]:
        if term:
            warn(f"no episodes in this month's calendar yet; adding {title}")
            add_show(c, profile, term, title, have)
        try:
            count = wait_until("episodes in Sonarr's calendar", lambda: calendar_count(c), timeout=120, interval=3)
            break
        except Fatal:
            continue
    if not count:
        raise Fatal("Sonarr's calendar for this month stays empty (episode refresh needs skyhook.sonarr.tv)")
    log(f"sonarr: ok ({len(have)} shows, {count} calendar episodes this month)")


def seed_radarr() -> None:
    c = arr_client("radarr")
    root_folder(c, "radarr", "/data/movies")
    profile = quality_profile(c, "radarr")
    r = c.get("/api/v3/movie")
    have = {m.get("tmdbId") for m in (r.json() or [])} if r.ok else set()
    for term, title in MOVIES:
        item = lookup(c, "radarr", "/api/v3/movie/lookup", term, title)
        if item.get("tmdbId") in have:
            continue
        item.update({
            "qualityProfileId": profile,
            "rootFolderPath": "/data/movies",
            "monitored": True,
            "minimumAvailability": "released",
            "addOptions": {"monitor": "movieOnly", "searchForMovie": False},
        })
        r = c.post("/api/v3/movie", item, timeout=60)
        if not r.ok:
            raise Fatal(f"radarr add {title}: HTTP {r.status} {r.text()[:300]}")
        have.add(item.get("tmdbId"))
        log(f"  added movie {item.get('title')} ({item.get('year')})")
    log(f"radarr: ok ({len(have)} movies)")


# ----------------------------------------------------------------------------------------------------------------
# Prowlarr
# ----------------------------------------------------------------------------------------------------------------
def seed_prowlarr() -> None:
    wait_until("prowlarr", lambda: Client(base("prowlarr")).get("/ping").ok, timeout=180)
    key = wait_until("prowlarr's API key", lambda: arr_key("prowlarr"), timeout=60)
    c = Client(base("prowlarr"), {"X-Api-Key": key})
    wait_until("prowlarr API", lambda: c.get("/api/v1/system/status").ok, timeout=60)
    r = c.get("/api/v1/applications")
    have = {a.get("implementation") for a in (r.json() or [])} if r.ok else set()
    schema = c.get("/api/v1/applications/schema").json() or []
    for impl, port in [("Sonarr", 8989), ("Radarr", 7878)]:
        if impl in have:
            continue
        app = next((s for s in schema if s.get("implementation") == impl), None)
        if app is None:
            raise Fatal(f"prowlarr has no {impl} application schema")
        values = {
            "prowlarrUrl": "http://prowlarr:9696",
            "baseUrl": f"http://{impl.lower()}:{port}",
            "apiKey": arr_key(impl.lower()),
        }
        for f in app.get("fields", []):
            if f.get("name") in values:
                f["value"] = values[f["name"]]
        app.update({"name": impl, "syncLevel": "fullSync", "tags": []})
        r = c.post("/api/v1/applications", app)
        if not r.ok:
            raise Fatal(f"prowlarr add {impl}: HTTP {r.status} {r.text()[:300]}")
        log(f"  application {impl}")
    log("prowlarr: ok")


# ----------------------------------------------------------------------------------------------------------------
# Bazarr (best effort)
# ----------------------------------------------------------------------------------------------------------------
def bazarr_key() -> str | None:
    p = os.path.join(os.environ["SANDBOX_DIR"], "yams/config/bazarr/config/config.yaml")
    try:
        text = open(p).read()
    except OSError:
        return None
    m = re.search(r"^auth:\n(?:[ \t]+.*\n)*?[ \t]+apikey:[ \t]*['\"]?([A-Za-z0-9]+)", text, re.M)
    return m.group(1) if m else None


def seed_bazarr() -> None:
    wait_until("bazarr", lambda: Client(base("bazarr")).get("/api/system/ping").ok, timeout=180)
    key = wait_until("bazarr's API key", bazarr_key, timeout=60)
    c = Client(base("bazarr"), {"X-API-KEY": key})
    r = c.get("/api/system/settings")
    s = r.json() if r.ok else None
    if not s:
        raise Fatal(f"bazarr GET /api/system/settings: HTTP {r.status}")
    if s.get("general", {}).get("use_sonarr") and s.get("general", {}).get("use_radarr"):
        log("bazarr: ok (already connected)")
        return
    form = {
        "settings-general-use_sonarr": "true",
        "settings-sonarr-ip": "sonarr",
        "settings-sonarr-port": "8989",
        "settings-sonarr-base_url": "/",
        "settings-sonarr-apikey": arr_key("sonarr"),
        "settings-general-use_radarr": "true",
        "settings-radarr-ip": "radarr",
        "settings-radarr-port": "7878",
        "settings-radarr-base_url": "/",
        "settings-radarr-apikey": arr_key("radarr"),
    }
    r = c.post("/api/system/settings", form=form)
    if not r.ok:
        raise Fatal(f"bazarr POST /api/system/settings: HTTP {r.status} {r.text()[:200]}")
    log("bazarr: ok (connected to sonarr and radarr)")


# ----------------------------------------------------------------------------------------------------------------
# Seerr (best effort)
# ----------------------------------------------------------------------------------------------------------------
def seed_seerr(sec: dict[str, str]) -> None:
    c = Client(base("seerr"), cookies=True)
    pub = wait_until("seerr", lambda: (r := c.get("/api/v1/settings/public")).ok and r.json(), timeout=180)
    user, password = sec["SBX_JELLYFIN_USER"], sec["SBX_JELLYFIN_PASSWORD"]
    body = {"username": user, "password": password, "email": "admin@sandbox.invalid"}
    if not pub.get("initialized"):
        body.update({"hostname": "jellyfin", "port": 8096, "useSsl": False, "urlBase": "", "serverType": 2})
    r = c.post("/api/v1/auth/jellyfin", body, timeout=60)
    if r.status == 500 and "already configured" in r.text():
        # An earlier run got past the login but not to the end of the setup.
        r = c.post("/api/v1/auth/jellyfin", {k: body[k] for k in ("username", "password", "email")}, timeout=60)
    if not r.ok:
        raise Fatal(f"seerr Jellyfin login: HTTP {r.status} {r.text()[:300]}")
    if pub.get("initialized"):
        log("seerr: ok (already set up)")
        return
    # Seerr 3: POST .../library/sync, then PUT .../library/{id} (Jellyseerr 2 used GET ?sync=true / ?enable=ids).
    r = c.post("/api/v1/settings/jellyfin/library/sync", timeout=60)
    libs = r.json() if r.ok else None
    if not libs:
        raise Fatal(f"seerr library sync: HTTP {r.status} {r.text()[:200]}")
    for lib in libs:
        r = c.put(f"/api/v1/settings/jellyfin/library/{lib['id']}", {"enabled": True})
        if not r.ok:
            raise Fatal(f"seerr enable library {lib.get('name')}: HTTP {r.status} {r.text()[:200]}")
    for svc, port, root in [("sonarr", 8989, "/data/tvshows"), ("radarr", 7878, "/data/movies")]:
        server = {"name": svc.capitalize(), "hostname": svc, "port": port, "apiKey": arr_key(svc), "useSsl": False,
                  "baseUrl": "", "is4k": False, "isDefault": True, "syncEnabled": False, "preventSearch": True,
                  "activeDirectory": root, "tags": [], "externalUrl": ""}
        t = c.post(f"/api/v1/settings/{svc}/test", {k: server[k] for k in ("hostname", "port", "apiKey", "useSsl",
                                                                           "baseUrl")})
        profiles = (t.json() or {}).get("profiles") if t.ok else None
        if not profiles:
            warn(f"seerr cannot test {svc} (HTTP {t.status}); left out")
            continue
        server.update({"activeProfileId": profiles[0]["id"], "activeProfileName": profiles[0]["name"]})
        if svc == "sonarr":
            server.update({"seriesType": "standard", "animeSeriesType": "anime", "enableSeasonFolders": True,
                           "activeAnimeProfileId": profiles[0]["id"], "activeAnimeProfileName": profiles[0]["name"],
                           "activeAnimeDirectory": root, "activeLanguageProfileId": 1})
        else:
            server.update({"minimumAvailability": "released"})
        r = c.post(f"/api/v1/settings/{svc}", server)
        if not r.ok:
            warn(f"seerr add {svc}: HTTP {r.status} {r.text()[:200]}")
    r = c.post("/api/v1/settings/initialize")
    if not r.ok:
        raise Fatal(f"seerr initialize: HTTP {r.status} {r.text()[:200]}")
    log("seerr: ok (set up against Jellyfin)")


def main() -> int:
    sec = secrets()
    steps = [
        ("jellyfin", lambda: seed_jellyfin(sec), True),
        ("qbittorrent", lambda: seed_qbittorrent(sec), True),
        ("sonarr", seed_sonarr, True),
        ("radarr", seed_radarr, True),
        ("prowlarr", seed_prowlarr, True),
        ("bazarr", seed_bazarr, False),
        ("seerr", lambda: seed_seerr(sec), False),
    ]
    failed = []
    t0 = time.monotonic()
    for name, fn, required in steps:
        try:
            fn()
        except Fatal as e:
            if required:
                print(f"seed: {name}: ERROR: {e}", file=sys.stderr)
                failed.append(name)
            else:
                warn(f"{name} skipped: {e}")
    if failed:
        print(f"seed failed: {', '.join(failed)}", file=sys.stderr)
        return 1
    if not state_get("jellyfin_api_key"):
        print("seed: no Jellyfin API key was stored", file=sys.stderr)
        return 1
    log(f"seed: done in {time.monotonic() - t0:.0f} s ({VARIANT})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
