"use strict";

// Couch phone remote. Talks to the Couch helper on the Mac; the Mac talks to the TV.

const TOKEN_KEY = "couch-token";
const REPEAT_DELAY_MS = 420;
const REPEAT_EVERY_MS = 130;
const SWIPE_STEP_PX = 34;
const TAP_SLOP_PX = 10;
const RECONNECT_MS = 1500;

const APP_NAMES = {
  "com.google.android.youtube.tv": "YouTube",
  "com.netflix.ninja": "Netflix",
  "com.apple.atve.androidtv.appletv": "Apple TV",
  "com.amazon.amazonvideo.livingroom": "Prime Video",
  "com.disney.disneyplus": "Disney+",
  "com.spotify.tv.android": "Spotify",
  "com.google.android.apps.tv.launcherx": "Home screen",
  "com.neilturner.aerialviews": "Screensaver",
};
const STATUS_TEXT = {
  connected: "Connected", reconnecting: "Reconnecting", offline: "TV not reachable",
  unpaired: "Pair on the Mac first", pairing: "Pairing on the Mac", searching: "Looking for the TV",
};

const $ = (id) => document.getElementById(id);
let socket = null;
let state = { status: "searching" };
let sheetMode = null; // "type" | "search"
let toastTimer = 0;

// ------------------------------------------------------------ pairing token

function readToken() {
  // The QR code carries the token after "#t=". Keep it, then take it out of the address bar.
  const match = location.hash.match(/t=([A-Za-z0-9_-]+)/);
  if (match) {
    try { localStorage.setItem(TOKEN_KEY, match[1]); } catch { /* private mode: use it for this visit */ }
    history.replaceState(null, "", location.pathname);
    return match[1];
  }
  try { return localStorage.getItem(TOKEN_KEY); } catch { return null; }
}
const token = readToken();

// ------------------------------------------------------------ connection

function connect() {
  if (!token) { $("gate").hidden = false; return; }
  socket = new WebSocket(`ws://${location.host}/ws?t=${encodeURIComponent(token)}`);
  socket.addEventListener("message", (event) => {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message.type === "state") render(message);
    else if (message.type === "error") toast(message.message);
  });
  socket.addEventListener("close", (event) => {
    render({ ...state, status: "searching" });
    $("status").textContent = "Mac not reachable, retrying";
    if (event.code === 1006 && !navigator.onLine) return;
    setTimeout(connect, RECONNECT_MS);
  });
}

function send(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) { toast("Not connected to the Mac."); return false; }
  socket.send(JSON.stringify(message));
  return true;
}

function sendIfConnected(message) {
  if (state.status !== "connected") { toast(STATUS_TEXT[state.status] || "Not connected to the TV."); return false; }
  if (navigator.vibrate) navigator.vibrate(8);
  return send(message);
}

const press = (key) => sendIfConnected({ type: "key", key });

// ------------------------------------------------------------ render

let lastNotice = 0;

function render(next) {
  state = next;
  $("status").textContent = STATUS_TEXT[state.status] || "Connecting";
  $("tv").textContent = state.tv || "Couch";
  const app = state.app ? (APP_NAMES[state.app] || state.app) : "";
  $("now").textContent = state.status === "connected" && app ? `Now on ${app}` : " ";
  for (const el of [$("dot"), $("light")]) {
    el.classList.toggle("live", state.status === "connected");
    el.classList.toggle("warn", state.status === "reconnecting" || state.status === "searching");
  }
  $("remote").classList.toggle("off", state.status !== "connected" || state.is_on === false);
  if (state.notice && state.notice_id !== lastNotice) toast(state.notice);
  lastNotice = state.notice_id;
  renderMirror();
}

function renderMirror() {
  const mirror = $("mirror");
  if (sheetMode !== "type") return;
  const field = state.field;
  mirror.classList.toggle("live", Boolean(field && field.active));
  mirror.textContent = field && field.active
    ? (field.value ? `On the TV: ${field.value}` : "On the TV: empty")
    : "Select a text box on the TV first.";
}

function toast(text) {
  const el = $("toast");
  el.textContent = text;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
}

// ------------------------------------------------------------ buttons

function holdable(button, key) {
  let delay = 0;
  let repeat = 0;
  const stop = () => { clearTimeout(delay); clearInterval(repeat); button.classList.remove("pressed"); };
  button.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    stop();
    button.classList.add("pressed");
    press(key);
    delay = setTimeout(() => { repeat = setInterval(() => press(key), REPEAT_EVERY_MS); }, REPEAT_DELAY_MS);
  });
  for (const type of ["pointerup", "pointercancel", "pointerleave"]) button.addEventListener(type, stop);
  window.addEventListener("blur", stop);
}

