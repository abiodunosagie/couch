"""Server rules that keep phones limited and the app manager from nagging the TV."""

import asyncio

import pytest

import server
from apps import AppsError, AppsStatus
from errors import UserError
from handlers_apps import APPS_HANDLERS
from tv import KNOWN_APPS


RECENTS = [{"package": "com.example.player", "inactive": 125, "live": True}]


def test_phones_get_names_only():
    phone = server.TVSession.recents_message(RECENTS, for_phone=True)
    assert phone["apps"] == [{"package": "com.example.player", "name": phone["apps"][0]["name"]}]
    mac = server.TVSession.recents_message(RECENTS, for_phone=False)
    assert mac["apps"][0]["when"] == "2 min ago" and mac["apps"][0]["live"] is True


def test_ago():
    assert [server.ago(s) for s in (None, 5, 61, 7200, 200_000)] == [
        "Recently", "Just now", "1 min ago", "2 h ago", "2 d ago"]


def test_phone_handlers_stay_small():
    assert set(server.PHONE_HANDLERS) == {"key", "edit", "app", "search", "open_settings", "recents", "resume"}
    for mac_only in ("install_apk", "tweak", "apps_uninstall", "close_app", "home_set", "free_space"):
        assert mac_only not in server.PHONE_HANDLERS and mac_only in APPS_HANDLERS


@pytest.mark.parametrize("status, dropped, retries", [
    (AppsStatus.UNKNOWN, False, True),
    (AppsStatus.OFF, True, True),
    (AppsStatus.OFF, False, False),
    (AppsStatus.DENIED, True, False),
    (AppsStatus.NEEDS_PAIRING, True, False),
    (AppsStatus.READY, False, False),
])
def test_relink_only_after_a_dropped_link(monkeypatch, status, dropped, retries):
    async def check():
        session = server.TVSession(None, None)
        session.status = "connected"
        session.remote = type("Remote", (), {"host": "192.0.2.5"})()
        session.apps.status = status
        session.apps.link_dropped = dropped
        calls = []
        monkeypatch.setattr(session.apps, "connect", calls.append)
        monkeypatch.setattr(server.AppsManager, "was_linked", staticmethod(lambda: True))
        session._relink_apps()
        return calls
    assert bool(asyncio.run(check())) is retries


def test_resume_refuses_apps_not_in_the_list():
    async def check():
        session = server.TVSession(None, None)
        session.status = "connected"
        session.remote = object()
        session.apps.status = AppsStatus.READY
        launched = []

        async def recents():
            return RECENTS

        async def launch(package):
            launched.append(package)

        session.apps.recents = recents
        session.apps.launch = launch
        await APPS_HANDLERS["resume"](session, None, {"package": "com.example.player"})
        await APPS_HANDLERS["resume"](session, None, {"package": "com.netflix.ninja"})  # known, not recent
        with pytest.raises(UserError, match="not in the recent list"):
            await APPS_HANDLERS["resume"](session, None, {"package": "com.android.shell"})
        return launched
    assert "com.netflix.ninja" in KNOWN_APPS
    assert asyncio.run(check()) == ["com.example.player", "com.netflix.ninja"]


def test_a_socket_cannot_queue_endless_app_requests(monkeypatch):
    async def check():
        session = server.TVSession(None, None)
        gate = asyncio.Event()
        started = []

        async def slow(_session, _ws, _message):
            started.append(1)
            await gate.wait()

        monkeypatch.setitem(server.HANDLERS, "recents", slow)
        sent = []

        class Socket:
            async def send_json(self, message):
                sent.append(message)

        ws = Socket()
        for _ in range(server.MAX_PENDING_APPS_REQUESTS + 2):
            await server.handle_message(session, server.HANDLERS, ws, '{"type": "recents"}')
        await asyncio.sleep(0)
        busy = [m for m in sent if m.get("type") == "error"]
        gate.set()
        await asyncio.sleep(0)
        await asyncio.sleep(0)
        return len(started), len(busy), session.pending
    started, busy, pending = asyncio.run(check())
    assert (started, busy, pending) == (server.MAX_PENDING_APPS_REQUESTS, 2, {})


def test_unknown_sockets_get_the_phone_list():
    async def check():
        session = server.TVSession(None, None)
        session.apps.status = AppsStatus.READY

        async def recents():
            return RECENTS

        session.apps.recents = recents
        return await session.recents_for(object())
    assert "when" not in asyncio.run(check())["apps"][0]


def test_a_failed_lookup_keeps_the_strip():
    async def check():
        session = server.TVSession(None, None)
        session.apps.status = AppsStatus.READY

        async def recents():
            raise server.AppsError("The TV took too long to answer. Try again.")

        session.apps.recents = recents
        sent = []

        class Socket:
            async def send_json(self, message):
                sent.append(message)

        session.clients.add(Socket())
        await session.push_recents()
        return sent
    assert asyncio.run(check()) == []


@pytest.mark.parametrize("apps_status, app, playing, pressed", [
    (AppsStatus.READY, "com.example.player", True, True),
    (AppsStatus.READY, "com.example.player", False, False),  # paused: the pause key would start some apps
    (AppsStatus.READY, "com.example.player", None, False),  # no media session, nobody can tell
    (AppsStatus.READY, None, True, False),  # the TV did not say which app is in front
    (AppsStatus.OFF, "com.example.player", True, False),  # no app manager: leave the TV alone
    (AppsStatus.READY, "com.example.player", AppsError("Lost the connection"), False),
])
def test_auto_pause_presses_only_when_playing(apps_status, app, playing, pressed):
    async def check():
        session = server.TVSession(None, None)
        session.status = "connected"
        session.remote = type("Remote", (), {"current_app": app})()
        session.apps.status = apps_status
        keys, replies, asked = [], [], []

        async def is_playing(package):
            asked.append(package)
            if isinstance(playing, Exception):
                raise playing
            return playing

        class Socket:
            async def send_json(self, message):
                replies.append(message)

        session.apps.playing = is_playing
        session.send_key = keys.append
        await APPS_HANDLERS["pause_if_playing"](session, Socket(), {})
        return keys, replies, asked
    keys, replies, asked = asyncio.run(check())
    assert keys == (["MEDIA_PAUSE"] if pressed else [])
    assert replies == [{"type": "auto_pause", "paused": pressed}]
    assert asked == ([app] if apps_status == AppsStatus.READY and app else [])


def test_auto_pause_answers_when_the_tv_is_gone():
    async def check():
        session = server.TVSession(None, None)  # never connected
        replies = []

        class Socket:
            async def send_json(self, message):
                replies.append(message)

        await APPS_HANDLERS["pause_if_playing"](session, Socket(), {})
        return replies
    assert asyncio.run(check()) == [{"type": "auto_pause", "paused": False}]


def test_auto_pause_stays_off_the_phone():
    assert "pause_if_playing" in APPS_HANDLERS and "pause_if_playing" not in server.PHONE_HANDLERS
