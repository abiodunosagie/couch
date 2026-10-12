"""Shared TV plumbing: saved config, client certificate, mDNS discovery, pairing code rules.

Used by both the CLI (tvremote.py) and the app server (server.py).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import warnings
from pathlib import Path
from typing import TypedDict

from androidtvremote2 import AndroidTVRemote, CannotConnect

import text_input
from zeroconf import ServiceStateChange
from zeroconf.asyncio import AsyncServiceBrowser, AsyncServiceInfo, AsyncZeroconf

CLIENT_NAME = "Mac Remote"
SERVICE_TYPE = "_androidtvremote2._tcp.local."
CONFIG_DIR = Path(os.environ.get("TVREMOTE_HOME", Path.home() / ".config" / "tvremote"))
CERT_FILE = CONFIG_DIR / "cert.pem"
KEY_FILE = CONFIG_DIR / "key.pem"
STATE_FILE = CONFIG_DIR / "config.json"
DISCOVERY_SECONDS = 3.0
MDNS_RESOLVE_TIMEOUT_MS = 3000
DEFAULT_PORT = 8765
PAIRING_CODE = re.compile(r"[0-9A-F]{6}")

log = logging.getLogger("tvremote")

# Google TV only accepts typed text addressed to the focused field; see text_input.py.
text_input.install()

# Google TV certificates carry a 66 char common name; cryptography warns, the value is still read fine.
warnings.filterwarnings("ignore", message="Attribute's length must be", category=UserWarning)


class SavedTV(TypedDict, total=False):
    name: str
    host: str


# ---------------------------------------------------------------- config

def ensure_config_dir() -> None:
    CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)


def load_saved_tv() -> SavedTV:
    try:
        data = json.loads(STATE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if k in ("name", "host") and isinstance(v, str)}  # type: ignore[return-value]


def remember_tv(name: str, host: str) -> None:
    if load_saved_tv() == {"name": name, "host": host}:
        return
    ensure_config_dir()
    fd = os.open(STATE_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump({"name": name, "host": host}, out, indent=2)


async def make_remote(host: str) -> AndroidTVRemote:
    """Build a client for the TV, creating this Mac's certificate on first use."""
    ensure_config_dir()
    remote = AndroidTVRemote(CLIENT_NAME, str(CERT_FILE), str(KEY_FILE), host, enable_voice=True)
    # The private key authenticates this Mac to the TV: create it owner-only from the first byte.
    previous_umask = os.umask(0o077)
    try:
        if await remote.async_generate_cert_if_missing():
            log.debug("generated new client certificate")
    finally:
        os.umask(previous_umask)
    for path in (CERT_FILE, KEY_FILE):
        if path.exists():
            os.chmod(path, 0o600)
    return remote


# ---------------------------------------------------------------- discovery

async def discover() -> list[tuple[str, str]]:
    """List TVs on the LAN over mDNS as (name, ipv4)."""
    found: list[str] = []

    def on_change(zeroconf, service_type, name, state_change):  # noqa: ARG001
        # zeroconf calls handlers with these exact keyword names.
        if state_change is ServiceStateChange.Added:
            found.append(name)

    tvs: list[tuple[str, str]] = []
    aiozc = AsyncZeroconf()
    browser = AsyncServiceBrowser(aiozc.zeroconf, SERVICE_TYPE, handlers=[on_change])
    try:
        await asyncio.sleep(DISCOVERY_SECONDS)
        for service_name in found:
            info = AsyncServiceInfo(SERVICE_TYPE, service_name)
            if await info.async_request(aiozc.zeroconf, MDNS_RESOLVE_TIMEOUT_MS):
                ipv4 = [a for a in info.parsed_scoped_addresses() if ":" not in a]
                if ipv4:
                    tvs.append((service_name.removesuffix("." + SERVICE_TYPE), ipv4[0]))
    finally:
        await browser.async_cancel()
        await aiozc.async_close()
    return tvs


async def find_tv(host: str | None, name: str | None) -> tuple[str, str]:
    """Pick the TV: explicit host, then mDNS, then the last address that worked.

    `name` is a filter the user asked for. Without it the saved TV is preferred,
    and if that TV was renamed the only TV on the network is used instead.
    Returns (display name, ip). Raises CannotConnect when nothing is known.
    """
    saved = load_saved_tv()
    if host:
        return name or saved.get("name") or host, host
    tvs = await discover()
    wanted = (name or saved.get("name") or "").lower()
    match = next((tv for tv in tvs if tv[0].lower() == wanted), None)
    if match is None and not name:
        same_host = [tv for tv in tvs if tv[1] == saved.get("host")]
        if same_host:
            match = same_host[0]
        elif len(tvs) == 1:
            match = tvs[0]
    if match:
        remember_tv(*match)
        return match
    if saved.get("host") and not name:
        log.info("TV not found over mDNS, using last known address %s", saved["host"])
        return saved.get("name", saved["host"]), saved["host"]
    raise CannotConnect("No TV found. Check the TV is on and on the same Wi-Fi.")


# ---------------------------------------------------------------- helpers

KNOWN_APPS_FILE = Path(__file__).parent / "known_apps.json"


def _load_known_apps() -> dict[str, dict]:
    try:
        table = json.loads(KNOWN_APPS_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return {k: v for k, v in table.items() if not k.startswith("_") and isinstance(v, dict)}


KNOWN_APPS = _load_known_apps()


def app_name(package: str | None) -> str | None:
    """A readable app name, the same way the Mac app names it (KnownApps.swift)."""
    if not package:
        return None
    known = KNOWN_APPS.get(package, {}).get("name")
    if isinstance(known, str):
        return known
    filler = {"com", "tv", "android", "app", "atv", "google", "androidtv"}
    parts = [part for part in package.split(".") if part not in filler]
    return (parts[-1] if parts else package).capitalize()


def check_pairing_code(code: str) -> str:
    """Normalise a pairing code; raise ValueError unless it is the 6 hex characters the TV shows."""
    code = code.strip().upper()
    if not PAIRING_CODE.fullmatch(code):
        raise ValueError("The code on the TV has 6 characters, 0 to 9 and A to F.")
    return code


def describe(remote: AndroidTVRemote) -> str:
    power = {True: "on", False: "off", None: "unknown"}[remote.is_on]
    parts = [f"power {power}", f"app {remote.current_app or 'unknown'}"]
    volume = remote.volume_info
    if volume:
        muted = ", muted" if volume["muted"] else ""
        parts.append(f"volume {volume['level']}/{volume['max']}{muted}")
    return " | ".join(parts)
