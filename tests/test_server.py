"""Server rules that keep phones limited and the app manager from nagging the TV."""

import asyncio

import pytest

import server
from apps import AppsStatus
from errors import UserError
from handlers_apps import APPS_HANDLERS


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
        with pytest.raises(UserError):
            await APPS_HANDLERS["resume"](session, None, {"package": "com.android.shell"})
        return launched
    assert asyncio.run(check()) == ["com.example.player"]
