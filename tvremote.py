"""Couch: remote control for Google TV (Android TV Remote v2 protocol).

Usage:
    tvremote serve           run the helper server (the Couch Mac app starts this)
    tvremote pair            pair this Mac with the TV from Terminal (one time)
    tvremote key HOME ...    send one or more keys and exit
    tvremote text "hello"    type text into the focused field
    tvremote status          print power, app and volume state
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import secrets
import sys
import threading
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from androidtvremote2 import AndroidTVRemote, CannotConnect, ConnectionClosed, InvalidAuth

from server import serve
from tv import DEFAULT_PORT, check_pairing_code, describe, find_tv, make_remote

SETTLE_SECONDS = 0.6
KEY_INTERVAL_SECONDS = 0.15


# ---------------------------------------------------------------- CLI

class CliError(Exception):
    """A failure with a message fit to print to the user."""


def read_line_daemon(prompt: str) -> asyncio.Future[str]:
    """Read a stdin line on a daemon thread, so Ctrl-C never waits on a blocked input()."""
    loop = asyncio.get_running_loop()
    future: asyncio.Future[str] = loop.create_future()

    def deliver(setter, value) -> None:
        if not future.done():
            setter(value)

    def reader() -> None:
        try:
            line = input(prompt)
        except EOFError as exc:
            loop.call_soon_threadsafe(deliver, future.set_exception, exc)
        else:
            loop.call_soon_threadsafe(deliver, future.set_result, line)

    threading.Thread(target=reader, daemon=True).start()
    return future


async def cli_pair(remote: AndroidTVRemote) -> None:
    name, mac = await remote.async_get_name_and_mac()
    print(f"Pairing with {name} ({mac}).")
    await remote.async_start_pairing()
    print("A code is now showing on the TV.")
    while True:
        try:
            code = check_pairing_code(await read_line_daemon("Enter the code from the TV: "))
        except EOFError:
            raise CliError("Pairing cancelled.") from None
        except ValueError as exc:
            print(exc)
            continue
        try:
            await remote.async_finish_pairing(code)
        except InvalidAuth:
            print("The TV rejected that code. It now shows a new one.")
        except ConnectionClosed:
            print("The TV closed pairing (timed out or cancelled). It now shows a new code.")
        else:
            print("Paired.")
            return
        await remote.async_start_pairing()


@asynccontextmanager
async def cli_connected(args: argparse.Namespace) -> AsyncIterator[AndroidTVRemote]:
    """Connect to the TV for one CLI command and always disconnect afterwards."""
    _, host = await find_tv(args.host, args.name)
    remote = await make_remote(host)
    try:
        try:
            await remote.async_connect()
        except InvalidAuth:
            raise CliError("This Mac is not paired with the TV. Run: tvremote pair") from None
        yield remote
    finally:
        remote.disconnect()


async def cmd_pair(args: argparse.Namespace) -> None:
    _, host = await find_tv(args.host, args.name)
    remote = await make_remote(host)
    try:
        await cli_pair(remote)
        await remote.async_connect()
        await asyncio.sleep(SETTLE_SECONDS)
        print(describe(remote))
    finally:
        remote.disconnect()


async def cmd_key(args: argparse.Namespace) -> None:
    from androidtvremote2.remotemessage_pb2 import RemoteKeyCode

    keys = [k.upper().removeprefix("KEYCODE_") for k in args.keys]
    unknown = [k for k in keys if f"KEYCODE_{k}" not in RemoteKeyCode.keys()]
    if unknown:
        raise CliError(f"Unknown key: {', '.join(unknown)}")
    async with cli_connected(args) as remote:
        for key in keys:
            remote.send_key_command(key)
            await asyncio.sleep(KEY_INTERVAL_SECONDS)
        await asyncio.sleep(SETTLE_SECONDS)


async def cmd_text(args: argparse.Namespace) -> None:
    async with cli_connected(args) as remote:
        remote.send_text(args.text)
        await asyncio.sleep(SETTLE_SECONDS)


async def cmd_open(args: argparse.Namespace) -> None:
    async with cli_connected(args) as remote:
        remote.send_launch_app_command(args.target)
        await asyncio.sleep(SETTLE_SECONDS * 4)
        print(describe(remote))


async def cmd_status(args: argparse.Namespace) -> None:
    async with cli_connected(args) as remote:
        await asyncio.sleep(SETTLE_SECONDS)
        print(describe(remote))


async def cmd_serve(args: argparse.Namespace) -> None:
    if not os.environ.get("COUCH_TOKEN"):
        # Run by hand: still require a token, so other local programs cannot drive the TV.
        os.environ["COUCH_TOKEN"] = secrets.token_urlsafe(24)
        print(f"Clients must send the header X-Couch-Token: {os.environ['COUCH_TOKEN']}", flush=True)
    await serve(args.port, args.host, args.name, args.parent_pid)


def main() -> None:
    parser = argparse.ArgumentParser(prog="tvremote", description="Couch: remote control for Google TV.")
    parser.add_argument("--host", help="TV IP address (skips network discovery)")
    parser.add_argument("--name", help="TV name as shown in Google Home, if you have more than one")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)
    serve_parser = sub.add_parser("serve", help="run the remote app server")
    serve_parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve_parser.add_argument("--parent-pid", type=int, help="exit when this process exits (set by the Mac app)")
    sub.add_parser("pair", help="pair this Mac with the TV")
    key = sub.add_parser("key", help="send keys, e.g. HOME, DPAD_UP, VOLUME_DOWN")
    key.add_argument("keys", nargs="+")
    text = sub.add_parser("text", help="type text into the focused field")
    text.add_argument("text")
    sub.add_parser("status", help="show power, app and volume")
    open_parser = sub.add_parser("open", help="open an app (package name) or a link on the TV")
    open_parser.add_argument("target")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO if args.command == "serve" else logging.WARNING,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # At DEBUG the library logs every message it sends and receives, typed text and
    # passwords included. Keep it at INFO even with -v.
    logging.getLogger("androidtvremote2").setLevel(logging.INFO)
    command = {
        "serve": cmd_serve,
        "pair": cmd_pair,
        "key": cmd_key,
        "text": cmd_text,
        "status": cmd_status,
        "open": cmd_open,
    }[args.command]
    try:
        asyncio.run(command(args))
    except KeyboardInterrupt:
        print()
    except CliError as exc:
        sys.exit(str(exc))
    except (CannotConnect, ConnectionClosed) as exc:
        sys.exit(f"Could not reach the TV: {exc}. Is it on and on the same Wi-Fi?")
    except InvalidAuth:
        sys.exit("The TV refused this Mac. Run: tvremote pair")


if __name__ == "__main__":
    main()
