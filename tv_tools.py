"""TV upgrades over the app manager: install apps from the Mac, tweaks Android hides, space and
memory, and choosing the home screen.

Every setting Couch can change is listed in TWEAKS with the only values it may take, and the
TV's own value is saved the first time Couch changes it, so Reset puts the TV back exactly.
"""

from __future__ import annotations

import json
import logging
import os
import re
import shlex
from pathlib import Path
from typing import NamedTuple

from apps import COMPONENT, AppsError, AppsManager, check_package, is_package
from tv import CONFIG_DIR, ensure_config_dir

log = logging.getLogger("tvremote.tools")

ORIGINALS_FILE = CONFIG_DIR / "tv_originals.json"
INSTALL_TIMEOUT_SECONDS = 600.0
# Android asks every app to drop its cache; on a full TV that takes a while.
FREE_SPACE_TIMEOUT_SECONDS = 180.0
MAX_APK_BYTES = 2 * 1024 ** 3
GOOGLE_HOME = "com.google.android.apps.tv.launcherx"
# A popular ad free home screen for Google TV; Couch opens its Play Store page, the user installs it.
SUGGESTED_HOME = "com.spocky.projengmenu"
HOME_RESOLVE = "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"
# What `settings get` prints for a setting the TV never stored, and Reset deletes again.
UNSET = "null"
NUMBER = re.compile(r"-?\d+(\.\d+)?")

MINUTE_MS = 60_000


class Tweak(NamedTuple):
    """A hidden TV setting: the only keys Couch writes and the only values they may take."""

    title: str
    namespace: str
    keys: tuple[str, ...]
    choices: tuple[tuple[str, str, str], ...]  # (choice, label, value written)

    def value(self, choice: object) -> str | None:
        return next((value for c, _label, value in self.choices if c == choice), None)

    def choice(self, value: str) -> str:
        """The choice the TV's current value matches, or "custom" for the TV's own value."""
        return next((c for c, _label, v in self.choices if _same(v, value)), "custom")


def _minutes(*counts: int) -> tuple[tuple[str, str, str], ...]:
    def label(count: int) -> str:
        return f"{count} min" if count < 60 else f"{count // 60} hour{'s' if count >= 120 else ''}"
    return tuple((str(count), label(count), str(count * MINUTE_MS)) for count in counts)


TWEAKS: dict[str, Tweak] = {
    # Animation speed is three settings that move together.
    "animations": Tweak("Animations", "global",
                        ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"),
                        (("normal", "Normal", "1.0"), ("fast", "Fast", "0.5"), ("off", "Off", "0"))),
    "screensaver_after": Tweak("Screensaver after", "system", ("screen_off_timeout",), _minutes(5, 10, 15, 30)),
    "sleep_after": Tweak("Turn off after", "secure", ("sleep_timeout",), _minutes(30, 60, 120, 240)),
}
# Every (namespace, key) Couch may ever write, also on Reset.
WRITABLE = frozenset(f"{tweak.namespace}/{key}" for tweak in TWEAKS.values() for key in tweak.keys)


def _valid_original(value: object) -> bool:
    return isinstance(value, str) and (value == UNSET or NUMBER.fullmatch(value) is not None)


