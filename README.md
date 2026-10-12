# Couch

A Mac remote for Chromecast with Google TV. Lives in the menu bar (Option Command R opens it from anywhere) and as a normal window.

- `mac/` is the native app (SwiftUI and AppKit).
- `tv.py`, `server.py` and `tvremote.py` are the helper that speaks the Android TV Remote v2 protocol through `androidtvremote2`. The app starts it on launch and stops it on quit. It listens on 127.0.0.1 only.

## Build

    ./build-app.sh

Installs `~/Applications/Couch.app`. Needs Xcode command line tools and `uv`.

## Pairing

The first time, Couch asks for the 6 character code the TV shows. The client certificate lives in `~/.config/tvremote` (owner only).

## Terminal

    tvremote status
    tvremote key HOME
    tvremote text "breaking bad"
