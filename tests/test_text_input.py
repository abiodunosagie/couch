"""Edits sent to the TV text box: the addressing Google TV needs (see text_input.py)."""

from types import SimpleNamespace

import text_input
from text_input import FieldTrackingProtocol, _cursor


def make_protocol(value: str, cursor: int, field_id: int = 114, app_counter: int = 2) -> FieldTrackingProtocol:
    protocol = object.__new__(FieldTrackingProtocol)  # skip the network set up
    protocol.text_field_id = field_id
    protocol.app_counter = app_counter
    protocol.ime_counter = 1
    protocol.field_value = value
    protocol.cursor = cursor
    protocol.sent = []
    protocol._send_message = lambda msg, *args: protocol.sent.append(msg)
    return protocol


def test_insert_names_cursor_after_the_text_over_the_whole_field():
    # Field "/" with the cursor at the end, paste "couch paste": the TV keeps text up to the
    # cursor position it is sent, so it must be 1 + 11, not 11 (which cut off the last letter).
    protocol = make_protocol("/", cursor=1)
    protocol._send_insert("couch paste")
    edit = protocol.sent[0].remote_ime_batch_edit
    assert edit.edit_info[0].text_field_status.end == 12
    assert edit.edit_info[0].text_field_status.start == 12
    assert edit.edit_info[0].text_field_status.value == "couch paste"


def test_insert_uses_app_counter_and_field_id():
    # The TV drops edits whose ime_counter is the batch counter (1) when the app counter is 2.
    protocol = make_protocol("", cursor=0)
    protocol._send_insert("hi")
    edit = protocol.sent[0].remote_ime_batch_edit
    assert edit.ime_counter == 2
    assert edit.field_counter == 114


def test_cursor_reading():
    assert _cursor(SimpleNamespace(start=0, end=0, value="")) == 0
    assert _cursor(SimpleNamespace(start=3, end=3, value="abc")) == 3
    # proto3 drops zeros: 0/0 on text that is not empty means "not reported"
    assert _cursor(SimpleNamespace(start=0, end=0, value="abc")) is None


def test_install_replaces_the_library_protocol():
    text_input.install()
    assert text_input.library.RemoteProtocol is FieldTrackingProtocol
