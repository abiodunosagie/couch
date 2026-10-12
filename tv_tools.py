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

from apps import AppsError, AppsManager, check_package
from tv import CONFIG_DIR, ensure_config_dir

log = logging.getLogger("tvremote.tools")

ORIGINALS_FILE = CONFIG_DIR / "tv_originals.json"
INSTALL_TIMEOUT_SECONDS = 600.0
MAX_APK_BYTES = 2 * 1024 ** 3
GOOGLE_HOME = "com.google.android.apps.tv.launcherx"
# A popular ad free home screen for Google TV; Couch opens its Play Store page, the user installs it.
SUGGESTED_HOME = "com.spocky.projengmenu"

MINUTE_MS = 60_000
# name: (namespace, key, {choice: value}). Only these keys and values are ever written.
TWEAKS: dict[str, tuple[str, str, dict[str, str]]] = {
    "animations": ("global", "window_animation_scale", {"normal": "1.0", "fast": "0.5", "off": "0"}),
    "screensaver_after": ("system", "screen_off_timeout",
                          {"5": str(5 * MINUTE_MS), "10": str(10 * MINUTE_MS), "15": str(15 * MINUTE_MS),
                           "30": str(30 * MINUTE_MS)}),
    "sleep_after": ("secure", "sleep_timeout",
                    {"30": str(30 * MINUTE_MS), "60": str(60 * MINUTE_MS), "120": str(120 * MINUTE_MS),
                     "240": str(240 * MINUTE_MS)}),
}
# Animation speed is three settings that move together.
ANIMATION_KEYS = ("window_animation_scale", "transition_animation_scale", "animator_duration_scale")


def _load_originals() -> dict[str, str]:
    try:
        data = json.loads(ORIGINALS_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)} if isinstance(data, dict) else {}


def _save_originals(originals: dict[str, str]) -> None:
    ensure_config_dir()
    fd = os.open(ORIGINALS_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(originals, out, indent=2)


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
        commands = [f"settings get {namespace} {key}" for namespace, key, _ in TWEAKS.values()]
        commands += ["df -k /data", "cat /proc/meminfo",
                     "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"]
        outputs = await self.apps.shell(*commands)
        tweaks = {}
        for (name, (_ns, _key, choices)), value in zip(TWEAKS.items(), outputs[:len(TWEAKS)]):
            value = value.strip()
            tweaks[name] = next((choice for choice, v in choices.items() if _same(v, value)), "custom")
        home_lines = outputs[-1].strip().splitlines()
        home = home_lines[-1].split("/")[0] if home_lines else None
        return {
            "type": "tv_tools",
            "tweaks": tweaks,
            "changed": sorted(_load_originals()),
            "storage": parse_storage(outputs[len(TWEAKS)]),
            "memory": parse_memory(outputs[len(TWEAKS) + 1]),
            "home": home if home and check_package_ok(home) else None,
        }

    # ------------------------------------------------------------ tweaks

    async def set_tweak(self, name: object, choice: object) -> None:
        if name not in TWEAKS:
            raise AppsError("Unknown setting.")
        namespace, key, choices = TWEAKS[name]
        if choice not in choices:
            raise AppsError("That value is not allowed.")
        keys = ANIMATION_KEYS if name == "animations" else (key,)
        await self._remember_originals(namespace, keys)
        await self.apps.shell(*(f"settings put {namespace} {k} {shlex.quote(choices[choice])}" for k in keys))

    async def _remember_originals(self, namespace: str, keys: tuple[str, ...]) -> None:
        originals = _load_originals()
        missing = [k for k in keys if f"{namespace}/{k}" not in originals]
        if not missing:
            return
        values = await self.apps.shell(*(f"settings get {namespace} {k}" for k in missing))
        for k, value in zip(missing, values):
            originals[f"{namespace}/{k}"] = value.strip()
        _save_originals(originals)

    async def reset_tweaks(self) -> None:
        """Put back every setting Couch changed, exactly as the TV had it."""
        originals = _load_originals()
        commands = []
        for entry, value in originals.items():
            namespace, key = entry.split("/", 1)
            if not _known_key(namespace, key):
                continue
            commands.append(f"settings delete {namespace} {key}" if value == "null"
                            else f"settings put {namespace} {key} {shlex.quote(value)}")
        if commands:
            await self.apps.shell(*commands)
        _save_originals({})

    # ------------------------------------------------------------ space and memory

    async def free_space(self) -> None:
        """Clear app caches: Android asks every app to drop cached files. Nothing personal is deleted."""
        await self.apps.shell("pm trim-caches 999G")

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
        (resolved,) = await self.apps.shell(
            f"cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME "
            f"{shlex.quote(name)}")
        lines = resolved.strip().splitlines()
        component = lines[-1].strip() if lines else ""
        if not component.startswith(name + "/"):
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


def _known_key(namespace: str, key: str) -> bool:
    return any(namespace == ns and (key == k or key in ANIMATION_KEYS) for ns, k, _ in TWEAKS.values())


def check_package_ok(package: str) -> bool:
    try:
        check_package(package)
    except AppsError:
        return False
    return True
