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
from urllib.parse import quote_plus, urlparse
from collections.abc import Awaitable
from typing import Any

from aiohttp import WSMsgType, web
from androidtvremote2 import AndroidTVRemote, CannotConnect, ConnectionClosed, InvalidAuth, VoiceStream
from androidtvremote2.remote import VOICE_CHUNK_MIN_SIZE

from apps import AppsError, AppsManager, AppsStatus
from errors import UserError
from handlers_apps import APPS_HANDLERS, Handler, reply
from phone import PhoneAccess
from tv_tools import TVTools
from text_input import EDIT_KEYS, NAVIGATION_KEYS, FieldTrackingProtocol
from tv import KNOWN_APPS, app_name, check_pairing_code, find_tv, make_remote

TOKEN_HEADER = "X-Couch-Token"
RETRY_SECONDS = 5.0
REDISCOVER_AFTER_SECONDS = 30.0
MAX_TEXT_LENGTH = 2000  # one paste
# Room for a 2000 character paste as escaped JSON, and for audio frames.
MAX_MESSAGE_BYTES = 65536
PARENT_CHECK_SECONDS = 5.0
MAX_PHONES = 6
APPS_RELINK_SECONDS = 60.0
RECENTS_SETTLE_SECONDS = 1.5
# A held voice button that never sends "voice_end" (app crashed) must not keep the TV listening.
MAX_VOICE_SECONDS = 20.0
VOICE_START_SECONDS = 3.0
VOICE_START_ATTEMPTS = 2
BAD_MESSAGE = "Bad message."
TV_UNREACHABLE = "Can't reach the TV. Is it on and on the same Wi-Fi?"

# Only keys that have a button or shortcut on the page can be sent.
ALLOWED_KEYS = frozenset({
    "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_CENTER",
    "BACK", "HOME", "POWER", "TV_INPUT",
    "VOLUME_UP", "VOLUME_DOWN", "VOLUME_MUTE", "MEDIA_PLAY_PAUSE",
    # Explicit pause and play, so automations never resume when they meant to pause.
    "MEDIA_PAUSE", "MEDIA_PLAY",
})
# Short ids the YouTube and Netflix buttons send, mapped to links from known_apps.json.
APP_LINKS = {
    "youtube": KNOWN_APPS["com.google.android.youtube.tv"]["link"],
    "netflix": KNOWN_APPS["com.netflix.ninja"]["link"],
}

MAX_LINK_LENGTH = 2000
MAX_SEARCH_LENGTH = 200
YOUTUBE_SEARCH = "https://www.youtube.com/results?search_query="

log = logging.getLogger("tvremote.server")


