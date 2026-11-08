#!/usr/bin/env python3
"""Mock upstream services for the YAMS Hub mobile-web benchmark (tool/perf).

Impersonates Sonarr, Radarr, Prowlarr, Bazarr, Seerr, Jellyfin, Jellystat,
qBittorrent, Gluetun, the Docker socket proxy, Watchtower, Uptime Kuma,
Audiobookshelf and Shelfmark, each on its own localhost port, answering from
the captured fixtures in ../../fixtures. Kavita and the updater stay
unconfigured.

The fixtures hold ~5 records per list; the benchmark needs a library and a
Discover feed big enough to scroll, so the main lists are amplified by cloning
records with fresh ids (`--scale`, default 1.0 = 120 movies, 60 series,
20 Discover results per page). Clones of Seerr titles use poster paths from a
pool of real TMDB paths found in the fixtures, so the gateway's TMDB proxy
fetches real, distinct images from image.tmdb.org.

*arr `MediaCover` images are generated JPEG posters (Pillow): by default every
poster variant is ~1000x1500 (`--poster-mode full`, a few hundred KB, like a
real full-size poster); `--poster-mode arr` serves the size a real *arr
serves for the variant (poster-500.jpg is 500x750).

Usage:
  python3 mock_upstreams.py --base-port 18100 --env-out mock.env [--scale 1]

`--env-out` writes the `*_URL` / secret lines the gateway's secrets file needs.
Requests nothing answers are logged to stderr as `UNMATCHED ...` (and answered
with a fallback) so missing routes are easy to spot.
"""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import io
import json
import os
import random
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / "fixtures"

SERVICES = [
    # name, url var, secret var(s)
    ("sonarr", "SONARR_URL", {"SONARR_API_KEY": "mock-sonarr-key"}),
    ("radarr", "RADARR_URL", {"RADARR_API_KEY": "mock-radarr-key"}),
    ("prowlarr", "PROWLARR_URL", {"PROWLARR_API_KEY": "mock-prowlarr-key"}),
    ("bazarr", "BAZARR_URL", {"BAZARR_API_KEY": "mock-bazarr-key"}),
    ("seerr", "SEERR_URL", {"SEERR_API_KEY": "mock-seerr-key"}),
    ("jellyfin", "JELLYFIN_URL", {"JELLYFIN_API_KEY": "mock-jellyfin-key"}),
    ("jellystat", "JELLYSTAT_URL", {"JELLYSTAT_API_KEY": "mock-jellystat-key"}),
    ("qbittorrent", "QBIT_URL", {"QBIT_USERNAME": "admin", "QBIT_PASSWORD": "mock-qbit-pass"}),
    ("gluetun", "GLUETUN_URL", {}),
    ("docker", "DOCKER_URL", {}),
    ("watchtower", "WATCHTOWER_URL", {"WATCHTOWER_TOKEN": "mock-watchtower-token"}),
    ("uptimekuma", "UPTIME_KUMA_URL", {}),
    ("audiobookshelf", "ABS_URL", {"ABS_API_KEY": "mock-abs-key"}),
    ("shelfmark", "SHELFMARK_URL", {}),
]


def fx(rel: str):
    with open(FIX / rel, "rb") as f:
        return json.loads(f.read())


def fx_or(rel: str, default):
    try:
        return fx(rel)
    except FileNotFoundError:
        return default


# ---------------------------------------------------------------------------
# Generated images
# ---------------------------------------------------------------------------

_img_lock = threading.Lock()
_img_cache: dict[tuple, bytes] = {}


