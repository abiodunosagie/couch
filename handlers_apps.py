"""WebSocket requests that go through the TV's app manager (adb).

adb commands can take seconds, an install minutes, so the server runs every handler here off
the socket's read loop: remote keys keep working meanwhile. Each handler shows an AppsError
to the user as is, since those messages are written for people.
"""

from __future__ import annotations

import functools
import logging
from collections.abc import Awaitable, Callable
from typing import TYPE_CHECKING, Any

from aiohttp import web
from androidtvremote2 import ConnectionClosed

from apps import AppsError, AppsManager, AppsStatus
from errors import UserError
from tv import KNOWN_APPS

if TYPE_CHECKING:
    from server import TVSession

log = logging.getLogger("tvremote.server")

Handler = Callable[["TVSession", web.WebSocketResponse, dict[str, Any]], Awaitable[None]]


async def reply(ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    """Send to one client that may have closed while a slow command ran (aiohttp raises
    ConnectionError, or RuntimeError for a socket already closing)."""
    try:
        await ws.send_json(message)
    except (ConnectionError, RuntimeError):
        pass


def apps_handler(handler: Handler) -> Handler:
    """Show an AppsError's message to the user."""
    @functools.wraps(handler)
    async def wrapped(session: TVSession, ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
        try:
            await handler(session, ws, message)
        except AppsError as exc:
            raise UserError(str(exc)) from None
    return wrapped


def _app_manager(session: TVSession, needed_for: str = "This") -> AppsManager:
    session.require_connected()
    if session.apps.status != AppsStatus.READY:
        raise UserError(f"{needed_for} needs the TV's app manager. Connect it in Apps first.")
    return session.apps


# ---------------------------------------------------------------- link

async def _apps_connect(session: TVSession, _ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    # Runs in the background (the TV may wait a minute for the user); status changes are pushed.
    session.apps.connect(session.require_connected().host)


@apps_handler
async def _apps_pair(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    session.apps.pair(session.require_connected().host, message.get("code"), message.get("address"))


# ---------------------------------------------------------------- apps

@apps_handler
async def _apps_list(session: TVSession, _ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    installed = await session.apps.installed()
    await session.broadcast(session.apps_message(installed))


@apps_handler
async def _apps_launch(session: TVSession, ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    await _app_manager(session).launch(message.get("package"))
    await reply(ws, {"type": "apps_launched", "package": message.get("package")})


@apps_handler
async def _apps_uninstall(session: TVSession, ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    await _app_manager(session).uninstall(message.get("package"))
    await reply(ws, {"type": "apps_uninstalled", "package": message.get("package")})
    await _apps_list(session, ws, {})


@apps_handler
async def _open_settings(session: TVSession, _ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    await _app_manager(session, "One click Settings").open_settings()


# ---------------------------------------------------------------- recent apps

async def _recents(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    # The phone asks on every connect, also before the app manager is up: no error then.
    message = await session.recents_for(ws)
    if message is not None:
        await reply(ws, message)


@apps_handler
async def _resume(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    """Bring a recent app back where it was. Phones may do this, so only for an app in the
    recent list (or one of the apps Couch knows), never any package a client names."""
    manager = _app_manager(session)
    package = message.get("package")
    recent = {item["package"] for item in await manager.recents()}
    if package not in recent and package not in KNOWN_APPS:
        raise UserError("That app is not in the recent list any more.")
    await manager.launch(package)


async def _pause_if_playing(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    """Auto pause. Some TV apps (Netflix for one) take the pause key as play/pause, so a pause
    sent to a paused TV starts it. Press only when the app says it is playing; when nobody can
    tell (no app manager, no app in front, no media session), leave the TV alone. Answers whether
    it paused, so the Mac only resumes what it paused. Quiet on failure: this runs on its own, not
    on a click."""
    paused = False
    try:
        app = session.require_connected().current_app
        if app and session.apps.status == AppsStatus.READY and await session.apps.playing(app):
            session.send_key("MEDIA_PAUSE")
            paused = True
    except (UserError, AppsError, ConnectionClosed) as exc:
        log.info("auto pause skipped: %s", exc)
    finally:
        # Always answer, so the Mac never waits on this for good. Errors not caught above still
        # reach run_handler after this.
        await reply(ws, {"type": "auto_pause", "paused": paused})


@apps_handler
async def _close_app(session: TVSession, _ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    await _app_manager(session).close_app(message.get("package"))
    await session.push_recents()


# ---------------------------------------------------------------- TV upgrades

@apps_handler
async def _tools_status(session: TVSession, ws: web.WebSocketResponse, _message: dict[str, Any]) -> None:
    _app_manager(session)
    await reply(ws, await session.tools.status())


def _tool(action: Callable[[TVSession, dict[str, Any]], Awaitable[str | None]]) -> Handler:
    """A Mac only TV upgrade: runs `action`, then sends the fresh status and its notice."""
    @apps_handler
    async def handler(session: TVSession, ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
        _app_manager(session)
        notice = await action(session, message)
        await reply(ws, await session.tools.status())
        if notice:
            await reply(ws, {"type": "notice", "message": notice})
    return handler


async def _tweak(session: TVSession, message: dict[str, Any]) -> str | None:
    await session.tools.set_tweak(message.get("name"), message.get("choice"))
    return None


async def _reset(session: TVSession, _message: dict[str, Any]) -> str:
    await session.tools.reset_tweaks()
    return "The TV settings are back the way they were."


async def _free_space(session: TVSession, _message: dict[str, Any]) -> str:
    await session.tools.free_space()
    return "Cleared app caches on the TV."


async def _free_memory(session: TVSession, _message: dict[str, Any]) -> str:
    current = session.remote.current_app if session.remote else None
    stopped = await session.tools.free_memory(current)
    await session.push_recents()
    if not stopped:
        return "Nothing else was running."
    apps = "1 app" if stopped == 1 else f"{stopped} apps"
    return f"Stopped {apps} in the background."


async def _home_suggest(session: TVSession, _message: dict[str, Any]) -> str:
    await session.tools.suggest_home()
    return "The Play Store page is open on the TV. Install it there, then choose it here."


async def _home_set(session: TVSession, message: dict[str, Any]) -> str:
    await session.tools.set_home(message.get("package"))
    return "Home screen changed."


async def _install(session: TVSession, ws: web.WebSocketResponse, message: dict[str, Any]) -> None:
    """One install at a time. The result goes to every Mac window (it may have reconnected
    meanwhile), even when something unexpected fails."""
    _app_manager(session)
    if session.installing:
        raise UserError("An app is already installing. Wait for it to finish.")
    session.installing = True
    try:
        await session.broadcast({"type": "install", "state": "installing"})
        try:
            name = await session.tools.install(message.get("path"))
        except AppsError as exc:
            await session.broadcast({"type": "install", "state": "failed", "message": str(exc)})
            return
        except Exception:
            log.exception("install failed")
            await session.broadcast({"type": "install", "state": "failed", "message": "Couch could not install that app."})
            return
        await session.broadcast({"type": "install", "state": "done", "message": f"Installed {name} on the TV."})
    finally:
        session.installing = False
    await session.refresh_apps()


# Installed apps, recent apps and TV upgrades. The server runs all of these off the read loop.
# Phones reach only the few that server.PHONE_HANDLERS picks (recents, resume, open_settings).
APPS_HANDLERS: dict[str, Handler] = {
    "apps_connect": _apps_connect,
    "apps_pair": _apps_pair,
    "apps_list": _apps_list,
    "apps_launch": _apps_launch,
    "apps_uninstall": _apps_uninstall,
    "open_settings": _open_settings,
    "recents": _recents,
    "resume": _resume,
    "close_app": _close_app,
    "pause_if_playing": _pause_if_playing,
    "tools_status": _tools_status,
    "tweak": _tool(_tweak),
    "tweaks_reset": _tool(_reset),
    "free_space": _tool(_free_space),
    "free_memory": _tool(_free_memory),
    "home_suggest": _tool(_home_suggest),
    "home_set": _tool(_home_set),
    "install_apk": _install,
}
