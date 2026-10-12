"""Installed apps on the TV: list, open and uninstall, over ADB (Android debugging).

The remote protocol cannot list, open by name or remove apps. Android's debug bridge can,
once the user turns on USB debugging in the TV's Developer options and allows this Mac
the first time it connects (the TV shows a prompt). The bridge gives full control of the
TV, so this module only runs a few fixed commands, every argument is checked against a
strict pattern and shell quoted, and uninstall is limited to apps the user installed
(`pm list packages -3`), never system apps.

ADB runs on its own thread with the blocking client: the async client spins without
yielding when the TV drops the socket, which would freeze the whole helper.
"""

from __future__ import annotations

import asyncio
import enum
import logging
import os
import re
import shlex
import threading
from collections.abc import Callable

from adb_shell.adb_device import AdbDeviceTcp
from adb_shell.auth.keygen import keygen
from adb_shell.auth.sign_cryptography import CryptographySigner
from adb_shell.exceptions import DeviceAuthError, TcpTimeoutException

from tv import CONFIG_DIR, ensure_config_dir

ADB_PORT = 5555
KEY_FILE = CONFIG_DIR / "adbkey"
PUBLIC_KEY_FILE = CONFIG_DIR / "adbkey.pub"
# The TV shows "Allow USB debugging?" and waits for the user; give them time to answer.
AUTH_TIMEOUT_SECONDS = 90.0
COMMAND_TIMEOUT_SECONDS = 15.0
READ_TIMEOUT_SECONDS = 3.0
PORT_CHECK_SECONDS = 1.5
MAX_PACKAGE_LENGTH = 200
# An Android package name: letters, digits and underscores in dot separated parts.
PACKAGE_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+")
# A launchable component as printed by resolve-activity: package/activity.
COMPONENT = re.compile(r"[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.$]+")
PACKAGE_PREFIX = "package:"

log = logging.getLogger("tvremote.apps")


class AppsStatus(enum.StrEnum):
    """Matches AppsLink in the Mac app."""

    UNKNOWN = "unknown"  # not tried yet, or the link dropped
    OFF = "off"  # debugging is not on (port closed)
    WAITING = "waiting"  # the TV is asking the user to allow this Mac
    READY = "ready"
    DENIED = "denied"  # the user said no, or nobody answered in time


class AppsError(Exception):
    """A failure with a message fit to show the user."""


def check_package(package: object) -> str:
    if not isinstance(package, str) or len(package) > MAX_PACKAGE_LENGTH or not PACKAGE_NAME.fullmatch(package):
        raise AppsError("That is not an app name.")
    return package


def _parse_packages(output: str) -> list[str]:
    names = (line.removeprefix(PACKAGE_PREFIX).strip() for line in output.splitlines() if line.startswith(PACKAGE_PREFIX))
    return sorted(name for name in names if PACKAGE_NAME.fullmatch(name))


def _signer() -> CryptographySigner:
    ensure_config_dir()
    # An empty key is a key generation that was cut off; make a new one.
    if not KEY_FILE.exists() or KEY_FILE.stat().st_size == 0:
        # Create both files owner-only first; keygen then writes into them and keeps the mode.
        for path in (KEY_FILE, PUBLIC_KEY_FILE):
            os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
        keygen(str(KEY_FILE))
    for path in (KEY_FILE, PUBLIC_KEY_FILE):
        if path.exists():
            os.chmod(path, 0o600)
    return CryptographySigner(str(KEY_FILE))


