"""Typing into TV text fields.

androidtvremote2 0.3.2 addresses text edits with the `field_counter` from the TV's
`remote_ime_batch_edit` message. Google TV ignores edits sent that way. It accepts
them only when they carry
- as `ime_counter`, the app counter from `remote_ime_key_inject.app_info.counter`
  (the library's batch counter can lag behind it, and then every edit is dropped), and
- as `field_counter`, the id of the focused field, announced in
  `text_field_status.counter_field`: in `remote_ime_key_inject` when a field gets focus,
  and in `remote_ime_show_request` after each accepted edit, where the id moves on and
  the field's full text comes along.
Verified against a Chromecast with Google TV 4K on 2026-10-12.

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


def u16(text: str) -> int:
    """Length in UTF-16 code units, which is how the TV counts cursor positions."""
    return len(text.encode("utf-16-le")) // 2


def _index(text: str, position: int) -> int:
    """The string index at a UTF-16 position, clamped to the text."""
    units = 0
    for index, char in enumerate(text):
        if units >= position:
            return index
        units += u16(char)
    return len(text)


@dataclass
class _Insert:
    text: str


@dataclass
class _Key:
    name: str


@dataclass
class _Clear:
    """Delete everything; counted when it runs, so text typed just before is included."""


class FieldTrackingProtocol(RemoteProtocol):
    """RemoteProtocol that remembers the focused text field and types into it in order.

    Couch keeps its own copy of the field text and cursor, updated as each edit goes out,
    because the TV does not answer every key edit. Each insert names the cursor position
    after it, counted over the whole field in UTF-16 units: the TV cuts the field off there.
    When the TV does report the field, its report wins.
    """

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.text_field_id = 0
        self.app_counter = 0
        self.field_value = ""
        self.cursor = 0  # UTF-16 units
        self.on_field_changed: Callable[[], None] | None = None
        self._edits: deque[_Insert | _Key | _Clear] = deque()
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
                if inject.HasField("app_info") and inject.app_info.counter:
                    self.app_counter = inject.app_info.counter
                # Focus moved: to a text field (it has a status) or away from one (it has none).
                if inject.HasField("text_field_status"):
                    status = inject.text_field_status
                    self._field_update(status.counter_field, status.value, self._reported_cursor(status))
                else:
                    self._field_update(0, "", 0)
            elif msg.HasField("remote_ime_show_request"):
                status = msg.remote_ime_show_request.remote_text_field_status
                self._field_update(status.counter_field, status.value, self._reported_cursor(status))
        super()._handle_message(raw_msg)

    def _reported_cursor(self, status) -> int | None:
        """The TV's cursor. Proto3 drops zeros, so 0/0 on text that is not empty is either "at the
        start" or "not sent"; keep Couch's own position when it is at the start, else take the end."""
        if status.start == 0 and status.end == 0 and status.value:
            return 0 if self.cursor == 0 else None
        return status.end

    def _field_update(self, field_id: int, value: str, cursor: int | None) -> None:
        changed = (field_id != 0) != self.field_active or value != self.field_value
        self.cursor = min(cursor, u16(value)) if cursor is not None else u16(value)
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
        """Empty the field. A second Clear while one waits does nothing."""
        if any(isinstance(edit, _Clear) for edit in self._edits):
            return
        self._edits.append(_Clear())
        self._run()

    def _run(self) -> None:
        if self._pump is None or self._pump.done():
            self._pump = self._loop.create_task(self._send_edits())

    async def _send_edits(self) -> None:
        while self._edits:
            edit = self._edits.popleft()
            self._reset_idle_disconnect_task()
            if isinstance(edit, _Key):
                await self._key(edit.name)
            elif isinstance(edit, _Clear):
                await self._key("MOVE_END")
                for _ in range(min(len(self.field_value), MAX_CLEAR)):
                    await self._key("DEL")
            else:
                await self._insert(edit.text)

    async def _key(self, name: str) -> None:
        self.send_key_command(f"KEYCODE_{name}")
        self._apply_key(name)
        await asyncio.sleep(KEY_GAP_SECONDS)

    def _apply_key(self, name: str) -> None:
        """Mirror a key edit locally, since the TV may not report it."""
        value, at = self.field_value, _index(self.field_value, self.cursor)
        if name == "DEL" and at > 0:
            self.field_value = value[:at - 1] + value[at:]
            self.cursor -= u16(value[at - 1])
        elif name == "FORWARD_DEL" and at < len(value):
            self.field_value = value[:at] + value[at + 1:]
        elif name == "DPAD_LEFT" and at > 0:
            self.cursor -= u16(value[at - 1])
        elif name == "DPAD_RIGHT" and at < len(value):
            self.cursor += u16(value[at])
        elif name == "MOVE_HOME":
            self.cursor = 0
        elif name == "MOVE_END":
            self.cursor = u16(value)

    async def _insert(self, text: str) -> None:
        sent_with = self.text_field_id
        self._id_moved.clear()
        self._send_insert(text)
        at = _index(self.field_value, self.cursor)
        self.field_value = self.field_value[:at] + text + self.field_value[at:]
        self.cursor += u16(text)
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
        after = self.cursor + u16(text)
        field = RemoteImeObject(start=after, end=after, value=text)
        msg.remote_ime_batch_edit.CopyFrom(
            RemoteImeBatchEdit(
                ime_counter=self.app_counter or self.ime_counter,
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
