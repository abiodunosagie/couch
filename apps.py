"""Installed apps on the TV: list, open and uninstall, over ADB (Android debugging).

The remote protocol cannot list, open by name or remove apps. Android's debug bridge can,
once the user turns on USB debugging in the TV's Developer options and allows this Mac
the first time it connects (the TV shows a prompt). The bridge gives full control of the
TV, so this module only ever runs three fixed commands, and every package name is checked
against a strict pattern before it goes into one. Uninstall is limited to apps the user
installed (`pm list packages -3`), never system apps.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import socket

from adb_shell.adb_device_async import AdbDeviceTcpAsync
from adb_shell.auth.keygen import keygen
from adb_shell.auth.sign_cryptography import CryptographySigner
from adb_shell.exceptions import AdbConnectionError, AdbTimeoutError, DeviceAuthError, TcpTimeoutException

from tv import CONFIG_DIR, ensure_config_dir

ADB_PORT = 5555
KEY_FILE = CONFIG_DIR / "adbkey"
# The TV shows "Allow USB debugging?" and waits for the user; give them time to answer.
AUTH_TIMEOUT_SECONDS = 90.0
COMMAND_TIMEOUT_SECONDS = 15.0
PORT_CHECK_SECONDS = 1.5
# An Android package name: letters, digits and underscores in dot separated parts.
PACKAGE_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+")
# A launchable component as printed by resolve-activity: package/activity.
COMPONENT = re.compile(r"[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.$]+")

log = logging.getLogger("tvremote.apps")


class AppsError(Exception):
    """A failure with a message fit to show the user."""


def check_package(package: object) -> str:
    if not isinstance(package, str) or len(package) > 200 or not PACKAGE_NAME.fullmatch(package):
        raise AppsError("That is not an app name.")
    return package


class AppsManager:
    """One ADB connection to the TV, opened on demand."""

    # off: debugging is not on (port closed). waiting: the TV is asking the user to allow
    # this Mac. ready: connected. denied: the user said no, or the prompt timed out.
    def __init__(self) -> None:
        self.status = "unknown"
        self._host: str | None = None
        self._device: AdbDeviceTcpAsync | None = None
        self._lock = asyncio.Lock()
        self._installed: set[str] = set()

    def _signer(self) -> CryptographySigner:
        ensure_config_dir()
        if not KEY_FILE.exists():
            previous = os.umask(0o077)
            try:
                keygen(str(KEY_FILE))
            finally:
                os.umask(previous)
        for path in (KEY_FILE, KEY_FILE.with_name(KEY_FILE.name + ".pub")):
            if path.exists():
                os.chmod(path, 0o600)
        return CryptographySigner(str(KEY_FILE))

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

    async def connect(self, host: str, on_status) -> None:
        """Connect, reporting each state through `on_status` (the TV prompt can take a while)."""
        async with self._lock:
            if self._device and self._device.available and self._host == host:
                return
            await self._close()
            self._host = host
            if not await self._port_open(host):
                self._set("off", on_status)
                return
            self._set("waiting", on_status)
            device = AdbDeviceTcpAsync(host, ADB_PORT, default_transport_timeout_s=COMMAND_TIMEOUT_SECONDS)
            try:
                signer = await asyncio.get_running_loop().run_in_executor(None, self._signer)
                await device.connect(rsa_keys=[signer], auth_timeout_s=AUTH_TIMEOUT_SECONDS)
            except DeviceAuthError:
                self._set("denied", on_status)
                return
            except (AdbConnectionError, AdbTimeoutError, TcpTimeoutException, OSError, socket.timeout) as exc:
                log.info("adb connect failed: %r", exc)
                self._set("denied" if isinstance(exc, AdbTimeoutError) else "off", on_status)
                return
            self._device = device
            self._set("ready", on_status)

    def _set(self, status: str, on_status) -> None:
        self.status = status
        on_status()

    async def _close(self) -> None:
        if self._device:
            try:
                await self._device.close()
            except Exception:  # closing a dead link must not stop a reconnect
                pass
            self._device = None

    async def close(self) -> None:
        async with self._lock:
            await self._close()

    async def _shell(self, command: str) -> str:
        if not self._device or not self._device.available:
            raise AppsError("Couch is not connected to the TV's app manager.")
        try:
            output = await self._device.shell(command, timeout_s=COMMAND_TIMEOUT_SECONDS)
        except (AdbConnectionError, AdbTimeoutError, TcpTimeoutException, OSError) as exc:
            log.info("adb command failed: %r", exc)
            await self._close()
            self.status = "unknown"
            raise AppsError("Lost the connection to the TV's app manager.") from None
        return output if isinstance(output, str) else ""

    # ------------------------------------------------------------ commands

    async def installed(self) -> list[str]:
        """Apps the user installed (not system apps), sorted by package name."""
        async with self._lock:
            output = await self._shell("pm list packages -3")
        packages = sorted(
            line.removeprefix("package:").strip()
            for line in output.splitlines()
            if line.startswith("package:") and PACKAGE_NAME.fullmatch(line.removeprefix("package:").strip())
        )
        self._installed = set(packages)
        return packages

    async def launch(self, package: object) -> None:
        name = check_package(package)
        async with self._lock:
            component = (await self._shell(
                f"cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER {name}"
            )).strip().splitlines()
            target = component[-1].strip() if component else ""
            if COMPONENT.fullmatch(target):
                result = await self._shell(f"am start -n {target}")
                if "Error" not in result:
                    return
            # No TV launcher entry; ask Android to start it any way it can.
            result = await self._shell(f"monkey -p {name} -c android.intent.category.LAUNCHER 1")
        if "No activities found" in result or "aborted" in result:
            raise AppsError("That app has no screen to open.")

    async def uninstall(self, package: object) -> None:
        name = check_package(package)
        if name not in self._installed:
            # Only apps from the last list of user installed apps; never system apps.
            raise AppsError("Couch only removes apps you installed.")
        async with self._lock:
            result = (await self._shell(f"pm uninstall --user 0 {name}")).strip()
        if not result.startswith("Success"):
            log.info("uninstall %s: %s", name, result[:200])
            raise AppsError("The TV did not remove that app.")
        self._installed.discard(name)