def ago(seconds: int | None) -> str:
    """How long ago a recent app was on screen, as the Mac shows it."""
    if seconds is None:
        return "Recently"
    if seconds < 60:
        return "Just now"
    if seconds < 3600:
        return f"{seconds // 60} min ago"
    if seconds < 86_400:
        return f"{seconds // 3600} h ago"
    return f"{seconds // 86_400} d ago"


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
        self.clients: set[web.WebSocketResponse] = set()  # the Mac app
        self.phone_clients: set[web.WebSocketResponse] = set()
        self._lock = asyncio.Lock()
        self._background: set[asyncio.Task[Any]] = set()
        self._connector: asyncio.Task[None] | None = None
        self._rediscover: asyncio.TimerHandle | None = None
        self._voice: VoiceStream | None = None
        self._voice_owner: web.WebSocketResponse | None = None
        self._voice_buffer = bytearray()
        self._voice_timeout: asyncio.TimerHandle | None = None
        self.phone: PhoneAccess  # set by serve()
        self.apps = AppsManager(on_status=self._apps_changed)
        self.tools = TVTools(self.apps)
        self._last_apps_status = AppsStatus.UNKNOWN
        self._relinker: asyncio.Task[None] | None = None
        self._recents_timer: asyncio.TimerHandle | None = None
        self._recents_round = 0  # the newest recent list wins when two lookups overlap
        self.installing = False

    # ------------------------------------------------------------ state

    def snapshot(self, for_phone: bool = False) -> dict[str, Any]:
        remote = self.remote
        volume = remote.volume_info if remote else None
        field = self._field_protocol()
        if field is None:
            field_state = None
        elif for_phone:
            # Phones see that a box is open, never its text or length: it can be a password.
            field_state = {"active": field.field_active, "value": ""}
        else:
            # The Mac mirrors the TV text box so the user sees what they type.
            field_state = {"active": field.field_active, "value": field.field_value}
        app = remote.current_app if remote else None
        return {
            "type": "state",
            "status": self.status,
            "notice": self.notice,
            "notice_id": self.notice_id,
            "tv": self.tv_name,
            "is_on": remote.is_on if remote else None,
            "app": app,
            "app_name": app_name(app),
            "volume": dict(volume) if volume else None,
            "field": field_state,
        }

    def _set(self, status: str, notice: str = "") -> None:
        self.status = status
        self.notice = notice
        if notice:
            self.notice_id += 1
        self._push()

    def spawn(self, coro: Awaitable[Any]) -> None:
        task = asyncio.ensure_future(coro)
        self._background.add(task)
        task.add_done_callback(self._background.discard)

    def _push(self) -> None:
        """Schedule a state broadcast to every client. Safe to call from library callbacks."""
        self.spawn(self._send_all(self.clients, self.snapshot()))
        self.spawn(self._send_all(self.phone_clients, self.snapshot(for_phone=True)))

    async def broadcast(self, message: dict[str, Any]) -> None:
        """Send to the Mac app only."""
        await self._send_all(self.clients, message)

    @staticmethod
    async def _send_all(clients: set[web.WebSocketResponse], message: dict[str, Any]) -> None:
        for ws in list(clients):
            try:
                await ws.send_json(message)
            except (ConnectionError, RuntimeError):
                clients.discard(ws)

    def _app_changed(self, _app: str) -> None:
        self._push()
        # The order of recent apps changed; send the new list once the TV has settled.
        if self._recents_timer:
            self._recents_timer.cancel()
        self._recents_timer = asyncio.get_running_loop().call_later(
            RECENTS_SETTLE_SECONDS, lambda: self.spawn(self.push_recents()))

    @staticmethod
    def recents_message(recents: list[dict], for_phone: bool) -> dict[str, Any]:
        if for_phone:
            # Phones get names to tap, not when each app was last watched.
            apps = [{"package": item["package"], "name": app_name(item["package"])} for item in recents]
        else:
            apps = [{"package": item["package"], "name": app_name(item["package"]), "live": item["live"],
                     "when": ago(item["inactive"])} for item in recents]
        return {"type": "recents", "apps": apps}

    async def _fetch_recents(self) -> list[dict]:
        if self.apps.status != AppsStatus.READY:
            return []
        try:
            return await self.apps.recents()
        except AppsError:
            return []  # the link dropped; that status change is already sent

    async def recents_for(self, ws: web.WebSocketResponse) -> dict[str, Any]:
        return self.recents_message(await self._fetch_recents(), for_phone=ws in self.phone_clients)

    async def push_recents(self) -> None:
        self._recents_round += 1
        round_ = self._recents_round
        recents = await self._fetch_recents()
        if round_ != self._recents_round:
            return  # a newer lookup started meanwhile; it sends the fresher list
        await self._send_all(self.clients, self.recents_message(recents, for_phone=False))
        await self._send_all(self.phone_clients, self.recents_message(recents, for_phone=True))

    async def close_phones(self) -> None:
        for ws in list(self.phone_clients):
            await ws.close(code=4403, message=b"phone access changed")
        self.phone_clients.clear()

    # ------------------------------------------------------------ installed apps

    def apps_message(self, installed: list[str] | None = None) -> dict[str, Any]:
        message: dict[str, Any] = {"type": "apps", "status": str(self.apps.status), "message": self.apps.message}
        if installed is not None:
            message["installed"] = installed
        return message

    def _apps_changed(self) -> None:
        self.spawn(self.broadcast(self.apps_message()))
        # List once when the link comes up, not on every repeat of the same state.
        if self.apps.status == AppsStatus.READY and self._last_apps_status != AppsStatus.READY:
            self.spawn(self.refresh_apps())
            self.spawn(self.push_recents())
        elif self.apps.status != AppsStatus.READY and self._last_apps_status == AppsStatus.READY:
            self.spawn(self.push_recents())  # an empty list, so no page keeps a strip it cannot use
        self._last_apps_status = self.apps.status

    async def refresh_apps(self) -> None:
        """Send the Mac the list of installed apps. Errors become a status change, already sent."""
        try:
            installed = await self.apps.installed()
        except AppsError:
            return
        await self.broadcast(self.apps_message(installed))

    # ------------------------------------------------------------ connection

    def start(self) -> None:
        if self._connector is None or self._connector.done():
            self._connector = asyncio.get_running_loop().create_task(self._connect_loop())
        if self._relinker is None:
            self._relinker = asyncio.get_running_loop().create_task(self._keep_apps_linked())

    async def _keep_apps_linked(self) -> None:
        """Wireless debugging moves to a new port on every TV restart. Once paired, follow it."""
        while True:
            await asyncio.sleep(APPS_RELINK_SECONDS)
            self._relink_apps()

    def _relink_apps(self) -> None:
        """Reconnect a link that worked before. Never after a refusal or while it needs pairing:
        those wait for the user, and retrying would show the TV's prompt again and again."""
        retry = self.apps.status == AppsStatus.UNKNOWN or (
            self.apps.status == AppsStatus.OFF and self.apps.link_dropped)
        if (self.status == "connected" and self.remote is not None and retry
                and AppsManager.was_linked() and not self.apps.busy()):
            self.apps.connect(self.remote.host)

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
        self._relink_apps()

    def _watch(self, remote: AndroidTVRemote) -> None:
        remote.add_is_on_updated_callback(lambda _on: self._push())
        remote.add_current_app_updated_callback(self._app_changed)
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
            self._relink_apps()  # the TV came back, likely restarted: debugging has a new port
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

    def require_connected(self) -> AndroidTVRemote:
        # The library does not raise while it reconnects, it drops the key, so check ourselves.
        if self.status != "connected" or self.remote is None:
            raise UserError("Not connected to the TV right now.")
        return self.remote

    def send_key(self, key: object) -> None:
        if key not in ALLOWED_KEYS:
            raise UserError("Unknown button.")
        self.require_connected().send_key_command(key)

    def edit(self, text: object = None, key: object = None, clear: bool = False) -> None:
        """Type into the focused TV text box: insert `text`, press an edit `key`, or `clear` it."""
        protocol = self._field_protocol() if self.status == "connected" else None
        if protocol is None:
            raise UserError("Not connected to the TV right now.")
        # Without a focused box, Delete and Enter would act as Back and Select on the TV.
        if not protocol.field_active and key not in NAVIGATION_KEYS:
            raise UserError("Select a text box on the TV first.")
        if clear:
            protocol.queue_clear()
        elif key is not None:
            if key not in EDIT_KEYS:
                raise UserError("Unknown key.")
            protocol.queue_key(key)  # dropped when a held key has run far ahead; that is intended
        elif isinstance(text, str) and 0 < len(text) <= MAX_TEXT_LENGTH:
            protocol.queue_insert(text)
        else:
            raise UserError(f"Text must be 1 to {MAX_TEXT_LENGTH} characters.")

    def launch(self, app: object) -> None:
        link = APP_LINKS.get(app) if isinstance(app, str) else None
        if link is None:
            raise UserError("Unknown app.")
        self.require_connected().send_launch_app_command(link)

    def open(self, link: object) -> None:
        """Open a web link on the TV. Apps that claim the link (youtube.com, netflix.com) open it.

        The TV refuses package launches (market://launch?id=, android-app:// and intent: links all
        come back as errors, tested 2026-10-12), so web links are the only way to start an app.
        """
        if not isinstance(link, str) or not link or len(link) > MAX_LINK_LENGTH:
            raise UserError("That link is too long or empty.")
        parts = urlparse(link)
        if parts.scheme not in ("http", "https") or not parts.netloc:
            raise UserError("Couch can open web links only.")
        self.require_connected().send_launch_app_command(link)

    def search_youtube(self, query: object) -> None:
        if not isinstance(query, str) or not query.strip() or len(query) > MAX_SEARCH_LENGTH:
            raise UserError(f"Search for 1 to {MAX_SEARCH_LENGTH} characters.")
        self.require_connected().send_launch_app_command(YOUTUBE_SEARCH + quote_plus(query.strip()))

    # ------------------------------------------------------------ voice

    async def voice_start(self, owner: web.WebSocketResponse) -> None:
        """Open the TV's voice search; audio then arrives as binary frames from `owner`."""
        remote = self.require_connected()
        if self._voice is not None:
            raise UserError("Already listening.")
        if not remote.is_voice_enabled:
            raise UserError("This TV does not accept voice from Couch.")
        for attempt in range(VOICE_START_ATTEMPTS):
            try:
                self._voice = await remote.start_voice(timeout=VOICE_START_SECONDS)
                break
            except TimeoutError as exc:
                # On the screensaver the first press only wakes the TV; the second opens voice search.
                log.info("voice did not start (attempt %s): %r", attempt + 1, exc)
            except ConnectionClosed as exc:
                log.info("voice did not start: %r", exc)
                break
        if self._voice is None:
            raise UserError("The TV did not start listening. Try again.")
        self._voice_owner = owner
        self._voice_buffer.clear()
        self._voice_timeout = asyncio.get_running_loop().call_later(MAX_VOICE_SECONDS, self.voice_end)
        await owner.send_json({"type": "voice", "listening": True})

    def voice_audio(self, owner: web.WebSocketResponse, data: bytes) -> None:
        """16-bit mono PCM at 8 kHz. Sent on in chunks of the size the TV wants, so it gets no padding."""
        if self._voice is None or owner is not self._voice_owner:
            return
        self._voice_buffer += data
        try:
            while len(self._voice_buffer) >= VOICE_CHUNK_MIN_SIZE:
                self._voice.send_chunk(bytes(self._voice_buffer[:VOICE_CHUNK_MIN_SIZE]))
                del self._voice_buffer[:VOICE_CHUNK_MIN_SIZE]
        except ConnectionClosed:
            # The TV dropped mid-sentence; end the session so the app stops recording.
            self._voice_buffer.clear()
            self.voice_end()

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
            self.spawn(listener.send_json({"type": "voice", "listening": False}))

    def close(self) -> None:
        self.voice_end()
        if self._relinker:
            self._relinker.cancel()
        if self._recents_timer:
            self._recents_timer.cancel()
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
    return await run_socket(request, request.app[SESSION], phone=False)


