"""Local helper behind the Couch Mac app.

Holds one connection to the TV and talks to the app over a WebSocket.
Binds to 127.0.0.1 only and checks Host and Origin, so neither other devices on
the Wi-Fi nor websites open in a browser can drive the TV. When the app starts it,
COUCH_TOKEN is set and every request must carry that token, so other local
processes cannot drive the TV either, and the app knows it talks to its own helper.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
import os
from collections.abc import Awaitable, Callable
from typing import Any

from aiohttp import WSMsgType, web
from androidtvremote2 import AndroidTVRemote, CannotConnect, ConnectionClosed, InvalidAuth, VoiceStream
from androidtvremote2.remote import VOICE_CHUNK_MIN_SIZE

from text_input import EDIT_KEYS, FieldTrackingProtocol
from tv import check_pairing_code, find_tv, make_remote

TOKEN_HEADER = "X-Couch-Token"
RETRY_SECONDS = 5.0
REDISCOVER_AFTER_SECONDS = 30.0
MAX_TEXT_LENGTH = 2000  # one paste
MAX_MESSAGE_BYTES = 16384  # room for a 2000 character paste as JSON
PARENT_CHECK_SECONDS = 5.0
# A held voice button that never sends "voice_end" (app crashed) must not keep the TV listening.
MAX_VOICE_SECONDS = 20.0
BAD_MESSAGE = "Bad message."
TV_UNREACHABLE = "Can't reach the TV. Is it on and on the same Wi-Fi?"

# Only keys that have a button or shortcut on the page can be sent.
ALLOWED_KEYS = frozenset({
    "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_CENTER",
    "BACK", "HOME", "POWER", "TV_INPUT",
    "VOLUME_UP", "VOLUME_DOWN", "VOLUME_MUTE", "MEDIA_PLAY_PAUSE",
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
        self._voice: VoiceStream | None = None
        self._voice_owner: web.WebSocketResponse | None = None
        self._voice_buffer = bytearray()
        self._voice_timeout: asyncio.TimerHandle | None = None

    # ------------------------------------------------------------ state

    def snapshot(self) -> dict[str, Any]:
        remote = self.remote
        volume = remote.volume_info if remote else None
        field = self._field_protocol()
        return {
            "type": "state",
            "status": self.status,
            "notice": self.notice,
            "notice_id": self.notice_id,
            "tv": self.tv_name,
            "is_on": remote.is_on if remote else None,
            "app": remote.current_app if remote else None,
            "volume": dict(volume) if volume else None,
            # The focused text box on the TV and its text, mirrored so the user sees what they type.
            "field": {"active": field.field_active, "value": field.field_value} if field else None,
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
                self._go_offline()
            except Exception:
                log.exception("unexpected error while connecting")
                self._go_offline()
            await asyncio.sleep(RETRY_SECONDS)

    def _go_offline(self) -> None:
        # Tell the user once, not again on every retry.
        if self.status != "offline":
            self._set("offline", TV_UNREACHABLE)

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
        self._watch_field()
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
            # The library made a fresh protocol object for the new connection.
            self._watch_field()
            self._set("connected")
            return
        self._set("reconnecting")
        # The library retries the old address forever; if the TV moved to a new IP, look for it again.
        self._rediscover = asyncio.get_running_loop().call_later(REDISCOVER_AFTER_SECONDS, self._restart)

    def _field_protocol(self) -> FieldTrackingProtocol | None:
        # text_input.install() makes every connection a FieldTrackingProtocol; the library
        # keeps the live one in this private attribute and has no public accessor.
        protocol = getattr(self.remote, "_remote_message_protocol", None)
        return protocol if isinstance(protocol, FieldTrackingProtocol) else None

    def _watch_field(self) -> None:
        protocol = self._field_protocol()
        if protocol:
            protocol.on_field_changed = self._push

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

    def edit(self, message: dict[str, Any]) -> None:
        """Type into the focused TV text box: insert `text`, or press an edit `key` (delete, cursor)."""
        self._require_connected()
        protocol = self._field_protocol()
        if protocol is None:
            raise UserError("Not connected to the TV right now.")
        text, key = message.get("text"), message.get("key")
        if key is not None:
            if key not in EDIT_KEYS:
                raise UserError("Unknown key.")
            protocol.queue_edit("key", key)
        elif isinstance(text, str) and 0 < len(text) <= MAX_TEXT_LENGTH:
            protocol.queue_edit("text", text)
        else:
            raise UserError(f"Text must be 1 to {MAX_TEXT_LENGTH} characters.")

    def launch(self, app: object) -> None:
        link = APP_LINKS.get(app) if isinstance(app, str) else None
        if link is None:
            raise UserError("Unknown app.")
        self._require_connected().send_launch_app_command(link)

    # ------------------------------------------------------------ voice

    async def voice_start(self, owner: web.WebSocketResponse) -> None:
        """Open the TV's voice search; audio then arrives as binary frames from `owner`."""
        remote = self._require_connected()
        if self._voice is not None:
            raise UserError("Already listening.")
        if not remote.is_voice_enabled:
            raise UserError("This TV does not accept voice from Couch.")
        try:
            self._voice = await remote.start_voice()
        except (TimeoutError, ConnectionClosed) as exc:
            log.info("voice did not start: %r", exc)
            raise UserError("The TV did not start listening. Try again.") from None
        self._voice_owner = owner
        self._voice_buffer.clear()
        self._voice_timeout = asyncio.get_running_loop().call_later(MAX_VOICE_SECONDS, self.voice_end)
        await owner.send_json({"type": "voice", "listening": True})

    def voice_audio(self, owner: web.WebSocketResponse, data: bytes) -> None:
        """16-bit mono PCM at 8 kHz. Sent on in chunks of the size the TV wants, so it gets no padding."""
        if self._voice is None or owner is not self._voice_owner:
            return
        self._voice_buffer += data
        while len(self._voice_buffer) >= VOICE_CHUNK_MIN_SIZE:
            self._voice.send_chunk(bytes(self._voice_buffer[:VOICE_CHUNK_MIN_SIZE]))
            del self._voice_buffer[:VOICE_CHUNK_MIN_SIZE]

    def voice_end(self, owner: web.WebSocketResponse | None = None) -> None:
        if self._voice is None or (owner is not None and owner is not self._voice_owner):
            return
        voice, self._voice = self._voice, None
        if self._voice_timeout:
            self._voice_timeout.cancel()
            self._voice_timeout = None
        try:
            if self._voice_buffer:
                voice.send_chunk(bytes(self._voice_buffer))
            voice.end()
        except ConnectionClosed:
            pass
        self._voice_buffer.clear()
        listener, self._voice_owner = self._voice_owner, None
        if listener is not None and not listener.closed:
            self._spawn(listener.send_json({"type": "voice", "listening": False}))

    def close(self) -> None:
        self.voice_end()
        self._cancel_rediscover()
        if self._connector:
            self._connector.cancel()
        if self.remote:
            self.remote.disconnect()


