"""Typing into TV text fields.

androidtvremote2 0.3.2 addresses text edits with the `field_counter` from the TV's
`remote_ime_batch_edit` message. Google TV ignores edits sent that way. It accepts
them only when they carry the id of the focused field, which it announces in
`text_field_status.counter_field` (in `remote_ime_key_inject` when a field gets
focus, and in `remote_ime_show_request` after each edit, where the id changes).
Verified against a Chromecast with Google TV 4K on 2026-10-12.

`install()` swaps the library's protocol class for one that tracks that id.
"""

from __future__ import annotations

from google.protobuf.message import DecodeError

import androidtvremote2.androidtv_remote as library
from androidtvremote2.remote import RemoteProtocol
from androidtvremote2.remotemessage_pb2 import RemoteEditInfo, RemoteImeBatchEdit, RemoteImeObject, RemoteMessage


class FieldTrackingProtocol(RemoteProtocol):
    """RemoteProtocol that remembers the focused text field and types into it."""

    text_field_id: int = 0

    def _handle_message(self, raw_msg: bytes) -> None:
        msg = RemoteMessage()
        try:
            msg.ParseFromString(raw_msg)
        except DecodeError:
            pass
        else:
            if msg.HasField("remote_ime_key_inject") and msg.remote_ime_key_inject.HasField("text_field_status"):
                self.text_field_id = msg.remote_ime_key_inject.text_field_status.counter_field
            elif msg.HasField("remote_ime_show_request"):
                self.text_field_id = msg.remote_ime_show_request.remote_text_field_status.counter_field
        super()._handle_message(raw_msg)

    def send_text(self, text: str) -> None:
        """Replace the focused field's contents with `text`, cursor at the end."""
        if not self.text_field_id:
            # No field announced yet; the library's own addressing is the only option.
            super().send_text(text)
            return
        if not text:
            raise ValueError("Text cannot be empty")
        self._reset_idle_disconnect_task()
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


def install() -> None:
    """Make AndroidTVRemote build FieldTrackingProtocol connections."""
    library.RemoteProtocol = FieldTrackingProtocol