def _load_originals() -> dict[str, str]:
    """Saved TV values, keeping only known keys with a plain number (or unset) as the value."""
    try:
        data = json.loads(ORIGINALS_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {entry: value for entry, value in data.items() if entry in WRITABLE and _valid_original(value)}


def _save_originals(originals: dict[str, str]) -> None:
    ensure_config_dir()
    fd = os.open(ORIGINALS_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(originals, out, indent=2)


def home_package(resolved: str) -> str | None:
    """The package in the last line of `resolve-activity --brief` (package/activity)."""
    lines = resolved.strip().splitlines()
    package = lines[-1].strip().split("/")[0] if lines else ""
    return package if is_package(package) else None


def parse_storage(df_output: str) -> dict[str, int] | None:
    """`df -k /data`: total and free space in bytes."""
    for line in df_output.splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[1].isdigit() and parts[3].isdigit():
            return {"total": int(parts[1]) * 1024, "free": int(parts[3]) * 1024}
    return None


def parse_memory(meminfo: str) -> dict[str, int] | None:
    values = dict(re.findall(r"^(MemTotal|MemAvailable):\s+(\d+) kB", meminfo, re.MULTILINE))
    if "MemTotal" not in values or "MemAvailable" not in values:
        return None
    return {"total": int(values["MemTotal"]) * 1024, "free": int(values["MemAvailable"]) * 1024}


def check_apk(path: object) -> Path:
    """Only an .apk file in the user's home folder, of a sane size."""
    if not isinstance(path, str) or not path:
        raise AppsError("Choose an app file (.apk).")
    file = Path(path).expanduser().resolve()
    if file.suffix.lower() != ".apk" or not file.is_file():
        raise AppsError("That is not an app file (.apk).")
    if not file.is_relative_to(Path.home()):
        raise AppsError("Couch installs app files from your home folder only.")
    if file.stat().st_size > MAX_APK_BYTES:
        raise AppsError("That app file is too big.")
    return file


INSTALL_FAILURES = {
    "INSTALL_FAILED_UPDATE_INCOMPATIBLE": "A different version of this app is already on the TV. Uninstall it first.",
    "INSTALL_FAILED_VERSION_DOWNGRADE": "The TV already has a newer version of this app.",
    "INSTALL_FAILED_INSUFFICIENT_STORAGE": "The TV is out of space. Free up space first.",
    "INSTALL_FAILED_NO_MATCHING_ABIS": "This app is not made for the TV's processor.",
    "INSTALL_FAILED_OLDER_SDK": "This app needs a newer version of Android than the TV has.",
    "INSTALL_PARSE_FAILED_NOT_APK": "That file is not a working app.",
    "INSTALL_PARSE_FAILED_NO_CERTIFICATES": "That app file is not signed, so Android refuses it.",
}


def install_result(output: str) -> str | None:
    """None on success, else a plain reason."""
    if re.search(r"^Success", output, re.MULTILINE):
        return None
    for code, reason in INSTALL_FAILURES.items():
        if code in output:
            return reason
    failure = re.search(r"Failure \[([A-Z_]+)", output)
    return f"The TV refused the app ({failure.group(1)})." if failure else "The TV did not install the app."


class TVTools:
    def __init__(self, apps: AppsManager) -> None:
        self.apps = apps

    # ------------------------------------------------------------ install

    async def install(self, path: object) -> str:
        file = check_apk(path)
        output = await self.apps.device_command("install", "-r", str(file), timeout=INSTALL_TIMEOUT_SECONDS)
        reason = install_result(output)
        if reason:
            log.info("install %s: %s", file.name, output.strip()[-200:])
            raise AppsError(reason)
        return file.name

    # ------------------------------------------------------------ status

    async def status(self) -> dict:
        tweak_commands = [f"settings get {t.namespace} {t.keys[0]}" for t in TWEAKS.values()]
        *tweak_values, storage, memory, home = await self.apps.shell(
            *tweak_commands, "df -k /data", "cat /proc/meminfo", HOME_RESOLVE)
        return {
            "type": "tv_tools",
            "tweaks": {name: tweak.choice(value.strip()) for (name, tweak), value in zip(TWEAKS.items(), tweak_values)},
            # The pickers, so the Mac shows exactly the choices allowed here.
            "options": [{"name": name, "title": tweak.title,
                         "choices": [{"id": c, "label": label} for c, label, _value in tweak.choices]}
                        for name, tweak in TWEAKS.items()],
            "changed": sorted(_load_originals()),
            "storage": parse_storage(storage),
            "memory": parse_memory(memory),
            "home": home_package(home),
            "google_home": GOOGLE_HOME,
            "suggested_home": SUGGESTED_HOME,
        }

    # ------------------------------------------------------------ tweaks

    async def set_tweak(self, name: object, choice: object) -> None:
        tweak = TWEAKS.get(name) if isinstance(name, str) else None
        if tweak is None:
            raise AppsError("Unknown setting.")
        value = tweak.value(choice)
        if value is None:
            raise AppsError("That value is not allowed.")
        await self._remember_originals(tweak)
        await self.apps.shell(*(f"settings put {tweak.namespace} {key} {shlex.quote(value)}" for key in tweak.keys))

    async def _remember_originals(self, tweak: Tweak) -> None:
        """Save the TV's own values the first time Couch changes them, so Reset can put them back."""
        originals = _load_originals()
        missing = [key for key in tweak.keys if f"{tweak.namespace}/{key}" not in originals]
        if not missing:
            return
        values = await self.apps.shell(*(f"settings get {tweak.namespace} {key}" for key in missing))
        for key, value in zip(missing, values):
            value = value.strip()
            if not _valid_original(value):
                # Never change a setting whose value could not be saved: Reset could not undo it.
                log.info("settings get %s/%s gave no value", tweak.namespace, key)
                raise AppsError("The TV did not report that setting. Try again.")
            originals[f"{tweak.namespace}/{key}"] = value
        _save_originals(originals)

    async def reset_tweaks(self) -> None:
        """Put back every setting Couch changed, exactly as the TV had it."""
        commands = []
        for entry, value in _load_originals().items():
            namespace, key = entry.split("/", 1)  # only WRITABLE entries are loaded
            commands.append(f"settings delete {namespace} {key}" if value == UNSET
                            else f"settings put {namespace} {key} {shlex.quote(value)}")
        if commands:
            await self.apps.shell(*commands)
        _save_originals({})

    # ------------------------------------------------------------ space and memory

    async def free_space(self) -> None:
        """Clear app caches: Android asks every app to drop cached files. Nothing personal is deleted."""
        await self.apps.shell("pm trim-caches 999G", timeout=FREE_SPACE_TIMEOUT_SECONDS)

    async def free_memory(self, keep: str | None) -> int:
        """Stop apps running in the background, except the one on screen."""
        recents = await self.apps.recents()
        stop = [r["package"] for r in recents if r["live"] and r["package"] != keep]
        if stop:
            await self.apps.shell(*(f"am force-stop {shlex.quote(check_package(p))}" for p in stop))
        return len(stop)

    # ------------------------------------------------------------ home screen

    async def suggest_home(self) -> None:
        """Open the Play Store page of a cleaner home screen on the TV. The user installs it there."""
        await self.apps.shell(
            f"am start -a android.intent.action.VIEW -d {shlex.quote('market://details?id=' + SUGGESTED_HOME)}")

    async def set_home(self, package: object) -> None:
        name = check_package(package)
        (resolved,) = await self.apps.shell(f"{HOME_RESOLVE} {shlex.quote(name)}")
        lines = resolved.strip().splitlines()
        component = lines[-1].strip() if lines else ""
        if home_package(resolved) != name or not COMPONENT.fullmatch(component):
            raise AppsError("That app is not a home screen. Install it on the TV first.")
        (result,) = await self.apps.shell(f"cmd package set-home-activity {shlex.quote(component)}")
        if "Success" not in result and result.strip():
            log.info("set-home %s: %s", component, result.strip()[:200])
            raise AppsError("The TV did not switch home screens.")
        await self.apps.shell("input keyevent KEYCODE_HOME")


def _same(a: str, b: str) -> bool:
    try:
        return float(a) == float(b)
    except ValueError:
        return a == b
