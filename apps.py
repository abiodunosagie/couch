"""Installed apps on the TV: list, open and uninstall, through Google's `adb` tool.

The remote protocol cannot list, open by name or remove apps. Android's debug bridge can.
Newer Google TV builds only offer it as Wireless debugging: a TLS connection on a port that
changes with every restart, opened once with a 6 digit pairing code the TV shows. Older
builds listen on port 5555 and ask the user to allow the Mac on screen. Google's `adb`
handles both (adb-shell, the Python client used before, cannot pair).

The bridge gives full control of the TV, so this module only runs a few fixed commands with
an argument list (no local shell), every value going into the TV's shell is checked against a
strict pattern and quoted, and uninstall is limited to apps the user installed
(`pm list packages -3`), never system apps.
"""

from __future__ import annotations

import asyncio
import enum
import logging
import re
import shlex
import shutil
from collections.abc import Callable
from typing import TypeGuard
from pathlib import Path

from tv import CONFIG_DIR, ensure_config_dir
from zeroconf import ServiceStateChange
from zeroconf.asyncio import AsyncServiceBrowser, AsyncServiceInfo, AsyncZeroconf

LEGACY_PORT = 5555
CONNECT_SERVICE = "_adb-tls-connect._tcp.local."
PAIRING_SERVICE = "_adb-tls-pairing._tcp.local."
DISCOVERY_SECONDS = 3.0
# The pairing screen's service can take several seconds to show on the network.
PAIRING_DISCOVERY_SECONDS = 10.0
RESOLVE_TIMEOUT_MS = 3000
PORT_CHECK_SECONDS = 1.5
CONNECT_TIMEOUT_SECONDS = 15.0
PAIR_TIMEOUT_SECONDS = 30.0
COMMAND_TIMEOUT_SECONDS = 15.0
# On a port 5555 TV, the "Allow USB debugging?" prompt waits for the user.
ALLOW_WAIT_SECONDS = 90.0
ALLOW_POLL_SECONDS = 1.0
# Right after pairing the TV can take a moment to advertise its connect port.
CONNECT_ATTEMPTS_AFTER_PAIRING = 4
LOG_SNIPPET_CHARS = 200
MAX_PACKAGE_LENGTH = 200
# Where Homebrew and Android Studio put adb; the app starts from launchd with a bare PATH.
ADB_LOCATIONS = (
    "/opt/homebrew/bin/adb",
    "/usr/local/bin/adb",
    str(Path.home() / "Library/Android/sdk/platform-tools/adb"),
)
# An Android package name: letters, digits and underscores in dot separated parts.
PACKAGE_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+")
# A launchable component as printed by resolve-activity: package/activity.
COMPONENT = re.compile(r"[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.$]+")
PAIRING_CODE = re.compile(r"\d{6}")
HOST_PORT = re.compile(r"(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})")
PACKAGE_PREFIX = "package:"
# Set once the app manager has worked; from then on Couch reconnects by itself.
LINKED_FILE = CONFIG_DIR / "apps_linked"

log = logging.getLogger("tvremote.apps")


class AppsStatus(enum.StrEnum):
    """Matches AppsLink in the Mac app."""

    UNKNOWN = "unknown"  # not tried yet, or the link dropped
    NO_ADB = "no_adb"  # Google's adb tool is not installed on this Mac
    OFF = "off"  # debugging is not on on the TV
    NEEDS_PAIRING = "needs_pairing"  # Wireless debugging is on; pair once with the TV's code
    PAIRING = "pairing"
    WAITING = "waiting"  # the TV is asking the user to allow this Mac
    READY = "ready"
    DENIED = "denied"  # the user said no, or the code was wrong


class AppsError(Exception):
    """A failure with a message fit to show the user."""


class AppsTimeout(AppsError):
    """adb gave up waiting. The TV may only be slow, so this alone does not mean the link is gone."""


def is_package(package: object) -> TypeGuard[str]:
    return isinstance(package, str) and len(package) <= MAX_PACKAGE_LENGTH and PACKAGE_NAME.fullmatch(package) is not None


def check_package(package: object) -> str:
    if not is_package(package):
        raise AppsError("That is not an app name.")
    return package


