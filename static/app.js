"use strict";

const REPEAT_DELAY_MS = 450;
const REPEAT_EVERY_MS = 140;
const RECONNECT_MS = 1500;

const KEYBOARD = {
  ArrowUp: "DPAD_UP",
  ArrowDown: "DPAD_DOWN",
  ArrowLeft: "DPAD_LEFT",
  ArrowRight: "DPAD_RIGHT",
  Enter: "DPAD_CENTER",
  Escape: "BACK",
  Backspace: "BACK",
  h: "HOME",
  p: "POWER",
  " ": "MEDIA_PLAY_PAUSE",
  "+": "VOLUME_UP",
  "=": "VOLUME_UP",
  "-": "VOLUME_DOWN",
  m: "VOLUME_MUTE",
};

const APP_NAMES = {
  "com.google.android.youtube.tv": "YouTube",
  "com.google.android.youtube.tvkids": "YouTube Kids",
  "com.netflix.ninja": "Netflix",
  "com.amazon.amazonvideo.livingroom": "Prime Video",
  "com.disney.disneyplus": "Disney+",
  "com.spotify.tv.android": "Spotify",
  "com.google.android.apps.tv.launcherx": "Home screen",
  "com.google.android.tvlauncher": "Home screen",
  "com.android.tv.settings": "Settings",
};

const STATUS_TEXT = {
  searching: "Looking for your TV",
  offline: "TV not reachable",
  unpaired: "Not paired",
  pairing: "Pairing",
  connected: "Connected",
  reconnecting: "Reconnecting",
  server_down: "App server stopped, retrying",
};

// Keys that make sense to repeat while held; everything else fires once per press.
const REPEATABLE = new Set(["DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "VOLUME_UP", "VOLUME_DOWN"]);

const $ = (id) => document.getElementById(id);
const els = {
  room: document.querySelector(".room"),
  remote: document.querySelector(".remote"),
  led: $("led"),
  status: $("status"),
  tv: $("tv-name"),
  app: $("app-name"),
  notice: $("notice"),
  pairForm: $("pair-form"),
  pairCode: $("pair-code"),
  pairStart: $("pair-start"),
  textForm: $("text-form"),
  textInput: $("text-input"),
  quit: $("quit"),
};

let socket = null;
let state = { status: "searching" };
let closedByUser = false;
let noticeTimer = 0;
const holdStops = new Set();

// ---------------------------------------------------------------- socket

function connect() {
  socket = new WebSocket(`ws://${location.host}/ws`);
  socket.addEventListener("message", (event) => {
    let message;
    try {
      message = JSON.parse(event.data);
    } catch {
      return;
    }
    if (message.type === "state") render(message);
    else if (message.type === "error") flash(message.message);
    else if (message.type === "closed") showClosed();
  });
  socket.addEventListener("close", () => {
    if (closedByUser) return;
    render({ ...state, status: "server_down" });
    setTimeout(connect, RECONNECT_MS);
  });
}

function send(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    flash("Not connected to the remote app.");
    return;
  }
  socket.send(JSON.stringify(message));
}

function sendIfConnected(message) {
  if (state.status !== "connected") {
    flash(`Not connected to the TV (${(STATUS_TEXT[state.status] || state.status).toLowerCase()}).`);
    return false;
  }
  send(message);
  blink();
  return true;
}

function sendKey(key) {
  return sendIfConnected({ type: "key", key });
}

// ---------------------------------------------------------------- render

function appName(pkg) {
  if (!pkg) return "nothing yet";
  return APP_NAMES[pkg] || pkg;
}

function render(next) {
  const previousStatus = state.status;
  const previousNoticeId = state.notice_id;
  state = next;
  els.status.textContent = STATUS_TEXT[state.status] || state.status;
  els.tv.textContent = state.tv || "TV Remote";
  els.app.textContent = appName(state.app);

  els.led.className = "led";
  if (state.status === "connected") els.led.classList.add("is-live");
  else if (state.status === "reconnecting" || state.status === "pairing") els.led.classList.add("is-warn");

  els.remote.classList.toggle("is-off", state.status !== "connected" || state.is_on === false);

  const needsPairing = state.status === "unpaired" || state.status === "pairing";
  els.pairForm.hidden = !needsPairing;
  els.pairStart.textContent = state.status === "pairing" ? "Show a new code" : "Show a code on the TV";
  if (state.status === "pairing" && previousStatus !== "pairing") {
    els.pairCode.value = "";
    els.pairCode.focus();
  }

  if (state.notice && state.notice_id !== previousNoticeId) {
    flash(state.notice);
    if (state.status === "pairing") els.pairCode.value = "";
  }
}

function flash(text) {
  els.notice.textContent = text;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => { els.notice.textContent = ""; }, 5000);
}

