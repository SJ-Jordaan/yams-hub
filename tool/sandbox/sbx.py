"""Shared helpers for the sandbox scripts (seed.py, smoke.py, screens.py). Python 3 stdlib only.

Paths and throwaway credentials come from the environment run.sh exports:
  SANDBOX_DIR    the sandbox root (yams/ = INSTALL_DIRECTORY, media/ = MEDIA_DIRECTORY, state/, artifacts/)
  SANDBOX_SECRETS  KEY=value file with the generated passwords (0600)
"""

from __future__ import annotations

import http.cookiejar
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SANDBOX_DIR = Path(os.environ.get("SANDBOX_DIR", "")).expanduser()
YAMS_DIR = SANDBOX_DIR / "yams"
MEDIA_DIR = SANDBOX_DIR / "media"
STATE_DIR = SANDBOX_DIR / "state"
ARTIFACTS = Path(os.environ.get("SANDBOX_ARTIFACTS", str(SANDBOX_DIR / "artifacts")))

# Host ports from compose.yaml (127.0.0.1 only).
PORTS = {
    "jellyfin": 28096,
    "qbittorrent": 28081,
    "sonarr": 28989,
    "radarr": 27878,
    "prowlarr": 29696,
    "bazarr": 26767,
    "seerr": 25055,
}
HUB_PORT = int(os.environ.get("SANDBOX_HUB_PORT", "28090"))


def base(service: str) -> str:
    return f"http://127.0.0.1:{PORTS[service]}"


def log(msg: str) -> None:
    print(msg, flush=True)


def warn(msg: str) -> None:
    print(f"WARNING: {msg}", file=sys.stderr, flush=True)


class Fatal(Exception):
    """A seeding/test step that cannot continue; the message says what to do."""


def secrets() -> dict[str, str]:
    path = Path(os.environ.get("SANDBOX_SECRETS", str(SANDBOX_DIR / "secrets.env")))
    out: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def state_get(name: str) -> str | None:
    p = STATE_DIR / name
    return p.read_text().strip() if p.exists() else None


def state_put(name: str, value: str) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    p = STATE_DIR / name
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(value + "\n")


def arr_key(service: str) -> str:
    text = (YAMS_DIR / "config" / service / "config.xml").read_text()
    m = re.search(r"<ApiKey>([A-Za-z0-9]+)</ApiKey>", text)
    if not m:
        raise Fatal(f"no ApiKey in {service}'s config.xml yet")
    return m.group(1)


class Response:
    def __init__(self, status: int, body: bytes, headers):
        self.status = status
        self.body = body
        self.headers = headers

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def text(self) -> str:
        return self.body.decode("utf-8", "replace")

    def json(self):
        if not self.body:
            return None
        try:
            return json.loads(self.body)
        except ValueError:
            return None


class Client:
    """A tiny HTTP client: JSON in/out, optional cookie jar, default headers, never raises on HTTP errors."""

    def __init__(self, base_url: str, headers: dict[str, str] | None = None, cookies: bool = False):
        self.base_url = base_url.rstrip("/")
        self.headers = dict(headers or {})
        self.jar = http.cookiejar.CookieJar() if cookies else None
        handlers = [urllib.request.HTTPCookieProcessor(self.jar)] if self.jar is not None else []
        self.opener = urllib.request.build_opener(*handlers)

    def request(self, method: str, path: str, body=None, *, form: dict | None = None, query: dict | None = None,
                headers: dict[str, str] | None = None, timeout: float = 30) -> Response:
        url = self.base_url + path
        if query:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
        h = dict(self.headers)
        h.update(headers or {})
        data = None
        if form is not None:
            data = urllib.parse.urlencode(form).encode()
            h.setdefault("Content-Type", "application/x-www-form-urlencoded")
        elif body is not None:
            data = json.dumps(body).encode()
            h.setdefault("Content-Type", "application/json")
        req = urllib.request.Request(url, data=data, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=timeout) as r:
                return Response(r.status, r.read(), r.headers)
        except urllib.error.HTTPError as e:
            return Response(e.code, e.read() or b"", e.headers)
        except (urllib.error.URLError, OSError) as e:
            return Response(0, str(e).encode(), {})

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.request("POST", path, body, **kw)

    def put(self, path, body=None, **kw):
        return self.request("PUT", path, body, **kw)

    def delete(self, path, **kw):
        return self.request("DELETE", path, **kw)


def wait_until(what: str, check, timeout: float = 180, interval: float = 2):
    """Calls check() until it returns a truthy value; raises Fatal after timeout seconds."""
    deadline = time.monotonic() + timeout
    last = None
    while True:
        try:
            v = check()
            if v:
                return v
        except Exception as e:  # noqa: BLE001 - keep polling, report the last error
            last = e
        if time.monotonic() > deadline:
            raise Fatal(f"timed out after {int(timeout)} s waiting for {what}" + (f" (last error: {last})" if last else ""))
        time.sleep(interval)


def docker(*args: str, check: bool = True) -> str:
    r = subprocess.run(["docker", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise Fatal(f"docker {' '.join(args)} failed: {r.stderr.strip()}")
    return r.stdout + r.stderr