async def run_socket(request: web.Request, session: TVSession, phone: bool) -> web.WebSocketResponse:
    """Serve one client: push TV state, run its requests. Phones get fewer requests and no voice."""
    clients = session.phone_clients if phone else session.clients
    if phone and len(clients) >= MAX_PHONES:
        raise web.HTTPServiceUnavailable()
    handlers = PHONE_HANDLERS if phone else HANDLERS
    ws = web.WebSocketResponse(heartbeat=20, max_msg_size=MAX_MESSAGE_BYTES)
    await ws.prepare(request)
    clients.add(ws)
    await ws.send_json(session.snapshot(for_phone=phone))
    if not phone:
        await ws.send_json(session.apps_message())
    try:
        async for msg in ws:
            if msg.type == WSMsgType.TEXT:
                await handle_message(session, handlers, ws, msg.data)
            elif msg.type == WSMsgType.BINARY and not phone:
                session.voice_audio(ws, msg.data)
    finally:
        session.voice_end(ws)
        clients.discard(ws)
    return ws


async def _key(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.send_key(message.get("key"))


async def _edit(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.edit(text=message.get("text"), key=message.get("key"), clear=message.get("clear") is True)


async def _app(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.launch(message.get("app"))


async def _open(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.open(message.get("link"))


async def _search(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.search_youtube(message.get("query"))


async def _pair_start(session: TVSession, _ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    await session.start_pairing()


async def _pair_code(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    await session.finish_pairing(message.get("code"))


async def _voice_start(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    await session.voice_start(ws)


async def _voice_end(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    session.voice_end(ws)


async def _phone_get(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    await ws.send_json(session.phone.info())


async def _phone_set(session: TVSession, ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    await session.phone.set_enabled(message.get("enabled") is True)
    await ws.send_json(session.phone.info())


async def _phone_reset(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    await session.phone.reset_token()
    await ws.send_json(session.phone.info())


HANDLERS: dict[str, Handler] = {
    "key": _key,
    "edit": _edit,
    "app": _app,
    "open": _open,
    "search": _search,
    "pair_start": _pair_start,
    "pair_code": _pair_code,
    "voice_start": _voice_start,
    "voice_end": _voice_end,
    "phone_get": _phone_get,
    "phone_set": _phone_set,
    "phone_reset": _phone_reset,
    **APPS_HANDLERS,
}

# Phones get the remote, typing, YouTube search, the recent apps strip and one click Settings.
# Pairing, voice, links, phone settings, installing, uninstalling and TV tweaks stay on the Mac.
PHONE_HANDLERS: dict[str, Handler] = {
    name: HANDLERS[name] for name in ("key", "edit", "app", "search", "open_settings", "recents", "resume")
}


async def handle_message(session: TVSession, handlers: dict[str, Handler], ws: web.WebSocketResponse, data: str) -> None:
    try:
        message = json.loads(data)
    except json.JSONDecodeError:
        await reply(ws, {"type": "error", "message": BAD_MESSAGE})
        return
    kind = message.get("type") if isinstance(message, dict) else None
    handler = handlers.get(kind) if isinstance(kind, str) else None
    if handler is None:
        await reply(ws, {"type": "error", "message": BAD_MESSAGE, "for": None})
        return
    run = run_handler(session, handler, ws, message, kind)
    if kind in APPS_HANDLERS:
        session.spawn(run)  # adb can take minutes; keep this socket's keys and voice flowing
    else:
        await run


async def run_handler(session: TVSession, handler: Handler, ws: web.WebSocketResponse,
                      message: dict[str, Any], kind: str) -> None:
    try:
        await handler(session, ws, message)
    except UserError as exc:
        # `for` tells the app which request failed, so a typing error does not cancel a voice hold.
        await reply(ws, {"type": "error", "message": str(exc), "for": kind})
    except (CannotConnect, ConnectionClosed):
        await reply(ws, {"type": "error", "message": TV_UNREACHABLE})
    except Exception:
        # Log the message type only: text messages can hold passwords typed for the TV.
        log.exception("failed to handle a %r message", kind)
        await reply(ws, {"type": "error", "message": "Something went wrong. Try again."})


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
    session.phone = PhoneAccess(lambda request: run_socket(request, session, phone=True), session.close_phones)
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
    await session.phone.start()
    watchdog = asyncio.create_task(exit_when_parent_dies(parent_pid, shutdown)) if parent_pid else None
    try:
        await shutdown.wait()
    finally:
        if watchdog:
            watchdog.cancel()
        session.close()
        await session.apps.close()
        await session.phone.stop()
        await runner.cleanup()