function blink() {
  els.led.classList.add("is-blink");
  setTimeout(() => els.led.classList.remove("is-blink"), 120);
}

function showClosed() {
  closedByUser = true;
  els.room.classList.add("is-closed");
  els.status.textContent = "Closed";
  flash("TV Remote is closed. Open the app again to use it.");
  socket.close();
}

// ---------------------------------------------------------------- buttons

function bindHold(button) {
  const key = button.dataset.key;
  const repeats = button.hasAttribute("data-repeat");
  let delayTimer = 0;
  let repeatTimer = 0;

  const stop = () => {
    clearTimeout(delayTimer);
    clearInterval(repeatTimer);
  };
  holdStops.add(stop);

  button.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    event.preventDefault();
    stop();
    sendKey(key);
    if (repeats) {
      delayTimer = setTimeout(() => {
        repeatTimer = setInterval(() => sendKey(key), REPEAT_EVERY_MS);
      }, REPEAT_DELAY_MS);
    }
  });
  for (const type of ["pointerup", "pointerleave", "pointercancel"]) button.addEventListener(type, stop);
  // Keyboard activation (Tab to the button, then Enter or Space) fires click with detail 0.
  button.addEventListener("click", (event) => {
    if (event.detail === 0) sendKey(key);
  });
}

document.querySelectorAll("[data-key]").forEach(bindHold);

// A held button must never keep firing after the window loses focus mid-press.
const stopAllHolds = () => holdStops.forEach((stop) => stop());
window.addEventListener("blur", stopAllHolds);
document.addEventListener("visibilitychange", stopAllHolds);

document.querySelectorAll("[data-app]").forEach((button) => {
  button.addEventListener("click", () => sendIfConnected({ type: "app", app: button.dataset.app }));
});

// ---------------------------------------------------------------- keyboard

function pressVisual(key) {
  const button = document.querySelector(`[data-key="${key}"]`);
  if (!button) return;
  button.classList.add("is-pressed");
  setTimeout(() => button.classList.remove("is-pressed"), 120);
}

document.addEventListener("keydown", (event) => {
  if (event.target instanceof HTMLInputElement) {
    if (event.key === "Escape") event.target.blur();
    return;
  }
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  // Let Enter and Space activate a focused button natively instead of sending OK or play.
  if (event.target instanceof HTMLButtonElement && (event.key === "Enter" || event.key === " ")) return;
  if (event.key === "/") {
    event.preventDefault();
    els.textInput.focus();
    return;
  }
  const key = KEYBOARD[event.key] || KEYBOARD[event.key.toLowerCase()];
  if (!key) return;
  event.preventDefault();
  if (event.repeat && !REPEATABLE.has(key)) return;
  if (sendKey(key)) pressVisual(key);
});

// ---------------------------------------------------------------- forms

els.textForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = els.textInput.value;
  if (text && sendIfConnected({ type: "text", text })) els.textInput.value = "";
});

els.pairForm.addEventListener("submit", (event) => {
  event.preventDefault();
  // The server checks the code format and replies with the reason if it is wrong.
  const code = els.pairCode.value.trim().toUpperCase();
  if (state.status !== "pairing") {
    flash("Press \"Show a code on the TV\" first.");
    return;
  }
  send({ type: "pair_code", code });
});

els.pairStart.addEventListener("click", () => send({ type: "pair_start" }));

els.quit.addEventListener("click", () => send({ type: "quit" }));

connect();
