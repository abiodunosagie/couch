"""adb output parsing, from real output of Google's adb against a Chromecast with Google TV."""

from apps import AppsError, check_package, connected, paired, parse_packages
import pytest


def test_connect_output():
    assert connected("connected to 192.168.1.11:33417\n")
    assert connected("already connected to 192.168.1.11:33417")
    assert not connected("failed to connect to 192.168.1.11:33417")  # an unpaired TV says this
    assert not connected("failed to authenticate to 192.168.1.11:5555")


def test_pair_output():
    assert paired("Successfully paired to 192.168.1.11:37121 [guid=adb-17191HFDD3DQYY-7cQZfj]")
    assert not paired("Failed: Wrong password or connection was dropped.")


def test_package_list_drops_anything_that_is_not_a_package():
    output = "package:com.netflix.ninja\npackage:com.example.app\nnot a line\npackage:bad name;rm\n"
    assert parse_packages(output) == ["com.example.app", "com.netflix.ninja"]


@pytest.mark.parametrize("bad", ["", "rm -rf /", "com.x;reboot", "com..x", "1com.x", None, "a" * 300])
def test_package_names_are_strict(bad):
    with pytest.raises(AppsError):
        check_package(bad)


def test_output_after_adb_daemon_start_lines():
    from apps import last_line, lost_device
    banner = "* daemon not running; starting now at tcp:5037\n* daemon started successfully\n"
    assert connected(banner + "connected to 192.168.1.11:33417\n")
    assert last_line(banner + "device\n") == "device"
    assert lost_device("error: device '192.168.1.11:33417' not found")
    assert not lost_device("package:com.netflix.ninja")


def test_unauthorized_legacy_tv():
    from apps import unauthorized
    assert unauthorized("failed to authenticate to 192.168.1.11:5555")
    assert not unauthorized("connected to 192.168.1.11:5555")


def test_recents_from_a_real_chromecast():
    from pathlib import Path
    from apps import parse_recents
    sample = (Path(__file__).parent / "recents_sample.txt").read_text()
    recents = parse_recents(sample)
    packages = [r["package"] for r in recents]
    assert packages, "the sample has recent apps"
    assert len(packages) == len(set(packages))  # one card per app
    assert "com.android.systemui" not in packages and "com.google.android.apps.tv.launcherx" not in packages
    # YouTube's task affinity is com.google.android.youtube.tv.main; the package must be the real one
    assert all(not p.endswith(".main") for p in packages)
    inactive = [r["inactive"] for r in recents if r["inactive"] is not None]
    assert inactive == sorted(inactive)  # newest first


def test_recents_details():
    from pathlib import Path
    from apps import parse_recents
    recents = parse_recents((Path(__file__).parent / "recents_sample.txt").read_text())
    assert recents == [
        {"package": "com.google.android.youtube.tv", "inactive": 60, "live": True},
        {"package": "com.example.player", "inactive": 600, "live": False},
    ]
    assert parse_recents((Path(__file__).parent / "recents_sample.txt").read_text(),
                         frozenset({"com.example.player"}))[-1]["package"] == "com.google.android.youtube.tv"


def test_task_ids_for_close():
    from pathlib import Path
    from apps import parse_task_ids
    sample = (Path(__file__).parent / "recents_sample.txt").read_text()
    assert parse_task_ids(sample, "com.example.player") == [103, 104]
    assert parse_task_ids(sample, "com.google.android.youtube.tv") == [101]
    assert parse_task_ids(sample, "com.google.android.apps.tv.launcherx") == []  # home is never removed
    assert parse_task_ids(sample, "com.missing.app") == []


def _ready_manager(answers):
    import apps
    manager = apps.AppsManager(lambda: None)
    manager.status = apps.AppsStatus.READY
    manager._serial = "192.0.2.5:5555"

    async def fake_adb(*args, timeout=apps.COMMAND_TIMEOUT_SECONDS):
        answer = answers[args[-1]]
        if isinstance(answer, Exception):
            raise answer
        return answer

    manager._adb = fake_adb
    return manager


def test_a_slow_command_keeps_the_link():
    import asyncio
    import apps
    manager = _ready_manager({"pm trim-caches 999G": apps.AppsTimeout("slow"), "get-state": "device\n"})
    with pytest.raises(AppsError, match="still working"):
        asyncio.run(manager.shell("pm trim-caches 999G"))
    assert manager.status == apps.AppsStatus.READY and not manager.link_dropped


def test_a_gone_tv_drops_the_link():
    import asyncio
    import apps
    manager = _ready_manager({"pm trim-caches 999G": apps.AppsTimeout("slow"), "get-state": "error: device offline\n"})
    with pytest.raises(AppsError, match="Lost the connection"):
        asyncio.run(manager.shell("pm trim-caches 999G"))
    assert manager.status == apps.AppsStatus.UNKNOWN and manager.link_dropped


def test_install_notices_a_lost_device():
    import asyncio
    import apps
    manager = _ready_manager({"/x.apk": "adb: device offline\n"})
    with pytest.raises(AppsError, match="Lost the connection"):
        asyncio.run(manager.device_command("install", "-r", "/x.apk", timeout=5))
