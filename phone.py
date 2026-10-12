"""Phone remote: the Couch remote as a web page for phones on the same Wi-Fi.

Off until the user turns it on in the Mac app. Then a second server listens on the LAN
port and serves the page. Every WebSocket must carry the pairing token, which only the
QR code in the Mac app shows; the page keeps it after the first scan. Host and Origin
are checked like on the local server, so a website cannot reach it through the phone's
browser by DNS rebinding. Plain HTTP on the home network: the token travels unencrypted
on the Wi-Fi, which is the same trust the TV protocol itself gets there.
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import secrets
import socket
import time
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from aiohttp import web

from tv import CONFIG_DIR, ensure_config_dir

PHONE_PORT = 8766
PAGE_DIR = Path(__file__).parent / "phone"
SETTINGS_FILE = CONFIG_DIR / "phone.json"
TOKEN_BYTES = 24
# The LAN address is looked up again after this long, in case the Mac moved networks.
ADDRESS_CACHE_SECONDS = 30

log = logging.getLogger("tvremote.phone")

SocketRunner = Callable[[web.Request], Awaitable[web.WebSocketResponse]]


def lan_address() -> str | None:
    """The Mac's address on the local network (the interface that would reach the internet)."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))  # TEST-NET address: picks a route, sends nothing
        return probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()


class PhoneAccess:
    """Turns the phone server on and off and owns its pairing token."""

    def __init__(self, run_socket: SocketRunner) -> None:
        self._run_socket = run_socket
        self._runner: web.AppRunner | None = None
        self._address: str | None = None
        self._address_checked = 0.0
        settings = self._load()
        self.enabled = bool(settings.get("enabled"))
        self.token = settings.get("token") if isinstance(settings.get("token"), str) else None

    # ------------------------------------------------------------ settings

    @staticmethod
    def _load() -> dict[str, Any]:
        try:
            data = json.loads(SETTINGS_FILE.read_text())
        except (OSError, json.JSONDecodeError):
            return {}
        return data if isinstance(data, dict) else {}

    def _save(self) -> None:
        ensure_config_dir()
        fd = os.open(SETTINGS_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as out:
            json.dump({"enabled": self.enabled, "token": self.token}, out)

    # ------------------------------------------------------------ control

    async def set_enabled(self, enabled: bool) -> None:
        if enabled and not self.token:
            self.token = secrets.token_urlsafe(TOKEN_BYTES)
        self.enabled = enabled
        self._save()
        if enabled:
            await self.start()
        else:
            await self.stop()

    async def reset_token(self) -> None:
        """Forget every paired phone: a new token, and open phone pages drop off."""
        self.token = secrets.token_urlsafe(TOKEN_BYTES)
        self._save()
        if self._runner:
            await self.stop()
            await self.start()

    def info(self) -> dict[str, Any]:
        """For the Mac app only: never sent to phones, since it holds the token."""
        address = self._current_address()
        # The token stays in the address (not just in browser storage): iPhone Home Screen apps and
        # the camera's link viewer keep their own storage, so the address is what survives.
        url = f"http://{address}:{PHONE_PORT}/?t={self.token}" if self.enabled and address and self.token else None
        return {"type": "phone", "enabled": self.enabled, "running": self._runner is not None, "url": url}

    async def start(self) -> None:
        if self._runner or not self.enabled:
            return
        app = web.Application(middlewares=[self._guard])
        app.router.add_get("/", self._page("index.html", "text/html"))
        app.router.add_get("/app.js", self._page("app.js", "text/javascript"))
        app.router.add_get("/style.css", self._page("style.css", "text/css"))
        app.router.add_get("/manifest.webmanifest", self._manifest)
        app.router.add_get("/icon.png", self._page("icon.png", "image/png"))
        app.router.add_get("/ws", self._socket)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        try:
            # All interfaces, so a changed Wi-Fi address keeps working; the Host check and token gate it.
            await web.TCPSite(runner, "0.0.0.0", PHONE_PORT).start()
        except OSError as exc:
            log.warning("phone remote could not listen on port %s: %s", PHONE_PORT, exc)
            await runner.cleanup()
            return
        self._runner = runner
        log.info("phone remote on port %s", PHONE_PORT)

    async def stop(self) -> None:
        if self._runner:
            await self._runner.cleanup()
            self._runner = None

    # ------------------------------------------------------------ requests

    def _current_address(self) -> str | None:
        if time.monotonic() - self._address_checked > ADDRESS_CACHE_SECONDS:
            self._address = lan_address()
            self._address_checked = time.monotonic()
        return self._address

    def _allowed_hosts(self) -> set[str]:
        hosts = {f"{socket.gethostname()}:{PHONE_PORT}"}
        local = socket.gethostname()
        if not local.endswith(".local"):
            hosts.add(f"{local}.local:{PHONE_PORT}")
        address = self._current_address()
        if address:
            hosts.add(f"{address}:{PHONE_PORT}")
        return {host.lower() for host in hosts}

    @web.middleware
    async def _guard(self, request: web.Request, handler):
        hosts = self._allowed_hosts()
        if (request.host or "").lower() not in hosts:
            raise web.HTTPForbidden()
        origin = request.headers.get("Origin")
        if origin is not None and origin.lower().removeprefix("http://") not in hosts:
            raise web.HTTPForbidden()
        response = await handler(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response

    def _page(self, name: str, content_type: str):
        path = PAGE_DIR / name

        async def handler(_request: web.Request) -> web.StreamResponse:
            if not path.is_file():
                raise web.HTTPNotFound()
            return web.FileResponse(path, headers={"Content-Type": content_type})

        return handler

    def _token_ok(self, offered: str) -> bool:
        return bool(self.token) and hmac.compare_digest(offered, self.token or "")

    async def _manifest(self, request: web.Request) -> web.Response:
        """The Home Screen app starts at the manifest's start_url, so that has to carry the token."""
        offered = request.query.get("t", "")
        start = f"/?t={offered}" if self._token_ok(offered) else "/"
        manifest = {
            "name": "Couch", "short_name": "Couch", "description": "TV remote for your Google TV",
            "start_url": start, "scope": "/", "display": "standalone", "orientation": "portrait",
            "background_color": "#efebe5", "theme_color": "#efebe5",
            "icons": [{"src": "/icon.png", "sizes": "512x512", "type": "image/png", "purpose": "any"}],
        }
        return web.json_response(manifest, content_type="application/manifest+json")

    async def _socket(self, request: web.Request) -> web.WebSocketResponse:
        if not self._token_ok(request.query.get("t", "")):
            raise web.HTTPForbidden()
        return await self._run_socket(request)
