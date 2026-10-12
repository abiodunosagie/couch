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

# Each insert moves the field id on, so the next edit waits for the TV's echo with the new id.
ECHO_TIMEOUT_SECONDS = 0.6
# Key edits (delete, cursor moves) get no reliable echo; a short gap keeps them in order.
KEY_GAP_SECONDS = 0.08

# Keys allowed in an edit sequence, in the order the user pressed them.
EDIT_KEYS = frozenset({"DEL", "FORWARD_DEL", "ENTER", "DPAD_LEFT", "DPAD_RIGHT", "MOVE_HOME", "MOVE_END"})


class FieldTrackingProtocol(RemoteProtocol):
    """RemoteProtocol that remembers the focused text field and types into it in order."""

    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self.text_field_id = 0
        self.field_value = ""
        self.on_field_changed: Callable[[], None] | None = None
        self._edits: deque[tuple[str, str]] = deque()
        self._echo: asyncio.Event = asyncio.Event()
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
                self._echo.set()
        super()._handle_message(raw_msg)

    def _field_update(self, field_id: int, value: str) -> None:
        changed = (field_id != 0) != self.field_active or value != self.field_value
        self.text_field_id = field_id
        self.field_value = value
        if changed and self.on_field_changed:
            self.on_field_changed()

    # ------------------------------------------------------------ editing

    def send_text(self, text: str) -> None:
        """Insert `text` at the cursor of the focused field."""
        if not text:
            raise ValueError("Text cannot be empty")
        self.queue_edit("text", text)

    def queue_edit(self, kind: str, value: str) -> None:
        """Queue an insert (`kind` "text") or an edit key (`kind` "key", one of EDIT_KEYS)."""
        if kind == "key" and value not in EDIT_KEYS:
            raise ValueError(f"Not an edit key: {value}")
        if kind == "text" and self._edits and self._edits[-1][0] == "text":
            # Fast typing: merge into the insert that is still waiting to go out.
            self._edits[-1] = ("text", self._edits[-1][1] + value)
        else:
            self._edits.append((kind, value))
        if self._pump is None or self._pump.done():
            self._pump = self._loop.create_task(self._send_edits())

    async def _send_edits(self) -> None:
        while self._edits:
            kind, value = self._edits.popleft()
            self._reset_idle_disconnect_task()
            if kind == "key":
                self.send_key_command(f"KEYCODE_{value}")
                await asyncio.sleep(KEY_GAP_SECONDS)
                continue
            self._echo.clear()
            self._send_insert(value)
            try:
                await asyncio.wait_for(self._echo.wait(), ECHO_TIMEOUT_SECONDS)
            except TimeoutError:
                pass  # no echo (no field focused, or the TV dropped it); carry on rather than stall

    def _send_insert(self, text: str) -> None:
        if not self.text_field_id:
            # No field announced yet; the library's own addressing is the only option left.
            super().send_text(text)
            return
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


assert all(f"KEYCODE_{k}" in RemoteKeyCode.keys() for k in EDIT_KEYS)