class AppsManager:
    """One ADB connection to the TV, opened on demand. Every call runs on a worker thread."""

    def __init__(self, on_status: Callable[[], None]) -> None:
        self.status = AppsStatus.UNKNOWN
        self._on_status = on_status
        self._device: AdbDeviceTcp | None = None
        self._host: str | None = None
        self._thread_lock = threading.Lock()
        self._connecting: asyncio.Task[None] | None = None
        self._installed: set[str] = set()

    def _set(self, status: AppsStatus) -> None:
        if status != self.status:
            self.status = status
            self._on_status()

    # ------------------------------------------------------------ connection

    def connect(self, host: str) -> None:
        """Start connecting unless an attempt is already running (the TV prompt can take a minute)."""
        if self._connecting and not self._connecting.done():
            self._on_status()  # just repeat the current state
            return
        self._connecting = asyncio.get_running_loop().create_task(self._connect(host))

    async def _connect(self, host: str) -> None:
        if self.status == AppsStatus.READY and self._host == host and self._device and self._device.available:
            self._on_status()
            return
        if not await self._port_open(host):
            self._set(AppsStatus.OFF)
            return
        self._set(AppsStatus.WAITING)
        status = await asyncio.to_thread(self._connect_blocking, host)
        self._set(status)

    def _connect_blocking(self, host: str) -> AppsStatus:
        with self._thread_lock:
            self._close_blocking()
            device = AdbDeviceTcp(host, ADB_PORT, default_transport_timeout_s=COMMAND_TIMEOUT_SECONDS)
            try:
                device.connect(rsa_keys=[_signer()], auth_timeout_s=AUTH_TIMEOUT_SECONDS,
                               transport_timeout_s=AUTH_TIMEOUT_SECONDS, read_timeout_s=AUTH_TIMEOUT_SECONDS)
            except (DeviceAuthError, TcpTimeoutException):
                log.info("adb: the TV did not allow this Mac")
                self._safe_close(device)
                return AppsStatus.DENIED
            except Exception as exc:  # any protocol or socket failure: report it, never leave "waiting"
                log.info("adb connect failed: %r", exc)
                self._safe_close(device)
                return AppsStatus.OFF
            self._device = device
            if host != self._host:
                self._installed = set()  # a different TV: its list is unknown until listed
            self._host = host
            return AppsStatus.READY

    @staticmethod
    async def _port_open(host: str) -> bool:
        try:
            _, writer = await asyncio.wait_for(asyncio.open_connection(host, ADB_PORT), PORT_CHECK_SECONDS)
        except (OSError, TimeoutError):
            return False
        writer.close()
        try:
            await writer.wait_closed()
        except OSError:
            pass
        return True

    @staticmethod
    def _safe_close(device: AdbDeviceTcp) -> None:
        try:
            device.close()
        except Exception:  # closing a dead link must not hide the real error
            pass

    def _close_blocking(self) -> None:
        if self._device:
            self._safe_close(self._device)
            self._device = None

    async def close(self) -> None:
        if self._connecting:
            self._connecting.cancel()
        await asyncio.to_thread(lambda: self._with_lock(self._close_blocking))

    def _with_lock(self, work: Callable[[], object]) -> object:
        with self._thread_lock:
            return work()

    # ------------------------------------------------------------ commands

    async def _shell(self, *commands: str) -> list[str]:
        """Run commands in order on the worker thread; any failure marks the link as down."""

        def run() -> list[str]:
            with self._thread_lock:
                if not self._device or not self._device.available:
                    raise AppsError("Couch is not connected to the TV's app manager.")
                results = []
                for command in commands:
                    output = self._device.shell(command, timeout_s=COMMAND_TIMEOUT_SECONDS,
                                                read_timeout_s=READ_TIMEOUT_SECONDS)
                    results.append(output if isinstance(output, str) else "")
                return results

        try:
            return await asyncio.to_thread(run)
        except AppsError:
            # Not connected: only a link that was up is now down; "off" and "denied" stay as they are.
            if self.status == AppsStatus.READY:
                self._set(AppsStatus.UNKNOWN)
            raise
        except Exception as exc:
            log.info("adb command failed: %r", exc)
            await asyncio.to_thread(lambda: self._with_lock(self._close_blocking))
            self._set(AppsStatus.UNKNOWN)
            raise AppsError("Lost the connection to the TV's app manager. Open Apps to reconnect.") from None

    async def installed(self) -> list[str]:
        """Apps the user installed (not system apps), sorted by package name."""
        (output,) = await self._shell("pm list packages -3")
        packages = _parse_packages(output)
        self._installed = set(packages)
        return packages

    async def launch(self, package: object) -> None:
        name = check_package(package)
        (resolved,) = await self._shell(
            f"cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER {shlex.quote(name)}")
        lines = resolved.strip().splitlines()
        target = lines[-1].strip() if lines else ""
        if COMPONENT.fullmatch(target):
            (result,) = await self._shell(f"am start -n {shlex.quote(target)}")
            if result.lstrip().startswith("Starting:") and not re.search(r"^Error", result, re.MULTILINE):
                return
        # No TV launcher entry; ask Android to start it any way it can.
        (result,) = await self._shell(f"monkey -p {shlex.quote(name)} -c android.intent.category.LAUNCHER 1")
        if not re.search(r"^Events injected: 1\b", result, re.MULTILINE):
            raise AppsError("That app has no screen to open.")

    async def uninstall(self, package: object) -> None:
        name = check_package(package)
        if name not in self._installed:
            raise AppsError("Couch only removes apps you installed.")
        (result,) = await self._shell(f"pm uninstall --user 0 {shlex.quote(name)}")
        if not result.strip().startswith("Success"):
            log.info("uninstall %s: %s", name, result.strip()[:200])
            raise AppsError("The TV did not remove that app.")
        self._installed.discard(name)
