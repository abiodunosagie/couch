"""Typing into TV text fields.

androidtvremote2 0.3.2 addresses text edits with the `field_counter` from the TV's
`remote_ime_batch_edit` message. Google TV ignores edits sent that way. It accepts
them only when they carry the id of the focused field, which it announces in
`text_field_status.counter_field`: in `remote_ime_key_inject` when a field gets
focus, and in `remote_ime_show_request` after each accepted edit, where the id moves
on by one and the field's full text comes along. Verified against a Chromecast with
Google TV 4K on 2026-10-12.

`install()` swaps the library's protocol class for one that tracks the field, mirrors
its text, and sends edits one at a time so each carries the id the TV expects.
"""

from __future__ import annotations

import asyncio
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass

from google.protobuf.message import DecodeError

import androidtvremote2.androidtv_remote as library
from androidtvremote2.remote import RemoteProtocol
from androidtvremote2.remotemessage_pb2 import (
    RemoteEditInfo,
    RemoteImeBatchEdit,
    RemoteImeObject,
    RemoteKeyCode,
    RemoteMessage,
)

# Each insert moves the field id on, so the next edit waits for the echo carrying the new id.
# No retry after a timeout: a late echo would turn a retry into a doubled letter.
ECHO_TIMEOUT_SECONDS = 1.0
# Key edits (delete, cursor moves) get no reliable echo; a short gap keeps them in order.
KEY_GAP_SECONDS = 0.04
# Held Delete auto-repeats faster than the TV takes keys; past this, new key edits are dropped
# so nothing keeps deleting after the key is released.
MAX_QUEUED_KEYS = 12
# Clearing deletes at most this many characters.
MAX_CLEAR = 500

# Keys allowed in an edit sequence, sent in the order the user pressed them.
EDIT_KEYS = frozenset({
    "DEL", "FORWARD_DEL", "ENTER", "MOVE_HOME", "MOVE_END",
    "DPAD_LEFT", "DPAD_RIGHT", "DPAD_UP", "DPAD_DOWN",
})
# Up and Down move between fields, so they are allowed when no field is focused.
NAVIGATION_KEYS = frozenset({"DPAD_UP", "DPAD_DOWN"})

for _key in EDIT_KEYS:
    if f"KEYCODE_{_key}" not in RemoteKeyCode.keys():
        raise ImportError(f"androidtvremote2 has no KEYCODE_{_key}")


@dataclass
class _Insert:
    text: str


@dataclass
class _Key:
    name: str


class FieldTrackingProtocol(RemoteProtocol):
    """RemoteProtocol that remembers the focused text field and types into it in order."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.text_field_id = 0
        self.field_value = ""
        self.on_field_changed: Callable[[], None] | None = None
        self._edits: deque[_Insert | _Key] = deque()
        self._id_moved = asyncio.Event()
        self._pump: asyncio.Task[None] | None = None

    @property
    def field_active(self) -> bool:
        return self.text_field_id != 0

    def _handle_message(self, raw_msg: bytes) -> None:
        msg = RemoteMessage()
        try:
            msg.ParseFromString(raw_msg)
        except DecodeError:
            pass
        else:
            if msg.HasField("remote_ime_key_inject"):
                inject = msg.remote_ime_key_inject
                # Focus moved: to a text field (it has a status) or away from one (it has none).
                if inject.HasField("text_field_status"):
                    self._field_update(inject.text_field_status.counter_field, inject.text_field_status.value)
                else:
                    self._field_update(0, "")
            elif msg.HasField("remote_ime_show_request"):
                status = msg.remote_ime_show_request.remote_text_field_status
                self._field_update(status.counter_field, status.value)
        super()._handle_message(raw_msg)

    def _field_update(self, field_id: int, value: str) -> None:
        changed = (field_id != 0) != self.field_active or value != self.field_value
        if field_id != self.text_field_id:
            self._id_moved.set()
        self.text_field_id = field_id
        self.field_value = value
        if changed and self.on_field_changed:
            self.on_field_changed()

    # ------------------------------------------------------------ editing

    def send_text(self, text: str) -> None:
        """Insert `text` at the cursor of the focused field."""
        if not text:
            raise ValueError("Text cannot be empty")
        self.queue_insert(text)

    def queue_insert(self, text: str) -> None:
        if self._edits and isinstance(self._edits[-1], _Insert):
            # Fast typing: merge into the insert that is still waiting to go out.
            self._edits[-1].text += text
        else:
            self._edits.append(_Insert(text))
        self._run()

    def queue_key(self, name: str) -> bool:
        """Queue an edit key. Returns False when dropped because too many are waiting."""
        if name not in EDIT_KEYS:
            raise ValueError(f"Not an edit key: {name}")
        if sum(isinstance(edit, _Key) for edit in self._edits) >= MAX_QUEUED_KEYS:
            return False
        self._edits.append(_Key(name))
        self._run()
        return True

    def queue_clear(self) -> None:
        """Empty the field: jump to the end, then delete everything the TV last reported."""
        self._edits.append(_Key("MOVE_END"))
        self._edits.extend(_Key("DEL") for _ in range(min(len(self.field_value), MAX_CLEAR)))
        self._run()

    def _run(self) -> None:
        if self._pump is None or self._pump.done():
            self._pump = self._loop.create_task(self._send_edits())

    async def _send_edits(self) -> None:
        while self._edits:
            edit = self._edits.popleft()
            self._reset_idle_disconnect_task()
            if isinstance(edit, _Key):
                self.send_key_command(f"KEYCODE_{edit.name}")
                await asyncio.sleep(KEY_GAP_SECONDS)
            else:
                await self._insert(edit.text)

    async def _insert(self, text: str) -> None:
        sent_with = self.text_field_id
        self._id_moved.clear()
        self._send_insert(text)
        # Only an echo that moves the id on belongs to this insert; an older echo does not.
        try:
            await asyncio.wait_for(self._wait_for_new_id(sent_with), ECHO_TIMEOUT_SECONDS)
        except TimeoutError:
            pass  # the TV dropped it or is slow; carry on rather than stall the queue

    async def _wait_for_new_id(self, sent_with: int) -> None:
        while self.text_field_id == sent_with:
            await self._id_moved.wait()
            self._id_moved.clear()

    def _send_insert(self, text: str) -> None:
        msg = RemoteMessage()
        field = RemoteImeObject(start=len(text), end=len(text), value=text)
        msg.remote_ime_batch_edit.CopyFrom(
            RemoteImeBatchEdit(
                ime_counter=self.ime_counter,
                field_counter=self.text_field_id,
                edit_info=[RemoteEditInfo(insert=1, text_field_status=field)],
            )
        )
        self._send_message(msg)

    def connection_lost(self, exc: Exception | None) -> None:
        self._edits.clear()
        if self._pump:
            self._pump.cancel()
        super().connection_lost(exc)


def install() -> None:
    """Make AndroidTVRemote build FieldTrackingProtocol connections."""
    library.RemoteProtocol = FieldTrackingProtocol