document.querySelectorAll("[data-key]").forEach((button) => {
  const key = button.dataset.key;
  if (button.hasAttribute("data-repeat")) holdable(button, key);
  else button.addEventListener("click", () => press(key));
});

document.querySelectorAll("[data-app]").forEach((button) => {
  button.addEventListener("click", () => sendIfConnected({ type: "app", app: button.dataset.app }));
});

// ------------------------------------------------------------ pad: tap to select, tap an edge or swipe to move

const pad = $("pad");
let gesture = null;

function edgeOf(x, y) {
  const box = pad.getBoundingClientRect();
  const dx = x - (box.left + box.width / 2);
  const dy = y - (box.top + box.height / 2);
  if (Math.hypot(dx, dy) < box.width * 0.19) return "ok";
  if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? "right" : "left";
  return dy > 0 ? "down" : "up";
}

const PAD_KEYS = { up: "DPAD_UP", down: "DPAD_DOWN", left: "DPAD_LEFT", right: "DPAD_RIGHT", ok: "DPAD_CENTER" };

pad.addEventListener("pointerdown", (event) => {
  event.preventDefault();
  pad.setPointerCapture(event.pointerId);
  gesture = { x: event.clientX, y: event.clientY, lastX: event.clientX, lastY: event.clientY, moved: false, axis: null, hold: 0 };
  const edge = edgeOf(event.clientX, event.clientY);
  pad.dataset.dir = edge;
  if (edge !== "ok") {
    // Holding an edge repeats, like the real pad.
    gesture.hold = setTimeout(() => {
      gesture.repeat = setInterval(() => press(PAD_KEYS[edge]), REPEAT_EVERY_MS);
    }, REPEAT_DELAY_MS);
  }
});

pad.addEventListener("pointermove", (event) => {
  if (!gesture) return;
  const dx = event.clientX - gesture.lastX;
  const dy = event.clientY - gesture.lastY;
  if (!gesture.moved && Math.hypot(event.clientX - gesture.x, event.clientY - gesture.y) < TAP_SLOP_PX) return;
  if (!gesture.moved) {
    gesture.moved = true;
    clearTimeout(gesture.hold);
    clearInterval(gesture.repeat);
    gesture.axis = Math.abs(dx) > Math.abs(dy) ? "x" : "y";  // one direction per swipe
  }
  const travel = gesture.axis === "x" ? event.clientX - gesture.lastX : event.clientY - gesture.lastY;
  if (Math.abs(travel) >= SWIPE_STEP_PX) {
    const dir = gesture.axis === "x" ? (travel > 0 ? "right" : "left") : (travel > 0 ? "down" : "up");
    pad.dataset.dir = dir;
    press(PAD_KEYS[dir]);
    gesture.lastX = event.clientX;
    gesture.lastY = event.clientY;
  }
});

function endGesture(event) {
  if (!gesture) return;
  clearTimeout(gesture.hold);
  clearInterval(gesture.repeat);
  if (!gesture.moved && event.type === "pointerup") press(PAD_KEYS[edgeOf(gesture.x, gesture.y)]);
  gesture = null;
  delete pad.dataset.dir;
}
pad.addEventListener("pointerup", endGesture);
pad.addEventListener("pointercancel", endGesture);

// ------------------------------------------------------------ sheet: type or search

function openSheet(mode) {
  sheetMode = mode;
  $("sheet").hidden = false;
  $("sheet-title").textContent = mode === "type" ? "Type on the TV" : "Search YouTube";
  $("sheet-input").placeholder = mode === "type" ? "Text for the TV box" : "Show, song or channel";
  $("type-tools").hidden = mode !== "type";
  $("mirror").hidden = mode !== "type";
  $("sheet-input").value = "";
  renderMirror();
  setTimeout(() => $("sheet-input").focus(), 50);
}

function closeSheet() {
  sheetMode = null;
  $("sheet").hidden = true;
  $("sheet-input").blur();
}

$("open-type").addEventListener("click", () => openSheet("type"));
$("open-search").addEventListener("click", () => openSheet("search"));
$("sheet-close").addEventListener("click", closeSheet);
$("sheet").addEventListener("click", (event) => { if (event.target === $("sheet")) closeSheet(); });

$("sheet-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const text = $("sheet-input").value;
  if (!text.trim()) return;
  const ok = sheetMode === "type"
    ? sendIfConnected({ type: "edit", text })
    : sendIfConnected({ type: "search", query: text });
  if (!ok) return;
  $("sheet-input").value = "";
  if (sheetMode === "search") closeSheet();
});

document.querySelectorAll("[data-edit]").forEach((button) => {
  button.addEventListener("click", () => sendIfConnected({ type: "edit", key: button.dataset.edit }));
});
$("clear").addEventListener("click", () => sendIfConnected({ type: "edit", clear: true }));

connect();
