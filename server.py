"""Local web server behind the TV Remote app.

Holds one connection to the TV and talks to the page over a WebSocket.
Binds to 127.0.0.1 only and checks Host and Origin, so neither other devices on
the Wi-Fi nor other websites open in the browser can drive the TV.
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from aiohttp import WSMsgType, web
from androidtvremote2 import AndroidTVRemote, CannotConnect, ConnectionClosed, InvalidAuth

from tv import check_pairing_code, find_tv, make_remote

STATIC_DIR = Path(__file__).parent / "static"
RETRY_SECONDS = 5.0
REDISCOVER_AFTER_SECONDS = 30.0
MAX_TEXT_LENGTH = 200
MAX_MESSAGE_BYTES = 4096
BAD_MESSAGE = "Bad message."
TV_UNREACHABLE = "Can't reach the TV. Is it on and on the same Wi-Fi?"

# Only keys that have a button or shortcut on the page can be sent.
ALLOWED_KEYS = frozenset({
    "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_CENTER",
    "BACK", "HOME", "POWER", "SETTINGS", "TV_INPUT", "GUIDE",
    "VOLUME_UP", "VOLUME_DOWN", "VOLUME_MUTE",
    "MEDIA_PLAY_PAUSE", "MEDIA_REWIND", "MEDIA_FAST_FORWARD",
})
APP_LINKS = {
    "youtube": "https://www.youtube.com",
    "netflix": "https://www.netflix.com/title",
}

log = logging.getLogger("tvremote.server")


class UserError(Exception):
    """A problem the page can show as is. Never wraps internal error text."""


class TVSession:
    """One TV connection shared by every open remote page.

    status: searching | offline | unpaired | pairing | connected | reconnecting
    """

    def __init__(self, host: str | None, name: str | None) -> None:
        self._host_arg = host
        self._name_arg = name
        self.remote: AndroidTVRemote | None = None
        self.tv_name: str | None = None
        self.status = "searching"
        self.notice = ""
        self.notice_id = 0
        self.clients: set[web.WebSocketResponse] = set()
        self._lock = asyncio.Lock()
        self._background: set[asyncio.Task[Any]] = set()
        self._connector: asyncio.Task[None] | None = None
        self._rediscover: asyncio.TimerHandle | None = None

    # ------------------------------------------------------------ state

    def snapshot(self) -> dict[str, Any]:
        remote = self.remote
        volume = remote.volume_info if remote else None
        return {
            "type": "state",
            "status": self.status,
            "notice": self.notice,
            "notice_id": self.notice_id,
            "tv": self.tv_name,
            "is_on": remote.is_on if remote else None,
            "app": remote.current_app if remote else None,
            "volume": dict(volume) if volume else None,
        }

    def _set(self, status: str, notice: str = "") -> None:
        self.status = status
        self.notice = notice
        if notice:
            self.notice_id += 1
        self._push()

    def _spawn(self, coro: Awaitable[Any]) -> None:
        task = asyncio.ensure_future(coro)
        self._background.add(task)
        task.add_done_callback(self._background.discard)

    def _push(self) -> None:
        """Schedule a state broadcast. Safe to call from library callbacks."""
        self._spawn(self.broadcast(self.snapshot()))

    async def broadcast(self, message: dict[str, Any]) -> None:
        for ws in list(self.clients):
            try:
                await ws.send_json(message)
            except (ConnectionError, RuntimeError):
                self.clients.discard(ws)

    # ------------------------------------------------------------ connection

    def start(self) -> None:
        if self._connector is None or self._connector.done():
            self._connector = asyncio.get_running_loop().create_task(self._connect_loop())

    async def _connect_loop(self) -> None:
        """Find and connect to the TV, retrying until it answers or needs pairing."""
        while True:
            try:
                await self._connect_once()
                return
            except InvalidAuth:
                self._set("unpaired")
                return
            except (CannotConnect, ConnectionClosed, OSError) as exc:
                log.info("TV not reachable yet: %s", exc)
                self._set("offline", TV_UNREACHABLE)
            except Exception:
                log.exception("unexpected error while connecting")
                self._set("offline", TV_UNREACHABLE)
            await asyncio.sleep(RETRY_SECONDS)

    async def _connect_once(self) -> None:
        name, host = await find_tv(self._host_arg, self._name_arg)
        self.tv_name = name
        if self.remote is None or self.remote.host != host:
            if self.remote:
                self.remote.disconnect()
            self.remote = await make_remote(host)
            self._watch(self.remote)
        await self.remote.async_connect()
        self.remote.keep_reconnecting(self._on_invalid_auth)
        self._set("connected")

    def _watch(self, remote: AndroidTVRemote) -> None:
        remote.add_is_on_updated_callback(lambda _on: self._push())
        remote.add_current_app_updated_callback(lambda _app: self._push())
        remote.add_volume_info_updated_callback(lambda _vol: self._push())
        remote.add_is_available_updated_callback(self._on_available)

    def _on_available(self, available: bool) -> None:
        if self.status not in ("connected", "reconnecting"):
            return
        self._cancel_rediscover()
        if available:
            self._set("connected")
            return
        self._set("reconnecting")
        # The library retries the old address forever; if the TV moved to a new IP, look for it again.
        self._rediscover = asyncio.get_running_loop().call_later(REDISCOVER_AFTER_SECONDS, self._restart)

    def _cancel_rediscover(self) -> None:
        if self._rediscover:
            self._rediscover.cancel()
            self._rediscover = None

    def _restart(self) -> None:
        self._rediscover = None
        if self.status != "reconnecting" or self.remote is None:
            return
        log.info("still disconnected, searching the network for the TV again")
        self.remote.disconnect()
        self._set("searching")
        self.start()

    def _on_invalid_auth(self) -> None:
        self._cancel_rediscover()
        self._set("unpaired", "The TV forgot this Mac. Pair again.")

    # ------------------------------------------------------------ pairing

    async def start_pairing(self) -> None:
        async with self._lock:
            if self.status not in ("unpaired", "pairing") or self.remote is None:
                raise UserError("Pairing is only needed when the TV does not know this Mac.")
            await self._begin_pairing("A code is now showing on the TV.")

    async def _begin_pairing(self, notice: str) -> None:
        assert self.remote is not None
        try:
            await self.remote.async_start_pairing()
        except (CannotConnect, ConnectionClosed, InvalidAuth, OSError) as exc:
            log.info("could not start pairing: %s", exc)
            self._set("unpaired", "Can't reach the TV to pair. Is it on?")
            return
        self._set("pairing", notice)

    async def finish_pairing(self, raw_code: object) -> None:
        async with self._lock:
            if self.status != "pairing" or self.remote is None:
                raise UserError("Start pairing first.")
            try:
                code = check_pairing_code(raw_code if isinstance(raw_code, str) else "")
            except ValueError as exc:
                raise UserError(str(exc)) from None
            try:
                await self.remote.async_finish_pairing(code)
            except InvalidAuth:
                await self._begin_pairing("The TV rejected that code. Enter the new one it shows.")
                return
            except ConnectionClosed:
                await self._begin_pairing("Pairing timed out. Enter the new code on the TV.")
                return
            self._set("searching", "Paired.")
        self.start()

    # ------------------------------------------------------------ commands

    def _require_connected(self) -> AndroidTVRemote:
        # The library does not raise while it reconnects, it drops the key, so check ourselves.
        if self.status != "connected" or self.remote is None:
            raise UserError("Not connected to the TV right now.")
        return self.remote

    def send_key(self, key: object) -> None:
        if key not in ALLOWED_KEYS:
            raise UserError("Unknown button.")
        self._require_connected().send_key_command(key)

    def send_text(self, text: object) -> None:
        if not isinstance(text, str) or not text or len(text) > MAX_TEXT_LENGTH:
            raise UserError(f"Text must be 1 to {MAX_TEXT_LENGTH} characters.")
        self._require_connected().send_text(text)

    def launch(self, app: object) -> None:
        link = APP_LINKS.get(app) if isinstance(app, str) else None
        if link is None:
            raise UserError("Unknown app.")
        self._require_connected().send_launch_app_command(link)

    def close(self) -> None:
        self._cancel_rediscover()
        if self._connector:
            self._connector.cancel()
        if self.remote:
            self.remote.disconnect()


# ---------------------------------------------------------------- web app

SESSION = web.AppKey("session", TVSession)
SHUTDOWN = web.AppKey("shutdown", asyncio.Event)
ALLOWED_HOSTS = web.AppKey("allowed_hosts", frozenset)
ALLOWED_ORIGINS = web.AppKey("allowed_origins", frozenset)


@web.middleware
async def local_only(request: web.Request, handler):
    """Reject requests whose Host or Origin is not this app (blocks DNS rebinding and cross-site use)."""
    if request.host not in request.app[ALLOWED_HOSTS]:
        raise web.HTTPForbidden()
    origin = request.headers.get("Origin")
    if origin is not None and origin not in request.app[ALLOWED_ORIGINS]:
        raise web.HTTPForbidden()
    return await handler(request)


async def index(_request: web.Request) -> web.FileResponse:
    return web.FileResponse(STATIC_DIR / "index.html", headers={"Cache-Control": "no-store"})


async def health(_request: web.Request) -> web.Response:
    return web.Response(text="ok")


async def websocket(request: web.Request) -> web.WebSocketResponse:
    # Browsers always send Origin on a WebSocket handshake; the middleware has already checked it.
    if request.headers.get("Origin") is None:
        raise web.HTTPForbidden()
    session = request.app[SESSION]
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=MAX_MESSAGE_BYTES)
    await ws.prepare(request)
    session.clients.add(ws)
    await ws.send_json(session.snapshot())
    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                await handle_message(request.app, ws, msg.data)
    finally:
        session.clients.discard(ws)
    return ws


async def quit_app(app: web.Application, _message: dict[str, Any]) -> None:
    await app[SESSION].broadcast({"type": "closed"})
    app[SHUTDOWN].set()


def _sync(method: Callable[[TVSession, object], None], field: str):
    async def handler(app: web.Application, message: dict[str, Any]) -> None:
        method(app[SESSION], message.get(field))
    return handler


async def _pair_start(app: web.Application, _message: dict[str, Any]) -> None:
    await app[SESSION].start_pairing()


async def _pair_code(app: web.Application, message: dict[str, Any]) -> None:
    await app[SESSION].finish_pairing(message.get("code"))


HANDLERS: dict[str, Callable[[web.Application, dict[str, Any]], Awaitable[None]]] = {
    "key": _sync(TVSession.send_key, "key"),
    "text": _sync(TVSession.send_text, "text"),
    "app": _sync(TVSession.launch, "app"),
    "pair_start": _pair_start,
    "pair_code": _pair_code,
    "quit": quit_app,
}


async def handle_message(app: web.Application, ws: web.WebSocketResponse, data: str) -> None:
    kind = None
    try:
        message = json.loads(data)
        handler = HANDLERS.get(message.get("type")) if isinstance(message, dict) else None
        if handler is None:
            raise UserError(BAD_MESSAGE)
        kind = message["type"]
        await handler(app, message)
    except json.JSONDecodeError:
        await ws.send_json({"type": "error", "message": BAD_MESSAGE})
    except UserError as exc:
        await ws.send_json({"type": "error", "message": str(exc)})
    except (CannotConnect, ConnectionClosed):
        await ws.send_json({"type": "error", "message": TV_UNREACHABLE})
    except Exception:
        # Log the message type only: text messages can hold passwords typed for the TV.
        log.exception("failed to handle a %r message", kind)
        await ws.send_json({"type": "error", "message": "Something went wrong. Try again."})


async def serve(port: int, host: str | None, name: str | None) -> None:
    # zeroconf logs a full traceback for every interface without a route (VPN, Thunderbolt bridge).
    logging.getLogger("zeroconf").setLevel(logging.ERROR)
    session = TVSession(host, name)
    shutdown = asyncio.Event()
    app = web.Application(middlewares=[local_only])
    app[SESSION] = session
    app[SHUTDOWN] = shutdown
    app[ALLOWED_HOSTS] = frozenset({f"127.0.0.1:{port}", f"localhost:{port}"})
    app[ALLOWED_ORIGINS] = frozenset({f"http://127.0.0.1:{port}", f"http://localhost:{port}"})
    app.router.add_get("/", index)
    app.router.add_get("/health", health)
    app.router.add_get("/ws", websocket)
    app.router.add_static("/static", STATIC_DIR, show_index=False)

    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port).start()
    log.info("TV Remote running at http://127.0.0.1:%s", port)
    session.start()
    try:
        await shutdown.wait()
    finally:
        session.close()
        await runner.cleanup()