def parse_packages(output: str) -> list[str]:
    names = (line.removeprefix(PACKAGE_PREFIX).strip() for line in output.splitlines() if line.startswith(PACKAGE_PREFIX))
    return sorted(name for name in names if PACKAGE_NAME.fullmatch(name))


def connected(output: str) -> bool:
    """`adb connect` output: "connected to h:p" or "already connected to h:p" means up. adb may
    print "* daemon started successfully" lines first, so look at every line."""
    return re.search(r"^(already )?connected to", output, re.MULTILINE | re.IGNORECASE) is not None


def unauthorized(output: str) -> bool:
    """A port 5555 TV that has not allowed this Mac yet."""
    text = output.lower()
    return "failed to authenticate" in text or "unauthorized" in text


def last_line(output: str) -> str:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def lost_device(output: str) -> bool:
    """adb's own errors when the TV is gone, as opposed to a command's output."""
    return re.search(r"^(error: |adb: (device|no devices))", output, re.MULTILINE) is not None


def paired(output: str) -> bool:
    """`adb pair` output on success: "Successfully paired to h:p [guid=...]"."""
    return "successfully paired" in output.lower()


# System parts that show up as recent tasks but are not apps to switch to.
NOT_RECENT_APPS = frozenset({
    "com.android.systemui", "com.google.android.packageinstaller", "com.google.android.apps.tv.dreamx",
    "com.google.android.apps.tv.launcherx", "com.google.android.tvlauncher", "com.google.android.katniss",
})
MAX_RECENTS = 12


def parse_recents(output: str, hidden: frozenset[str] = frozenset()) -> list[dict]:
    """Recent tasks from `dumpsys activity recents`, newest first, one per app.

    Each block has the package in mActivityComponent (the "A=" field is the task affinity,
    which can differ, like com.google.android.youtube.tv.main), and "inactive for Ns".
    "live" is whether the app still runs (Activities listed); otherwise opening it starts fresh.
    """
    recents: list[dict] = []
    seen: set[str] = set()
    for block in output.split("* Recent #")[1:]:
        if "type=standard" not in block.split("\n", 1)[0]:
            continue
        component = re.search(r"mActivityComponent=([A-Za-z0-9_.]+)/", block)
        if not component:
            continue
        package = component.group(1)
        if package in seen or package in NOT_RECENT_APPS or package in hidden or not is_package(package):
            continue
        seen.add(package)
        inactive = re.search(r"inactive for (\d+)s", block)
        recents.append({
            "package": package,
            "inactive": int(inactive.group(1)) if inactive else None,
            "live": "Activities=[ActivityRecord" in block,
        })
        if len(recents) >= MAX_RECENTS:
            break
    return recents


def parse_task_ids(output: str, package: str) -> list[int]:
    """Every recent task id of `package` in `dumpsys activity recents`, so Close can clear them all."""
    ids: list[int] = []
    for block in output.split("* Recent #")[1:]:
        header = re.match(r"\d+: Task\{\w+ #(\d+) type=standard", block)
        component = re.search(r"mActivityComponent=([A-Za-z0-9_.]+)/", block)
        if header and component and component.group(1) == package:
            ids.append(int(header.group(1)))
    return ids


def find_adb() -> str | None:
    for path in ADB_LOCATIONS:
        if Path(path).is_file():
            return path
    return shutil.which("adb")


async def _find_service(service: str, host: str, seconds: float = DISCOVERY_SECONDS) -> int | None:
    """The port the TV at `host` advertises for an adb service, if it does right now."""
    names: list[str] = []

    def on_change(zeroconf, service_type, name, state_change):  # noqa: ARG001
        # zeroconf calls handlers with these exact keyword names.
        if state_change is ServiceStateChange.Added:
            names.append(name)

    aiozc = AsyncZeroconf()
    browser = AsyncServiceBrowser(aiozc.zeroconf, service, handlers=[on_change])
    checked: set[str] = set()
    loop = asyncio.get_running_loop()
    deadline = loop.time() + seconds
    try:
        # Answer as soon as the TV's service shows up instead of always waiting the full time.
        while loop.time() < deadline:
            for name in [n for n in names if n not in checked]:
                checked.add(name)
                info = AsyncServiceInfo(service, name)
                if await info.async_request(aiozc.zeroconf, RESOLVE_TIMEOUT_MS) and host in info.parsed_addresses():
                    return info.port
            await asyncio.sleep(0.2)
        return None
    finally:
        await browser.async_cancel()
        await aiozc.async_close()