def make_jpeg(seed: str, w: int, h: int, quality: int = 88) -> bytes:
    """A poster-like JPEG: colour gradient + shapes + film-grain noise.

    The noise keeps the file size (and decode cost) close to a real poster
    (~250-450 KB at 1000x1500)."""
    key = (seed, w, h, quality)
    with _img_lock:
        hit = _img_cache.get(key)
    if hit is not None:
        return hit
    from PIL import Image, ImageDraw, ImageFilter

    rnd = random.Random(seed)
    c1 = tuple(rnd.randrange(30, 220) for _ in range(3))
    c2 = tuple(rnd.randrange(10, 160) for _ in range(3))
    # Vertical gradient built small and scaled up (fast).
    grad = Image.new("RGB", (1, 256))
    for y in range(256):
        t = y / 255
        grad.putpixel((0, y), tuple(int(c1[i] * (1 - t) + c2[i] * t) for i in range(3)))
    img = grad.resize((w, h))
    d = ImageDraw.Draw(img)
    for _ in range(14):
        x0, y0 = rnd.randrange(-w // 4, w), rnd.randrange(-h // 4, h)
        s = rnd.randrange(w // 10, w // 2)
        col = tuple(rnd.randrange(0, 256) for _ in range(3))
        if rnd.random() < 0.5:
            d.ellipse([x0, y0, x0 + s, y0 + s], fill=col)
        else:
            d.rectangle([x0, y0, x0 + s, y0 + s * 2 // 3], fill=col)
    img = img.filter(ImageFilter.GaussianBlur(radius=max(1, w // 200)))
    d = ImageDraw.Draw(img)
    d.rectangle([0, int(h * 0.78), w, h], fill=(10, 10, 14))
    d.text((w // 20, int(h * 0.82)), seed[:40], fill=(240, 240, 240))
    noise = Image.effect_noise((w, h), 40).convert("RGB")
    img = Image.blend(img, noise, 0.12)
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, optimize=False)
    data = buf.getvalue()
    with _img_lock:
        _img_cache[key] = data
    return data


ARR_VARIANTS = {
    # file stem -> (w, h) a real *arr serves
    "poster": (1000, 1500),
    "poster-500": (500, 750),
    "poster-250": (250, 375),
    "fanart": (1920, 1080),
    "fanart-360": (640, 360),
    "fanart-180": (320, 180),
    "banner": (758, 140),
    "banner-70": (379, 70),
}


# ---------------------------------------------------------------------------
# Data set (fixtures + amplification)
# ---------------------------------------------------------------------------


class Data:
    def __init__(self, scale: float):
        self.scale = scale
        n_movies = max(5, int(120 * scale))
        n_series = max(5, int(60 * scale))
        self.page_size = 20
        self.discover_pages = 10

        # Pool of real TMDB poster/backdrop paths found in the fixtures.
        posters, backdrops = set(), set()
        for p in FIX.rglob("*.json"):
            txt = p.read_text(errors="ignore")
            posters.update(re.findall(r'"posterPath":\s*"(/[A-Za-z0-9_-]+\.(?:jpg|png))"', txt))
            backdrops.update(re.findall(r'"backdropPath":\s*"(/[A-Za-z0-9_-]+\.(?:jpg|png))"', txt))
            posters.update(
                re.findall(r'image\.tmdb\.org/t/p/[a-z0-9]+(/[A-Za-z0-9_-]+\.(?:jpg|png))', txt)
            )
        self.poster_pool = sorted(posters)
        self.backdrop_pool = sorted(backdrops) or self.poster_pool

        # --- Radarr movies ---
        base = fx("arr/radarr_movie.json")
        self.movies = []
        for i in range(n_movies):
            m = copy.deepcopy(base[i % len(base)])
            mid = i + 1
            k = i // len(base)
            m["id"] = mid
            if k:
                m["title"] = f"{m['title']} #{k + 1}"
                m["sortTitle"] = m["title"].lower()
                m["tmdbId"] = 9_000_000 + mid
                m["titleSlug"] = str(m["tmdbId"])
                m["imdbId"] = f"tt9{mid:07d}"
            h = hashlib.sha1(f"movie{mid}".encode()).hexdigest()[:20]
            for img in m.get("images", []):
                img["url"] = f"/MediaCover/{mid}/{img['coverType']}.jpg?h={h}"
            if isinstance(m.get("movieFile"), dict):
                m["movieFile"]["movieId"] = mid
            m["movieFileId"] = 1000 + mid
            self.movies.append(m)
        self.movie_by_id = {m["id"]: m for m in self.movies}

        # --- Sonarr series ---
        base = fx("arr/sonarr_series.json")
        self.series = []
        for i in range(n_series):
            s = copy.deepcopy(base[i % len(base)])
            sid = i + 1
            k = i // len(base)
            s["id"] = sid
            if k:
                s["title"] = f"{s['title']} #{k + 1}"
                s["sortTitle"] = s["title"].lower()
                s["tvdbId"] = 9_000_000 + sid
                s["tmdbId"] = 9_100_000 + sid
                s["titleSlug"] = f"{s.get('titleSlug', 'series')}-{k + 1}"
            lw = 639058149420000000 + sid
            for img in s.get("images", []):
                ext = "png" if img["coverType"] == "clearlogo" else "jpg"
                img["url"] = f"/MediaCover/{sid}/{img['coverType']}.{ext}?lastWrite={lw}"
            self.series.append(s)
        self.series_by_id = {s["id"]: s for s in self.series}

        self.movie_detail = fx("arr/radarr_movie_id.json")
        self.series_detail = fx("arr/sonarr_series_id.json")

    # Seerr --------------------------------------------------------------
    def poster_for(self, n: int) -> str:
        return self.poster_pool[n % len(self.poster_pool)]

    def backdrop_for(self, n: int) -> str:
        return self.backdrop_pool[n % len(self.backdrop_pool)]

    def seerr_page(self, rel: str, page: int, salt: int) -> dict:
        body = fx(rel)
        results = body.get("results") or []
        if not results:
            return body
        out = []
        for j in range(self.page_size):
            idx = (page - 1) * self.page_size + j
            r = copy.deepcopy(results[idx % len(results)])
            if idx >= len(results):
                n = salt * 100_000 + idx
                r["id"] = 8_000_000 + n
                if r.get("mediaInfo"):
                    r["mediaInfo"] = None
                for key in ("title", "name"):
                    if key in r and r[key]:
                        r[key] = f"{r[key]} #{idx // len(results) + 1}"
                r["posterPath"] = self.poster_for(n)
                if "backdropPath" in r:
                    r["backdropPath"] = self.backdrop_for(n)
            out.append(r)
        body = dict(body)
        body["page"] = page
        body["totalPages"] = self.discover_pages
        body["totalResults"] = self.discover_pages * self.page_size
        body["results"] = out
        return body


# ---------------------------------------------------------------------------
# HTTP plumbing
# ---------------------------------------------------------------------------


class Resp:
    def __init__(self, status=200, body=b"", ctype="application/json", headers=None, stream=False):
        self.status = status
        self.body = body
        self.ctype = ctype
        self.headers = headers or {}
        self.stream = stream


def J(obj, status=200, headers=None) -> Resp:
    return Resp(status, json.dumps(obj).encode(), "application/json; charset=utf-8", headers)


def T(text: str, status=200) -> Resp:
    return Resp(status, text.encode(), "text/plain; charset=utf-8")


def F(rel: str, status=200) -> Resp:
    return Resp(status, (FIX / rel).read_bytes(), "application/json; charset=utf-8")


def JPEG(seed, w, h) -> Resp:
    return Resp(200, make_jpeg(seed, w, h), "image/jpeg",
                {"cache-control": "public, max-age=31536000"})


class Req:
    def __init__(self, method, path, query, body, headers):
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.headers = headers

    def q(self, k, default=None):
        v = self.query.get(k) or self.query.get(k.lower())
        if v is None:
            for kk, vv in self.query.items():
                if kk.lower() == k.lower():
                    return vv[0]
            return default
        return v[0]

    def qi(self, k, default=0):
        try:
            return int(self.q(k, default))
        except (TypeError, ValueError):
            return default


Route = tuple  # (method, compiled regex, handler)


def routes(*specs):
    return [(m, re.compile("^" + p + "$"), h) for (m, p, h) in specs]


# ---------------------------------------------------------------------------
# Per-service routes
# ---------------------------------------------------------------------------


def paged(records, req: Req, page_key="page", size_key="pageSize"):
    page = max(1, req.qi(page_key, 1))
    size = max(1, req.qi(size_key, 20))
    start = (page - 1) * size
    return {
        "page": page,
        "pageSize": size,
        "sortKey": req.q("sortKey", "id"),
        "sortDirection": req.q("sortDirection", "descending"),
        "totalRecords": len(records),
        "records": records[start:start + size],
    }


def arr_common(svc: str, D: Data, poster_mode: str):
    pre = svc  # fixture prefix

    def media_cover(r: Req, m):
        item_id, stem, ext = m.group(1), m.group(2), m.group(3)
        if ext == "png":  # clearlogo
            from PIL import Image
            img = Image.new("RGBA", (800, 310), (255, 255, 255, 0))
            buf = io.BytesIO()
            img.save(buf, "PNG")
            return Resp(200, buf.getvalue(), "image/png")
        w, h = ARR_VARIANTS.get(stem, (1000, 1500))
        if poster_mode == "full" and stem.startswith("poster"):
            w, h = 1000, 1500
        return JPEG(f"{svc} {item_id} {stem.split('-')[0]}", w, h)

    def history(r: Req, m):
        body = fx(f"arr/{pre}_history.json")
        return J(paged(body["records"], r))

    def wanted(kind):
        def h(r: Req, m):
            body = fx(f"arr/{pre}_wanted_{kind}.json")
            return J(paged(body["records"], r))
        return h

    def queue(r: Req, m):
        body = fx(f"arr/{pre}_queue.json")
        return J(paged(body.get("records", []), r))

    def command_post(r: Req, m):
        return J({"id": 1, "name": "Mock", "status": "queued", "state": "queued"}, 201)

    return routes(
        ("GET", r"/MediaCover/([^/]+)/([a-z]+(?:-\d+)?)\.(jpg|png)", media_cover),
        ("GET", r"/ping", lambda r, m: J({"status": "OK"})),
        ("GET", r"/api/v3/system/status", lambda r, m: F(f"arr/{pre}_system_status.json")),
        ("GET", r"/api/v3/health", lambda r, m: F(f"arr/{pre}_health.json")),
        ("GET", r"/api/v3/diskspace", lambda r, m: F(f"arr/{pre}_diskspace.json")),
        ("GET", r"/api/v3/rootfolder", lambda r, m: F(f"arr/{pre}_rootfolder.json")),
        ("GET", r"/api/v3/tag", lambda r, m: F(f"arr/{pre}_tag.json")),
        ("GET", r"/api/v3/qualityprofile", lambda r, m: F(f"arr/{pre}_qualityprofile.json")),
        ("GET", r"/api/v3/languageprofile", lambda r, m: J(fx_or(f"arr/{pre}_languageprofile.json", []))),
        ("GET", r"/api/v3/queue/status", lambda r, m: F(f"arr/{pre}_queue_status.json")),
        ("GET", r"/api/v3/queue/details", lambda r, m: F(f"arr/{pre}_queue_details.json")),
        ("GET", r"/api/v3/queue", queue),
        ("GET", r"/api/v3/history/since", lambda r, m: J(fx_or(f"arr/{pre}_history_since.json", []))),
        ("GET", r"/api/v3/history/movie", lambda r, m: J(fx_or(f"arr/{pre}_history_movie.json", []))),
        ("GET", r"/api/v3/history/series", lambda r, m: J([])),
        ("GET", r"/api/v3/history", history),
        ("GET", r"/api/v3/wanted/missing", wanted("missing")),
        ("GET", r"/api/v3/wanted/cutoff", wanted("cutoff")),
        ("GET", r"/api/v3/calendar", lambda r, m: F(f"arr/{pre}_calendar.json")),
        ("GET", r"/api/v3/command", lambda r, m: F(f"arr/{pre}_command.json")),
        ("GET", r"/api/v3/command/(\d+)", lambda r, m: J(fx(f"arr/{pre}_command.json")[0])),
        ("POST", r"/api/v3/command", command_post),
        ("GET", r"/api/v3/system/task", lambda r, m: F(f"arr/{pre}_system_task.json")),
        ("GET", r"/api/v3/update", lambda r, m: F(f"arr/{pre}_update.json")),
    )


def sonarr_routes(D: Data, poster_mode: str):
    def series_one(r, m):
        s = D.series_by_id.get(int(m.group(1)))
        return J(s) if s else F("arr/sonarr_error_404.json", 404)

    def episodes(r, m):
        sid = r.qi("seriesId", 1)
        eps = copy.deepcopy(fx("arr/sonarr_episode.json"))
        for e in eps:
            e["seriesId"] = sid
        return J(eps)

    def episodefile(r, m):
        sid = r.qi("seriesId", 1)
        files = copy.deepcopy(fx("arr/sonarr_episodefile.json"))
        for f in files:
            f["seriesId"] = sid
        return J(files)

    return routes(
        ("GET", r"/api/v3/series", lambda r, m: J(D.series)),
        ("GET", r"/api/v3/series/lookup", lambda r, m: F("arr/sonarr_series_lookup.json")),
        ("GET", r"/api/v3/series/(\d+)", series_one),
        ("GET", r"/api/v3/episode", episodes),
        ("GET", r"/api/v3/episode/(\d+)", lambda r, m: F("arr/sonarr_episode_id.json")),
        ("GET", r"/api/v3/episodefile", episodefile),
        ("GET", r"/api/v3/parse", lambda r, m: F("arr/sonarr_parse.json")),
    ) + arr_common("sonarr", D, poster_mode)


def radarr_routes(D: Data, poster_mode: str):
    def movie_one(r, m):
        mv = D.movie_by_id.get(int(m.group(1)))
        return J(mv) if mv else F("arr/radarr_error_404.json", 404)

    def movie_list(r, m):
        tmdb = r.q("tmdbId")
        if tmdb:
            return J([mv for mv in D.movies if str(mv.get("tmdbId")) == tmdb])
        return J(D.movies)

    return routes(
        ("GET", r"/api/v3/movie", movie_list),
        ("GET", r"/api/v3/movie/lookup", lambda r, m: F("arr/radarr_movie_lookup.json")),
        ("GET", r"/api/v3/movie/lookup/tmdb", lambda r, m: F("arr/radarr_movie_lookup_tmdb.json")),
        ("GET", r"/api/v3/movie/(\d+)/folder", lambda r, m: F("arr/radarr_movie_folder.json")),
        ("GET", r"/api/v3/movie/(\d+)", movie_one),
        ("GET", r"/api/v3/moviefile", lambda r, m: F("arr/radarr_moviefile.json")),
    ) + arr_common("radarr", D, poster_mode)


def prowlarr_routes(D: Data):
    def history(r, m):
        body = fx("downloads/prowlarr_history.json")
        return J(paged(body["records"], r))

    return routes(
        ("GET", r"/ping", lambda r, m: J({"status": "OK"})),
        ("GET", r"/api/v1/system/status", lambda r, m: F("downloads/prowlarr_system_status.json")),
        ("GET", r"/api/v1/health", lambda r, m: F("downloads/prowlarr_health.json")),
        ("GET", r"/api/v1/indexerstatus", lambda r, m: F("downloads/prowlarr_indexerstatus.json")),
        ("GET", r"/api/v1/indexerstats", lambda r, m: F("downloads/prowlarr_indexerstats.json")),
        ("GET", r"/api/v1/indexer", lambda r, m: F("downloads/prowlarr_indexer.json")),
        ("GET", r"/api/v1/indexer/categories", lambda r, m: F("downloads/prowlarr_indexer_categories.json")),
        ("GET", r"/api/v1/indexer/(\d+)", lambda r, m: J(fx("downloads/prowlarr_indexer.json")[0])),
        ("GET", r"/api/v1/tag", lambda r, m: F("downloads/prowlarr_tag.json")),
        ("GET", r"/api/v1/tag/detail", lambda r, m: F("downloads/prowlarr_tag_detail.json")),
        ("GET", r"/api/v1/applications", lambda r, m: F("downloads/prowlarr_applications.json")),
        ("GET", r"/api/v1/appprofile", lambda r, m: F("downloads/prowlarr_appprofile.json")),
        ("GET", r"/api/v1/indexerproxy", lambda r, m: F("downloads/prowlarr_indexerproxy.json")),
        ("GET", r"/api/v1/downloadclient", lambda r, m: F("downloads/prowlarr_downloadclient.json")),
        ("GET", r"/api/v1/system/task", lambda r, m: F("downloads/prowlarr_system_task.json")),
        ("GET", r"/api/v1/update", lambda r, m: F("downloads/prowlarr_update.json")),
        ("GET", r"/api/v1/command", lambda r, m: F("downloads/prowlarr_command.json")),
        ("GET", r"/api/v1/log", lambda r, m: F("downloads/prowlarr_log.json")),
        ("GET", r"/api/v1/history/since", lambda r, m: F("downloads/prowlarr_history_since_mixed.json")),
        ("GET", r"/api/v1/history", history),
        ("GET", r"/api/v1/search", lambda r, m: J([])),
    )


def bazarr_routes(D: Data):
    d = "downloads/bazarr_"
    return routes(
        ("GET", r"/api/system/ping", lambda r, m: J({"status": "OK"})),
        ("GET", r"/api/system/status", lambda r, m: F(d + "system_status.json")),
        ("GET", r"/api/system/health", lambda r, m: F(d + "system_health.json")),
        ("GET", r"/api/system/tasks", lambda r, m: F(d + "system_tasks.json")),
        ("GET", r"/api/system/jobs", lambda r, m: F(d + "system_jobs.json")),
        ("GET", r"/api/system/announcements", lambda r, m: F(d + "system_announcements.json")),
        ("GET", r"/api/system/releases", lambda r, m: F(d + "system_releases.json")),
        ("GET", r"/api/system/languages/profiles", lambda r, m: F(d + "system_languages_profiles.json")),
        ("GET", r"/api/badges", lambda r, m: F(d + "badges.json")),
        ("GET", r"/api/providers", lambda r, m: F(d + "providers.json")),
        ("GET", r"/api/episodes/wanted", lambda r, m: F(d + "episodes_wanted.json")),
        ("GET", r"/api/movies/wanted", lambda r, m: F(d + "movies_wanted.json")),
        ("GET", r"/api/episodes/history", lambda r, m: F(d + "episodes_history.json")),
        ("GET", r"/api/movies/history", lambda r, m: F(d + "movies_history.json")),
        ("GET", r"/api/episodes/blacklist", lambda r, m: F(d + "episodes_blacklist.json")),
        ("GET", r"/api/history/stats", lambda r, m: F(d + "history_stats.json")),
        ("GET", r"/api/series", lambda r, m: F(d + "series.json")),
        ("GET", r"/api/movies", lambda r, m: F(d + "movies.json")),
    )


def seerr_routes(D: Data):
    s = "seerr/seerr_"

    def disc(rel, salt):
        return lambda r, m: J(D.seerr_page(rel, max(1, r.qi("page", 1)), salt))

    def requests_list(r, m):
        base = fx(s + "request_list.json")
        take = max(1, r.qi("take", 20))
        skip = max(0, r.qi("skip", 0))
        res = base["results"]
        total = max(len(res), 60)
        out = []
        for i in range(skip, min(skip + take, total)):
            x = copy.deepcopy(res[i % len(res)])
            if i >= len(res):
                x["id"] = 10_000 + i
                if x.get("media"):
                    x["media"]["id"] = 20_000 + i
                    x["media"]["tmdbId"] = 7_000_000 + i
            out.append(x)
        return J({
            "pageInfo": {"pages": (total + take - 1) // take, "pageSize": take,
                         "results": total, "page": skip // take + 1},
            "results": out,
            "serviceErrors": base.get("serviceErrors", {"radarr": [], "sonarr": []}),
        })

    def details(kind):
        rel = s + ("movie_details_available.json" if kind == "movie" else "tv_details_partially_available.json")

        def h(r, m):
            tid = int(m.group(1))
            body = fx(rel)
            if body.get("id") != tid:
                body["id"] = tid
                body["posterPath"] = D.poster_for(tid)
                body["backdropPath"] = D.backdrop_for(tid)
                for key in ("title", "name"):
                    if key in body:
                        body[key] = f"{body[key]} ({tid})"
            return J(body)
        return h

    def sub_page(rel):
        return lambda r, m: J(D.seerr_page(rel, max(1, r.qi("page", 1)), int(m.group(1)) % 97))

    return routes(
        ("GET", r"/api/v1/status", lambda r, m: F(s + "status.json")),
        ("GET", r"/avatarproxy/([^/]+)", lambda r, m: JPEG(f"avatar {m.group(1)}", 256, 256)),
        ("GET", r"/api/v1/settings/public", lambda r, m: F(s + "settings_public.json")),
        ("GET", r"/api/v1/auth/me", lambda r, m: F(s + "auth_me.json")),
        ("GET", r"/api/v1/user", lambda r, m: F(s + "user_list.json")),
        ("GET", r"/api/v1/user/jellyfin/([^/]+)", lambda r, m: F(s + "user_by_jellyfin_id.json")),
        ("GET", r"/api/v1/user/(\d+)/quota", lambda r, m: F(s + "user_quota.json")),
        ("GET", r"/api/v1/user/(\d+)/requests", lambda r, m: F(s + "user_requests.json")),
        ("GET", r"/api/v1/user/(\d+)/watchlist", lambda r, m: F(s + "discover_watchlist.json")),
        ("GET", r"/api/v1/user/(\d+)", lambda r, m: F(s + "user_detail.json")),
        ("GET", r"/api/v1/search", disc("seerr/seerr_search_multi.json", 7)),
        ("GET", r"/api/v1/discover/trending", disc("seerr/seerr_discover_trending.json", 1)),
        ("GET", r"/api/v1/discover/movies/upcoming", disc("seerr/seerr_discover_movies_upcoming.json", 2)),
        ("GET", r"/api/v1/discover/movies", disc("seerr/seerr_discover_movies.json", 3)),
        ("GET", r"/api/v1/discover/tv/upcoming", disc("seerr/seerr_discover_tv_upcoming.json", 4)),
        ("GET", r"/api/v1/discover/tv", disc("seerr/seerr_discover_tv.json", 5)),
        ("GET", r"/api/v1/discover/watchlist", lambda r, m: F(s + "discover_watchlist.json")),
        ("GET", r"/api/v1/genres/(movie|tv)", lambda r, m: F(s + "genres_movie.json")),
        ("GET", r"/api/v1/movie/(\d+)/ratingscombined", lambda r, m: F(s + "movie_ratingscombined.json")),
        ("GET", r"/api/v1/movie/(\d+)/recommendations", sub_page("seerr/seerr_movie_recommendations.json")),
        ("GET", r"/api/v1/movie/(\d+)/similar", sub_page("seerr/seerr_movie_similar.json")),
        ("GET", r"/api/v1/tv/(\d+)/recommendations", sub_page("seerr/seerr_movie_recommendations.json")),
        ("GET", r"/api/v1/tv/(\d+)/similar", sub_page("seerr/seerr_movie_similar.json")),
        ("GET", r"/api/v1/tv/(\d+)/ratings", lambda r, m: F(s + "tv_ratings.json")),
        ("GET", r"/api/v1/tv/(\d+)/season/(\d+)", lambda r, m: F(s + "tv_season.json")),
        ("GET", r"/api/v1/movie/(\d+)", details("movie")),
        ("GET", r"/api/v1/tv/(\d+)", details("tv")),
        ("GET", r"/api/v1/request/count", lambda r, m: F(s + "request_count.json")),
        ("GET", r"/api/v1/request/(\d+)", lambda r, m: F(s + "request_detail_approved.json")),
        ("GET", r"/api/v1/request", requests_list),
        ("GET", r"/api/v1/issue/count", lambda r, m: F(s + "issue_count.json")),
        ("GET", r"/api/v1/issue", lambda r, m: F(s + "issue_list_empty.json")),
        ("GET", r"/api/v1/media", lambda r, m: F(s + "media_list.json")),
        ("GET", r"/api/v1/service/radarr", lambda r, m: F(s + "service_radarr.json")),
        ("GET", r"/api/v1/service/radarr/(\d+)", lambda r, m: F(s + "service_radarr_detail.json")),
        ("GET", r"/api/v1/service/sonarr", lambda r, m: F(s + "service_sonarr.json")),
        ("GET", r"/api/v1/service/sonarr/(\d+)", lambda r, m: F(s + "service_sonarr_detail.json")),
    )


def jellyfin_routes(D: Data):
    s = "seerr/jellyfin_"

    def latest(r, m):
        items = fx(s + "items_latest_movies.json")
        parent = r.q("parentId") or ""
        if parent:
            # second library (shows) -> grouped shows fixture
            libs = fx(s + "library_virtualfolders.json")
            for lib in libs:
                if lib.get("ItemId") == parent and lib.get("CollectionType") == "tvshows":
                    items = fx(s + "items_latest_shows_grouped.json")
        return J(items)

    def items(r, m):
        if (r.q("includeItemTypes") or "").lower() == "movie" and r.q("startIndex"):
            return F(s + "items_movies_page.json")
        return F(s + "items_recently_added.json")

    def image(r, m):
        # Jellyfin resizes to the requested box (fillHeight / maxWidth ...).
        kind = m.group(2)
        if kind in ("Backdrop", "Thumb"):
            w = r.qi("maxWidth", 0) or r.qi("fillWidth", 0) or 1280
            h = w * 9 // 16
        else:
            h = r.qi("fillHeight", 0) or r.qi("maxHeight", 0) or 600
            w = h * 2 // 3
        return JPEG(f"jellyfin {m.group(1)} {kind}", max(16, w), max(16, h))

    return routes(
        ("GET", r"/System/Info/Public", lambda r, m: F(s + "system_info_public.json")),
        ("GET", r"/System/Info", lambda r, m: F(s + "system_info.json")),
        ("GET", r"/System/Configuration/encoding", lambda r, m: F(s + "encoding_config.json")),
        ("GET", r"/System/ActivityLog/Entries", lambda r, m: F(s + "activity_log.json")),
        ("GET", r"/Sessions", lambda r, m: F(s + "sessions.json")),
        ("GET", r"/Users", lambda r, m: F(s + "users.json")),
        ("GET", r"/Users/([^/]+)/Views", lambda r, m: F(s + "user_views.json")),
        ("GET", r"/UserViews", lambda r, m: F(s + "user_views.json")),
        ("GET", r"/Users/([^/]+)/Images/Primary", lambda r, m: JPEG(f"jfuser {m.group(1)}", 256, 256)),
        ("GET", r"/Items/Counts", lambda r, m: F(s + "items_counts.json")),
        ("GET", r"/Items/Latest", latest),
        ("GET", r"/Users/([^/]+)/Items/Latest", latest),
        ("GET", r"/Items/([^/]+)/Images/([A-Za-z]+)(?:/\d+)?", image),
        ("GET", r"/Items/([0-9a-f]{32})", lambda r, m: F(s + "item_movie.json")),
        ("GET", r"/Items", items),
        ("GET", r"/UserItems/Resume", lambda r, m: F(s + "items_resume.json")),
        ("GET", r"/Shows/NextUp", lambda r, m: J({"Items": [], "TotalRecordCount": 0, "StartIndex": 0})),
        ("GET", r"/Library/VirtualFolders", lambda r, m: F(s + "library_virtualfolders.json")),
        ("GET", r"/Search/Hints", lambda r, m: F(s + "search_hints.json")),
    )


def jellystat_routes(D: Data):
    s = "seerr/jellystat_"
    stats = {
        "getLibraryOverview", "getPlaybackActivity", "getAllUserActivity", "getLibraryCardStats",
        "getLibraryMetadata", "getViewsOverTime", "getViewsByDays", "getViewsByHour",
        "getViewsByLibraryType", "getMostViewedLibraries", "getMostUsedClient", "getMostActiveUsers",
        "getPlaybackMethodStats", "getGlobalUserStats", "getUserLastPlayed", "getGlobalLibraryStats",
        "getLibraryLastPlayed",
    }

    def stat(r, m):
        name = m.group(1)
        if name == "getMostViewedByType":
            t = (r.q("type") or "").lower()
            return F(s + ("getMostViewedByType_series.json" if t == "series" else "getMostViewedByType_movie_empty.json"))
        if name == "getMostPopularByType":
            return F(s + "getMostPopularByType_series.json")
        if name in stats:
            return F(s + f"{name}.json")
        return J([])

    def api(r, m):
        name = m.group(1)
        p = FIX / f"{s}api_{name}.json"
        if p.exists():
            return Resp(200, p.read_bytes(), "application/json")
        if name == "getUserHistory":
            return F(s + "api_getHistory.json")
        return J([])

    return routes(
        ("GET", r"/auth/isConfigured", lambda r, m: F(s + "auth_isConfigured.json")),
        ("GET|POST", r"/stats/([A-Za-z]+)", stat),
        ("GET|POST", r"/api/([A-Za-z]+)", api),
    )


class Qbit:
    def __init__(self):
        self.text = fx("downloads/qbittorrent_text_responses.json")

    def routes(self, D: Data):
        d = "downloads/qbittorrent_"
        text = self.text

        def login(r, m):
            return Resp(200, b"Ok.", "text/plain",
                        {"set-cookie": "QBT_SID_8081=mocksessionid0123456789abcdef; HttpOnly; path=/"})

        def maindata(r, m):
            if r.qi("rid", 0) == 0:
                return F(d + "sync_maindata_full.json")
            body = fx(d + "sync_maindata_delta.json")
            body["rid"] = r.qi("rid", 0) + 1
            return J(body)

        def plain(key, default=""):
            return lambda r, m: T(str(text.get(key, default)))

        return routes(
            ("POST", r"/api/v2/auth/login", login),
            ("GET", r"/api/v2/app/version", plain("GET /api/v2/app/version", "v5.0.0")),
            ("GET", r"/api/v2/app/webapiVersion", plain("GET /api/v2/app/webapiVersion", "2.11")),
            ("GET", r"/api/v2/app/buildInfo", lambda r, m: F(d + "app_buildInfo.json")),
            ("GET", r"/api/v2/app/preferences", lambda r, m: F(d + "app_preferences.json")),
            ("GET", r"/api/v2/transfer/info", lambda r, m: F(d + "transfer_info.json")),
            ("GET", r"/api/v2/transfer/getSpeedLimits", lambda r, m: F(d + "transfer_getSpeedLimits.json")),
            ("GET", r"/api/v2/transfer/speedLimitsMode", plain("GET /api/v2/transfer/speedLimitsMode", "0")),
            ("GET", r"/api/v2/sync/maindata", maindata),
            ("GET", r"/api/v2/sync/torrentPeers", lambda r, m: F(d + "sync_torrentPeers.json")),
            ("GET", r"/api/v2/torrents/info", lambda r, m: F(d + "torrents_info.json")),
            ("GET", r"/api/v2/torrents/categories", lambda r, m: F(d + "torrents_categories.json")),
            ("GET", r"/api/v2/torrents/tags", lambda r, m: F(d + "torrents_tags.json")),
            ("GET", r"/api/v2/torrents/properties", lambda r, m: F(d + "torrents_properties.json")),
            ("GET", r"/api/v2/torrents/files", lambda r, m: F(d + "torrents_files.json")),
            ("GET", r"/api/v2/torrents/trackers", lambda r, m: F(d + "torrents_trackers.json")),
            ("GET", r"/api/v2/log/main", lambda r, m: F(d + "log_main.json")),
        )


def gluetun_routes(D: Data):
    return routes(
        ("GET", r"/v1/publicip/ip", lambda r, m: F("downloads/gluetun_publicip_ip.json")),
        ("GET", r"/v1/openvpn/portforwarded", lambda r, m: F("downloads/gluetun_openvpn_portforwarded.json")),
        ("GET", r"/v1/portforward", lambda r, m: F("downloads/gluetun_openvpn_portforwarded.json")),
        ("GET", r"/v1/openvpn/status", lambda r, m: J({"status": "running"})),
        ("GET", r"/v1/vpn/status", lambda r, m: J({"status": "running"})),
    )


def docker_routes(D: Data):
    s = "system/docker_"
    containers = fx(s + "containers_json.json")
    by_name = {}
    for c in containers:
        for n in c.get("Names", []):
            by_name[n.lstrip("/")] = c
        by_name[c["Id"]] = c
        by_name[c["Id"][:12]] = c

    def inspect(r, m):
        ref = m.group(1)
        body = fx(s + "container_inspect.json")
        c = by_name.get(ref)
        if c is None and ref not in ("yams-hub",):
            return J({"message": f"No such container: {ref}"}, 404)
        if c is not None:
            body["Id"] = c["Id"]
            body["Name"] = c["Names"][0]
            body.setdefault("Config", {})["Image"] = c.get("Image", body.get("Config", {}).get("Image"))
            body.setdefault("Config", {})["Labels"] = c.get("Labels", {})
        return J(body)

    def stats(r, m):
        body = fx(s + "container_stats_oneshot.json")
        c = by_name.get(m.group(1))
        if c:
            body["id"] = c["Id"]
            body["name"] = c["Names"][0]
        return J(body)

    def logs(r, m):
        name = m.group(1)
        rel = s + ("container_logs_recyclarr.json" if "recyclarr" in name else "container_logs_decluttarr.json")
        raw = base64.b64decode(fx(rel)["body_base64"])
        return Resp(200, raw, "application/vnd.docker.multiplexed-stream")

    def events(r, m):
        return Resp(200, b"", "application/json", stream=True)

    pre = r"(?:/v[0-9.]+)?"
    return routes(
        ("GET|HEAD", pre + r"/_ping", lambda r, m: T("OK")),
        ("GET", pre + r"/version", lambda r, m: F(s + "version.json")),
        ("GET", pre + r"/info", lambda r, m: F(s + "info.json")),
        ("GET", pre + r"/containers/json", lambda r, m: J(containers)),
        ("GET", pre + r"/containers/([^/]+)/json", inspect),
        ("GET", pre + r"/containers/([^/]+)/stats", stats),
        ("GET", pre + r"/containers/([^/]+)/logs", logs),
        ("GET", pre + r"/events", events),
        ("POST", pre + r"/containers/create", lambda r, m: J({"message": "forbidden"}, 403)),
        ("POST", pre + r"/images/create", lambda r, m: J({"message": "forbidden"}, 403)),
        ("DELETE", pre + r"/containers/([^/]+)", lambda r, m: J({"message": "forbidden"}, 403)),
    )


def watchtower_routes(D: Data):
    metrics = (FIX / "system/watchtower_v1_metrics.txt").read_text()
    return routes(
        ("GET", r"/v1/metrics", lambda r, m: T(metrics)),
        ("GET", r"/healthz", lambda r, m: T("OK")),
        ("GET", r"/v1/status", lambda r, m: J({})),
        ("GET", r"/v1/containers/details", lambda r, m: J([])),
        ("GET", r"/v1/check", lambda r, m: J([])),
    )


def uptimekuma_routes(D: Data):
    return routes(
        ("GET", r"/api/status-page/heartbeat/([^/]+)", lambda r, m: F("system/uptimekuma_status_page_heartbeat.json")),
        ("GET", r"/api/status-page/([^/]+)", lambda r, m: F("system/uptimekuma_status_page.json")),
    )


def abs_routes(D: Data):
    s = "system/audiobookshelf_"

    def items(r, m):
        return F(s + "library_items_recent.json")

    def cover(r, m):
        return JPEG(f"abs {m.group(1)}", 400, 400)

    return routes(
        ("GET", r"/status", lambda r, m: F(s + "status.json")),
        ("GET", r"/healthcheck", lambda r, m: T("OK")),
        ("GET", r"/ping", lambda r, m: J({"success": True})),
        ("GET", r"/api/libraries", lambda r, m: F(s + "libraries.json")),
        ("GET", r"/api/libraries/([^/]+)/items", items),
        ("GET", r"/api/libraries/([^/]+)/stats", lambda r, m: F(s + "library_stats.json")),
        ("GET", r"/api/libraries/([^/]+)/personalized", lambda r, m: F(s + "library_personalized.json")),
        ("GET", r"/api/me", lambda r, m: F(s + "me.json")),
        ("GET", r"/api/me/items-in-progress", lambda r, m: F(s + "me_items_in_progress.json")),
        ("GET", r"/api/me/listening-stats", lambda r, m: F(s + "me_listening_stats.json")),
        ("GET", r"/api/me/listening-sessions", lambda r, m: F(s + "me_listening_sessions.json")),
        ("GET", r"/api/items/([^/]+)/cover", cover),
    )


def shelfmark_routes(D: Data):
    return routes(
        ("GET", r"/api/health", lambda r, m: F("system/shelfmark_health.json")),
        ("GET", r"/api/stats", lambda r, m: F("system/shelfmark_stats.json")),
    )


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------


class Counter:
    def __init__(self):
        self.lock = threading.Lock()
        self.counts: dict[str, int] = {}

    def add(self, key):
        with self.lock:
            self.counts[key] = self.counts.get(key, 0) + 1


def make_handler(service: str, table, latency_ms: int, counter: Counter, unmatched_log):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = f"mock-{service}"

        def log_message(self, fmt, *args):  # quiet
            pass

        def _handle(self):
            u = urlsplit(self.path)
            n = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(n) if n else b""
            req = Req(self.command, u.path, parse_qs(u.query, keep_blank_values=True), body, self.headers)
            resp = None
            for (meth, rx, fn) in table:
                if self.command not in meth.split("|"):
                    continue
                m = rx.match(u.path)
                if m:
                    try:
                        resp = fn(req, m)
                    except Exception as e:  # noqa: BLE001
                        print(f"ERROR {service} {self.command} {self.path}: {e!r}", file=sys.stderr)
                        resp = J({"message": str(e)}, 500)
                    break
            kind = "img" if resp is not None and resp.ctype.startswith("image/") else "api"
            if resp is None:
                line = f"UNMATCHED {service} {self.command} {self.path}"
                print(line, file=sys.stderr, flush=True)
                if unmatched_log:
                    with open(unmatched_log, "a") as f:
                        f.write(line + "\n")
                if self.command == "GET":
                    resp = J([])
                else:
                    resp = J({}, 200)
                kind = "unmatched"
            counter.add(f"{service} {kind}")
            if latency_ms and kind != "img":
                time.sleep(latency_ms / 1000)
            if resp.stream:
                self.send_response(resp.status)
                self.send_header("content-type", resp.ctype)
                self.send_header("transfer-encoding", "chunked")
                self.end_headers()
                try:
                    while True:  # keep the event stream open, send nothing
                        time.sleep(30)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            self.send_response(resp.status)
            self.send_header("content-type", resp.ctype)
            self.send_header("content-length", str(len(resp.body)))
            for k, v in resp.headers.items():
                self.send_header(k, v)
            self.end_headers()
            if self.command != "HEAD":
                try:
                    self.wfile.write(resp.body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = _handle

    return H


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-port", type=int, default=18100)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--poster-mode", choices=["full", "arr"], default="full")
    ap.add_argument("--latency-ms", type=int, default=0, help="extra delay on API (non-image) answers")
    ap.add_argument("--env-out", help="write the gateway secrets/URL lines here")
    ap.add_argument("--unmatched-log", help="append unmatched requests here")
    ap.add_argument("--stats-out", help="write per-service request counts here on SIGTERM/exit")
    ap.add_argument("--pregen", action="store_true", help="pre-generate all library posters at start-up")
    args = ap.parse_args()

    D = Data(args.scale)
    qbit = Qbit()
    tables = {
        "sonarr": sonarr_routes(D, args.poster_mode),
        "radarr": radarr_routes(D, args.poster_mode),
        "prowlarr": prowlarr_routes(D),
        "bazarr": bazarr_routes(D),
        "seerr": seerr_routes(D),
        "jellyfin": jellyfin_routes(D),
        "jellystat": jellystat_routes(D),
        "qbittorrent": qbit.routes(D),
        "gluetun": gluetun_routes(D),
        "docker": docker_routes(D),
        "watchtower": watchtower_routes(D),
        "uptimekuma": uptimekuma_routes(D),
        "audiobookshelf": abs_routes(D),
        "shelfmark": shelfmark_routes(D),
    }
    counter = Counter()
    env_lines = []
    servers = []
    for i, (name, url_var, secrets) in enumerate(SERVICES):
        port = args.base_port + i
        httpd = ThreadingHTTPServer((args.host, port), make_handler(name, tables[name], args.latency_ms, counter, args.unmatched_log))
        httpd.daemon_threads = True
        t = threading.Thread(target=httpd.serve_forever, name=name, daemon=True)
        t.start()
        servers.append(httpd)
        env_lines.append(f"{url_var}='http://{args.host}:{port}'")
        for k, v in secrets.items():
            env_lines.append(f"{k}='{v}'")
    env_lines.append("KAVITA_URL=''")
    env_lines.append("UPDATER_URL=''")
    if args.env_out:
        Path(args.env_out).write_text("\n".join(env_lines) + "\n")

    if args.pregen:
        t0 = time.time()
        for mv in D.movies:
            ARR = ARR_VARIANTS
            w, h = (1000, 1500) if args.poster_mode == "full" else ARR["poster-500"]
            make_jpeg(f"radarr {mv['id']} poster", w, h)
        for s in D.series:
            w, h = (1000, 1500) if args.poster_mode == "full" else ARR_VARIANTS["poster-500"]
            make_jpeg(f"sonarr {s['id']} poster", w, h)
        print(f"pre-generated {len(D.movies) + len(D.series)} posters in {time.time() - t0:.1f}s", file=sys.stderr)

    sample = make_jpeg("radarr 1 poster", 1000, 1500)
    print(
        f"mock upstreams up on {args.host}:{args.base_port}..{args.base_port + len(SERVICES) - 1} "
        f"({len(D.movies)} movies, {len(D.series)} series, {len(D.poster_pool)} TMDB poster paths, "
        f"sample poster {len(sample) // 1024} KB, poster-mode {args.poster_mode})",
        file=sys.stderr, flush=True,
    )

    import signal

    def stop(*_):
        if args.stats_out:
            Path(args.stats_out).write_text(json.dumps(counter.counts, indent=2, sort_keys=True))
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
