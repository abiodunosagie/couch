"""TV upgrade helpers: parsing and the strict checks before anything reaches the TV."""

import json

import pytest

from apps import AppsError
import tv_tools
from tv_tools import TWEAKS, WRITABLE, check_apk, home_package, install_result, parse_memory, parse_storage


def test_storage_and_memory():
    assert parse_storage("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/userdata 4194304 3764224 430080 90% /data")["free"] == 430080 * 1024
    assert parse_memory("MemTotal:        1982996 kB\nMemFree: 1 kB\nMemAvailable:     769096 kB\n") == {
        "total": 1982996 * 1024, "free": 769096 * 1024}


def test_install_results():
    assert install_result("Performing Streamed Install\nSuccess\n") is None
    assert "processor" in install_result("Failure [INSTALL_FAILED_NO_MATCHING_ABIS: ...]")
    assert "INSTALL_FAILED_ABORTED" in install_result("Failure [INSTALL_FAILED_ABORTED: User rejected]")


def test_apk_paths_are_checked(tmp_path):
    with pytest.raises(AppsError):
        check_apk("/etc/passwd")
    with pytest.raises(AppsError):
        check_apk(None)
    outside = tmp_path / "app.apk"  # tmp is outside the home folder on macOS
    outside.write_bytes(b"x")
    with pytest.raises(AppsError):
        check_apk(str(outside))


def test_tweak_values_are_fixed():
    for tweak in TWEAKS.values():
        assert tweak.namespace in {"global", "system", "secure"}
        assert all(value.replace(".", "").isdigit() for _choice, _label, value in tweak.choices)


def test_tweak_lookups():
    assert TWEAKS["screensaver_after"].choice("600000") == "10"
    assert TWEAKS["animations"].choice("0.5") == "fast"
    assert TWEAKS["sleep_after"].choice("12345") == "custom"
    assert TWEAKS["sleep_after"].value("120") == "7200000"
    assert TWEAKS["sleep_after"].value("7") is None
    assert [label for _c, label, _v in TWEAKS["sleep_after"].choices] == ["30 min", "1 hour", "2 hours", "4 hours"]


def test_writable_keys_are_exact_pairs():
    assert "global/transition_animation_scale" in WRITABLE
    assert "secure/window_animation_scale" not in WRITABLE  # right key, wrong namespace
    assert "system/transition_animation_scale" not in WRITABLE


def test_tampered_originals_are_ignored(tmp_path, monkeypatch):
    monkeypatch.setattr(tv_tools, "ORIGINALS_FILE", tmp_path / "originals.json")
    (tmp_path / "originals.json").write_text(json.dumps({
        "global/window_animation_scale": "1.0",
        "system/screen_off_timeout": "null",
        "secure/sleep_timeout": "Exception occurred while executing",
        "secure/window_animation_scale": "0",
        "noslash": "1",
        "global/animator_duration_scale": 5,
    }))
    assert tv_tools._load_originals() == {"global/window_animation_scale": "1.0", "system/screen_off_timeout": "null"}


def test_home_package():
    assert home_package("priority=0 preferredOrder=0\ncom.google.android.apps.tv.launcherx/.home.HomeActivity\n") == \
        "com.google.android.apps.tv.launcherx"
    assert home_package("No activity found\n") is None
    assert home_package("") is None


def test_two_quick_tweaks_keep_both_originals(tmp_path, monkeypatch):
    import asyncio
    import apps
    monkeypatch.setattr(tv_tools, "ORIGINALS_FILE", tmp_path / "originals.json")
    manager = apps.AppsManager(lambda: None)

    async def shell(*commands, timeout=None):
        await asyncio.sleep(0)  # let the other request run in between, as on a real TV
        return ["1.0" if "animation" in c or "animator" in c else "600000" for c in commands]

    manager.shell = shell
    tools = tv_tools.TVTools(manager)

    async def both():
        await asyncio.gather(tools.set_tweak("animations", "fast"), tools.set_tweak("screensaver_after", "5"))
    asyncio.run(both())
    assert set(tv_tools._load_originals()) == WRITABLE - {"secure/sleep_timeout"}