async def _port_open(host: str, port: int) -> bool:
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), PORT_CHECK_SECONDS)
    except (OSError, TimeoutError):
        return False
    writer.close()
    try:
        await writer.wait_closed()
    except OSError:
        pass
    return True


class AppsManager:
    """The TV's app manager over adb, connected on demand."""

    def __init__(self, on_status: Callable[[], None]) -> None:
        self.status = AppsStatus.UNKNOWN
        self.message = ""  # why the last connect or pairing failed, for the Mac app
        self._on_status = on_status
        self._serial: str | None = None  # host:port adb talks to
        self._host: str | None = None
        self._task: asyncio.Task[None] | None = None
        self._lock = asyncio.Lock()  # one adb command at a time
        self._installed: set[str] = set()
        self._server_started = False
        # True when a link worked before (this run or an earlier one) and is not up now, as after a
        # TV restart: only then does Couch reconnect by itself. A refusal or a missing pairing waits
        # for the user.
        self.link_dropped = self.was_linked()

    @staticmethod
    def was_linked() -> bool:
        """True once this Mac has been paired and connected; adb keeps the pairing in ~/.android."""
        return LINKED_FILE.exists()

    def _set(self, status: AppsStatus, message: str = "") -> None:
        if status == AppsStatus.READY:
            self.link_dropped = False
            if not LINKED_FILE.exists():
                ensure_config_dir()
                LINKED_FILE.touch(mode=0o600)
        if status != self.status or message != self.message:
            self.status = status
            self.message = message
            self._on_status()

    # ------------------------------------------------------------ adb

    async def _adb(self, *args: str, timeout: float = COMMAND_TIMEOUT_SECONDS) -> str:
        """Run adb with an argument list (never a local shell) and return its output."""
        adb = find_adb()
        if adb is None:
            self._set(AppsStatus.NO_ADB)
            raise AppsError("Google's adb tool is not installed. See the steps in Apps.")
        if not self._server_started:
            # Start adb's background server first, so its start up lines never mix into an answer.
            await self._exec(adb, "start-server", timeout=CONNECT_TIMEOUT_SECONDS)
            self._server_started = True
        return await self._exec(adb, *args, timeout=timeout)

    @staticmethod
    async def _exec(*args: str, timeout: float) -> str:
        process = await asyncio.create_subprocess_exec(
            *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        try:
            output, _ = await asyncio.wait_for(process.communicate(), timeout)
        except BaseException as exc:
            # Timed out or cancelled: never leave an adb process behind.
            if process.returncode is None:
                process.kill()
                await process.wait()
            if isinstance(exc, TimeoutError):
                raise AppsTimeout("The TV did not answer in time.") from None
            raise
        return output.decode(errors="replace")

    # ------------------------------------------------------------ connection

    def busy(self) -> bool:
        return self._task is not None and not self._task.done()

    def connect(self, host: str) -> None:
        """Start connecting unless an attempt is already running."""
        if self.busy():
            self._on_status()  # just repeat the current state
            return
        self._task = asyncio.get_running_loop().create_task(self._run(self._connect(host)))

    def pair(self, host: str, code: object, address: object = None) -> None:
        """Pair with the 6 digit code the TV shows, then connect. `address` is the h:p the TV
        shows, for when the pairing service cannot be found on the network."""
        if not isinstance(code, str) or not PAIRING_CODE.fullmatch(code.strip()):
            raise AppsError("The pairing code is the 6 digits the TV shows.")
        manual = None
        if isinstance(address, str) and address.strip():
            match = HOST_PORT.fullmatch(address.strip())
            if not match or match.group(1) != host:
                raise AppsError(f"Type the address as the TV shows it, like {host}:37000.")
            manual = int(match.group(2))
        if self.busy():
            raise AppsError("Couch is still talking to the TV. Try again in a moment.")
        self._task = asyncio.get_running_loop().create_task(self._run(self._pair(host, code.strip(), manual)))

    async def _run(self, work) -> None:
        try:
            await work
        except AppsError as exc:
            log.info("apps: %s", exc)
            # Always end on a state the user can act on, never on "pairing" or "unknown".
            settled = {AppsStatus.PAIRING: AppsStatus.NEEDS_PAIRING, AppsStatus.UNKNOWN: AppsStatus.OFF,
                       AppsStatus.WAITING: AppsStatus.OFF}.get(self.status, self.status)
            self._set(settled, str(exc))
        except Exception:
            log.exception("apps connection failed")
            self._set(AppsStatus.OFF, "Something went wrong talking to the TV. Try again.")

    async def _connect(self, host: str, attempts: int = 1) -> None:
        if find_adb() is None:
            self._set(AppsStatus.NO_ADB)
            return
        self._host = host
        for _ in range(attempts):
            port = await _find_service(CONNECT_SERVICE, host)
            if port is not None:
                await self._connect_to(f"{host}:{port}", wireless=True)
                return
            if await _port_open(host, LEGACY_PORT):
                await self._connect_to(f"{host}:{LEGACY_PORT}", wireless=False)
                return
        self._set(AppsStatus.OFF, "Couch could not find debugging on the TV. Check Wireless debugging is on.")

    async def _connect_to(self, serial: str, wireless: bool) -> None:
        async with self._lock:
            output = await self._adb("connect", serial, timeout=CONNECT_TIMEOUT_SECONDS)
        if not connected(output) and not (not wireless and unauthorized(output)):
            log.info("adb connect %s: %s", serial, output.strip()[:LOG_SNIPPET_CHARS])
            # A wireless debugging TV refuses a Mac it has not paired with.
            self._set(AppsStatus.NEEDS_PAIRING if wireless else AppsStatus.OFF)
            return
        if serial != self._serial:
            self._installed = set()
        self._serial = serial
        await self._wait_until_allowed(serial)

    async def _wait_until_allowed(self, serial: str) -> None:
        """A port 5555 TV shows "Allow USB debugging?"; wait for the answer."""
        loop = asyncio.get_running_loop()
        deadline = loop.time() + ALLOW_WAIT_SECONDS
        while True:
            async with self._lock:
                state = last_line(await self._adb("-s", serial, "get-state"))
            if state == "device":
                self._set(AppsStatus.READY)
                return
            if "unauthorized" not in state or loop.time() > deadline:
                self._set(AppsStatus.DENIED if "unauthorized" in state else AppsStatus.OFF)
                return
            self._set(AppsStatus.WAITING)
            await asyncio.sleep(ALLOW_POLL_SECONDS)

    async def _pair(self, host: str, code: str, manual_port: int | None) -> None:
        self._set(AppsStatus.PAIRING)
        port = manual_port or await _find_service(PAIRING_SERVICE, host, PAIRING_DISCOVERY_SECONDS)
        if port is None:
            self._set(AppsStatus.NEEDS_PAIRING,
                      "Couch could not find the pairing screen. Keep it open on the TV, or type the address it shows.")
            return
        async with self._lock:
            output = await self._adb("pair", f"{host}:{port}", code, timeout=PAIR_TIMEOUT_SECONDS)
        if not paired(output):
            log.info("adb pair: %s", output.strip()[:LOG_SNIPPET_CHARS])
            self._set(AppsStatus.NEEDS_PAIRING, "The TV did not accept that code. Check it and try again.")
            return
        self._set(AppsStatus.PAIRING, "Paired. Connecting to the TV…")
        await self._connect(host, attempts=CONNECT_ATTEMPTS_AFTER_PAIRING)

    async def close(self) -> None:
        if self._task:
            self._task.cancel()

    # ------------------------------------------------------------ commands

    async def shell(self, *commands: str, timeout: float = COMMAND_TIMEOUT_SECONDS) -> list[str]:
        """Run TV shell commands in order. Callers must check and quote every value."""
        return await self._on_tv_many([("shell", command) for command in commands], timeout)

    async def device_command(self, *args: str, timeout: float) -> str:
        """An adb command addressed to the TV (install), for tv_tools.py."""
        return await self._on_tv(args, timeout)

    async def _on_tv(self, args: tuple[str, ...], timeout: float) -> str:
        (output,) = await self._on_tv_many([args], timeout)
        return output

    async def _on_tv_many(self, commands: list[tuple[str, ...]], timeout: float) -> list[str]:
        """Run adb commands addressed to the TV, one at a time under the lock.

        adb's own errors ("error: device offline") mean the link is gone. A timeout alone does
        not: Free Up Space or an install can be slow, so ask the TV whether it is still there.
        """
        results = []
        async with self._lock:
            # Checked under the lock: a command that waited behind an install must not use a link
            # that dropped, or an old port, meanwhile.
            if self.status != AppsStatus.READY or not self._serial:
                raise AppsError("Couch is not connected to the TV's app manager.")
            serial = self._serial
            try:
                for args in commands:
                    results.append(await self._adb("-s", serial, *args, timeout=timeout))
            except AppsTimeout:
                if await self._still_there(serial):
                    raise AppsError("The TV took too long to answer. Try again.") from None
                self._link_lost()
            except AppsError:
                self._link_lost()
        if any(lost_device(result) for result in results):
            self._link_lost()
        return results

    async def _still_there(self, serial: str) -> bool:
        try:
            return last_line(await self._adb("-s", serial, "get-state")) == "device"
        except AppsError:
            return False

    def _link_lost(self) -> None:
        self.link_dropped = True
        self._set(AppsStatus.UNKNOWN)
        raise AppsError("Lost the connection to the TV's app manager. Open Apps to reconnect.")

    async def installed(self) -> list[str]:
        """Apps the user installed (not system apps), sorted by package name."""
        (output,) = await self.shell("pm list packages -3")
        packages = parse_packages(output)
        self._installed = set(packages)
        return packages

    async def launch(self, package: object) -> None:
        name = check_package(package)
        (resolved,) = await self.shell(
            f"cmd package resolve-activity --brief -c android.intent.category.LEANBACK_LAUNCHER {shlex.quote(name)}")
        lines = resolved.strip().splitlines()
        target = lines[-1].strip() if lines else ""
        if COMPONENT.fullmatch(target):
            # The same intent the home screen sends, so a paused app comes back where it was.
            (result,) = await self.shell(
                "am start -a android.intent.action.MAIN -c android.intent.category.LEANBACK_LAUNCHER "
                f"-f 0x10200000 -n {shlex.quote(target)}")
            if result.lstrip().startswith("Starting:") and not re.search(r"^Error", result, re.MULTILINE):
                return
        # No TV launcher entry; ask Android to start it any way it can.
        (result,) = await self.shell(f"monkey -p {shlex.quote(name)} -c android.intent.category.LAUNCHER 1")
        if not re.search(r"^Events injected: 1\b", result, re.MULTILINE):
            raise AppsError("That app has no screen to open.")

    async def recents(self, hidden: frozenset[str] = frozenset()) -> list[dict]:
        (output,) = await self.shell("dumpsys activity recents")
        return parse_recents(output, hidden)

    async def close_app(self, package: object) -> None:
        """Stop an app, free its memory and take it off the recent list. It stays installed."""
        name = check_package(package)
        (_, output) = await self.shell(f"am force-stop {shlex.quote(name)}", "dumpsys activity recents")
        # force-stop leaves the app's card in the TV's recents; removing its tasks clears it.
        tasks = parse_task_ids(output, name)
        if tasks:
            await self.shell(*(f"am stack remove {task}" for task in tasks))

    async def open_settings(self) -> None:
        """The TV's main Settings in one step (the remote's Settings key does nothing on Google TV)."""
        (result,) = await self.shell("am start -a android.settings.SETTINGS")
        if not result.lstrip().startswith("Starting:"):
            raise AppsError("The TV did not open Settings.")

    async def uninstall(self, package: object) -> None:
        name = check_package(package)
        if name not in self._installed:
            raise AppsError("Couch only removes apps you installed.")
        (result,) = await self.shell(f"pm uninstall --user 0 {shlex.quote(name)}")
        if not result.strip().startswith("Success"):
            log.info("uninstall %s: %s", name, result.strip()[:LOG_SNIPPET_CHARS])
            raise AppsError("The TV did not remove that app.")
        self._installed.discard(name)
