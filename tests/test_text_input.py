"""Edits sent to the TV text box: the addressing Google TV needs (see text_input.py)."""

from types import SimpleNamespace

import text_input
from text_input import FieldTrackingProtocol, u16


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


def sent_edit(protocol):
    return protocol.sent[-1].remote_ime_batch_edit


def test_insert_names_cursor_after_the_text_over_the_whole_field():
    # Field "/" with the cursor at the end, paste "couch paste": the TV keeps text up to the
    # position it is sent, so it must be 1 + 11, not 11 (which cut off the last letter).
    protocol = make_protocol("/", cursor=1)
    protocol._send_insert("couch paste")
    status = sent_edit(protocol).edit_info[0].text_field_status
    assert (status.start, status.end, status.value) == (12, 12, "couch paste")


def test_insert_uses_app_counter_and_field_id():
    # The TV drops edits whose ime_counter is the batch counter (1) when the app counter is 2.
    protocol = make_protocol("", cursor=0)
    protocol._send_insert("hi")
    assert sent_edit(protocol).ime_counter == 2
    assert sent_edit(protocol).field_counter == 114


def test_cursor_counts_utf16_like_the_tv():
    assert u16("hi 😀") == 5  # the emoji is two UTF-16 units
    protocol = make_protocol("", cursor=0)
    protocol._send_insert("hi 😀")
    assert sent_edit(protocol).edit_info[0].text_field_status.end == 5


def test_local_model_follows_delete_and_arrows():
    # The TV does not always answer key edits, so Couch tracks them itself.
    protocol = make_protocol("abc", cursor=3)
    protocol._apply_key("DEL")
    assert (protocol.field_value, protocol.cursor) == ("ab", 2)
    protocol._apply_key("DPAD_LEFT")
    assert protocol.cursor == 1
    protocol._apply_key("FORWARD_DEL")
    assert (protocol.field_value, protocol.cursor) == ("a", 1)
    protocol._apply_key("MOVE_HOME")
    assert protocol.cursor == 0
    protocol._apply_key("MOVE_END")
    assert protocol.cursor == 1


def test_typing_after_delete_uses_the_new_cursor():
    protocol = make_protocol("abc", cursor=3)
    protocol._apply_key("DEL")
    protocol._send_insert("x")
    assert sent_edit(protocol).edit_info[0].text_field_status.end == 3  # "ab" + "x"


def test_reported_cursor():
    protocol = make_protocol("abc", cursor=2)
    assert protocol._reported_cursor(SimpleNamespace(start=3, end=3, value="abc")) == 3
    # proto3 drops zeros: 0/0 on text that is not empty is "not sent" unless Couch is at the start
    assert protocol._reported_cursor(SimpleNamespace(start=0, end=0, value="abc")) is None
    protocol.cursor = 0
    assert protocol._reported_cursor(SimpleNamespace(start=0, end=0, value="abc")) == 0


def test_install_replaces_the_library_protocol():
    text_input.install()
    assert text_input.library.RemoteProtocol is FieldTrackingProtocol