# ---------------------------------------------------------------- web app

SESSION = web.AppKey("session", TVSession)
ALLOWED_HOSTS = web.AppKey("allowed_hosts", frozenset)
ALLOWED_ORIGINS = web.AppKey("allowed_origins", frozenset)
TOKEN = web.AppKey("token", str)


@web.middleware
async def local_only(request: web.Request, handler):
    """Reject requests whose Host or Origin is not this app (blocks DNS rebinding and cross-site use)."""
    if request.host not in request.app[ALLOWED_HOSTS]:
        raise web.HTTPForbidden()
    origin = request.headers.get("Origin")
    if origin is not None and origin not in request.app[ALLOWED_ORIGINS]:
        raise web.HTTPForbidden()
    token = request.app[TOKEN]
    if token and not hmac.compare_digest(request.headers.get(TOKEN_HEADER, ""), token):
        raise web.HTTPForbidden()
    return await handler(request)


async def health(_request: web.Request) -> web.Response:
    return web.Response(text="ok")


async def websocket(request: web.Request) -> web.WebSocketResponse:
    # A browser always sends Origin on a WebSocket handshake; requiring it keeps the
    # browser rule in force even when no token is set (tvremote serve from Terminal).
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
            elif msg.type == WSMsgType.BINARY:
                session.voice_audio(ws, msg.data)
    finally:
        session.voice_end(ws)
        session.clients.discard(ws)
    return ws


Handler = Callable[[TVSession, web.WebSocketResponse, dict[str, Any]], Awaitable[None]]


async def _key(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.send_key(message.get("key"))


async def _edit(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.edit(message)


async def _app(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.launch(message.get("app"))


async def _pair_start(session: TVSession, _ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    await session.start_pairing()


async def _pair_code(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    await session.finish_pairing(message.get("code"))


async def _voice_start(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    await session.voice_start(ws)


async def _voice_end(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    session.voice_end(ws)


HANDLERS: dict[str, Handler] = {
    "key": _key,
    "edit": _edit,
    "app": _app,
    "pair_start": _pair_start,
    "pair_code": _pair_code,
    "voice_start": _voice_start,
    "voice_end": _voice_end,
}


async def handle_message(app: web.Application, ws: web.WebSocketResponse, data: str) -> None:
    kind = None
    try:
        message = json.loads(data)
        handler = HANDLERS.get(message.get("type")) if isinstance(message, dict) else None
        if handler is None:
            raise UserError(BAD_MESSAGE)
        kind = message["type"]
        await handler(app[SESSION], ws, message)
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


async def exit_when_parent_dies(parent_pid: int, shutdown: asyncio.Event) -> None:
    """Stop when the Mac app that started us is gone, so no orphan keeps driving the TV."""
    while not shutdown.is_set():
        try:
            os.kill(parent_pid, 0)
        except ProcessLookupError:
            log.info("parent app %s exited, shutting down", parent_pid)
            shutdown.set()
            return
        except PermissionError:
            pass  # exists but owned by someone else; treat as alive
        await asyncio.sleep(PARENT_CHECK_SECONDS)


async def serve(port: int, host: str | None, name: str | None, parent_pid: int | None = None) -> None:
    if parent_pid is not None and parent_pid <= 0:
        raise ValueError("--parent-pid must be a real process id")
    # zeroconf logs a full traceback for every interface without a route (VPN, Thunderbolt bridge).
    logging.getLogger("zeroconf").setLevel(logging.ERROR)
    session = TVSession(host, name)
    shutdown = asyncio.Event()
    app = web.Application(middlewares=[local_only])
    app[SESSION] = session
    app[ALLOWED_HOSTS] = frozenset({f"127.0.0.1:{port}", f"localhost:{port}"})
    app[ALLOWED_ORIGINS] = frozenset({f"http://127.0.0.1:{port}", f"http://localhost:{port}"})
    app[TOKEN] = os.environ.get("COUCH_TOKEN", "")
    app.router.add_get("/health", health)
    app.router.add_get("/ws", websocket)

    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "127.0.0.1", port).start()
    log.info("Couch helper listening on 127.0.0.1:%s", port)
    session.start()
    watchdog = asyncio.create_task(exit_when_parent_dies(parent_pid, shutdown)) if parent_pid else None
    try:
        await shutdown.wait()
    finally:
        if watchdog:
            watchdog.cancel()
        session.close()
        await runner.cleanup()
