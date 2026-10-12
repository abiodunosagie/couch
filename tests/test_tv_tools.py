"""TV upgrade helpers: parsing and the strict checks before anything reaches the TV."""

import pytest

from apps import AppsError
from tv_tools import TWEAKS, check_apk, install_result, parse_memory, parse_storage


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
    for namespace, key, choices in TWEAKS.values():
        assert namespace in {"global", "system", "secure"}
        assert all(value.replace(".", "").isdigit() for value in choices.values())
