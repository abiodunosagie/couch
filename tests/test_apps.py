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
