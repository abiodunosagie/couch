"use strict";

// Couch phone remote. Talks to the Couch helper on the Mac; the Mac talks to the TV.

const TOKEN_KEY = "couch-token";
const REPEAT_DELAY_MS = 420;
const REPEAT_EVERY_MS = 130;
const SWIPE_STEP_PX = 34;
const TAP_SLOP_PX = 10;
const RECONNECT_MS = 1500;

const MAX_SEARCH = 200;  // MAX_SEARCH_LENGTH in server.py

const STATUS_TEXT = {
  connected: "Connected", reconnecting: "Reconnecting", offline: "TV not reachable",
  unpaired: "Pair on the Mac first", pairing: "Pairing on the Mac", searching: "Looking for the TV",
};

const $ = (id) => document.getElementById(id);
let socket = null;
let retryTimer = 0;
let state = { status: "searching" };
let sheetMode = null; // "type" | "search"
let toastTimer = 0;

// ------------------------------------------------------------ pairing token

function readToken() {
  // The QR code puts the token in the address as ?t=. It stays there, because Home Screen apps
  // and the camera's link viewer keep separate storage; storage is only a backup.
  const fromAddress = new URLSearchParams(location.search).get("t")
    || (location.hash.match(/t=([A-Za-z0-9_-]+)/) || [])[1];
  let stored = null;
  try { stored = localStorage.getItem(TOKEN_KEY); } catch { /* storage blocked */ }
  const token = fromAddress || stored;
  if (!token) return null;
  try { localStorage.setItem(TOKEN_KEY, token); } catch { /* fine, the address has it */ }
  if (new URLSearchParams(location.search).get("t") !== token) {
    history.replaceState(null, "", `/?t=${encodeURIComponent(token)}`);
  }
  // Add to Home Screen reads the manifest; its start address must carry the token too.
  document.querySelector('link[rel="manifest"]').href = `/manifest.webmanifest?t=${encodeURIComponent(token)}`;
  return token;
}
const token = readToken();

// ------------------------------------------------------------ connection

function connect() {
  clearTimeout(retryTimer);
  if (!token) { showGate(); return; }
  if (socket && (socket.readyState === WebSocket.CONNECTING || socket.readyState === WebSocket.OPEN)) return;
  const ws = new WebSocket(`ws://${location.host}/ws?t=${encodeURIComponent(token)}`);
  socket = ws;
  ws.addEventListener("message", (event) => {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message.type === "state") render(message);
    else if (message.type === "recents") renderRecents(message.apps || []);
    else if (message.type === "error") toast(message.message);
  });
  ws.addEventListener("close", async () => {
    if (socket !== ws) return;  // an older socket closing after a newer one opened
    socket = null;
    recentsAsked = false;
    render({ ...state, status: "searching" });
    $("status").textContent = "Mac not reachable, retrying";
    // A refused code means the Mac forgot this phone: ask for a new scan instead of retrying forever.
    try {
      const check = await fetch(`/check?t=${encodeURIComponent(token)}`, { cache: "no-store" });
      if (check.status === 403) { forgetToken(); return; }
    } catch { /* the Mac is asleep or off the Wi-Fi: keep trying */ }
    retryTimer = setTimeout(connect, RECONNECT_MS);
  });
}

function forgetToken() {
  try { localStorage.removeItem(TOKEN_KEY); } catch { /* nothing stored */ }
  history.replaceState(null, "", "/");
  showGate();
}

function showGate() { $("gate").hidden = false; }

// Coming back to the page (unlocking the phone, switching apps) reconnects at once.
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") connect(); });
window.addEventListener("online", connect);

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
let recentsAsked = false;  // once per connection; the Mac pushes changes after that

function render(next) {
  state = next;
  $("status").textContent = STATUS_TEXT[state.status] || "Connecting";
  $("tv").textContent = state.tv || "Couch";
  const app = state.app_name || "";
  $("now").textContent = state.status === "connected" && app ? `Now on ${app}` : " ";
  for (const el of [$("dot"), $("light")]) {
    el.classList.toggle("live", state.status === "connected");
    el.classList.toggle("warn", state.status === "reconnecting" || state.status === "searching");
  }
  $("remote").classList.toggle("off", state.status !== "connected" || state.is_on === false);
  if (state.status === "connected" && !recentsAsked) { recentsAsked = true; send({ type: "recents" }); }
  if (state.notice && state.notice_id !== lastNotice) toast(state.notice);
  lastNotice = state.notice_id;
  renderMirror();
}

function renderMirror() {
  const mirror = $("mirror");
  if (sheetMode !== "type") return;
  const field = state.field;
  mirror.classList.toggle("live", Boolean(field && field.active));
  // The phone is never sent the TV text itself: it can be a password.
  mirror.textContent = field && field.active
    ? "A text box is open on the TV. What you send goes in at the cursor."
    : "Select a text box on the TV first.";
}

// ------------------------------------------------------------ recent apps

function renderRecents(apps) {
  const strip = $("recents");
  strip.replaceChildren();
  strip.hidden = apps.length === 0;
  for (const app of apps) {
    const card = document.createElement("button");
    card.className = "recent" + (app.package === state.app ? " current" : "");
    const name = document.createElement("b");
    name.textContent = app.name || app.package;
    const when = document.createElement("span");
    // Phones get names only, not when each app was last watched.
    when.textContent = app.package === state.app ? "On screen" : "Open";
    card.append(name, when);
    card.addEventListener("click", () => sendIfConnected({ type: "resume", package: app.package }));
    strip.append(card);
  }
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
  // A held key stops by itself if the TV drops, instead of buzzing errors.
  const repeatPress = () => { if (state.status !== "connected") stop(); else press(key); };
  button.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    stop();
    button.classList.add("pressed");
    press(key);
    delay = setTimeout(() => { repeat = setInterval(repeatPress, REPEAT_EVERY_MS); }, REPEAT_DELAY_MS);
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
  if (gesture) return;  // one finger at a time; a second touch is ignored
  pad.setPointerCapture(event.pointerId);
  const current = { id: event.pointerId, x: event.clientX, y: event.clientY, lastX: event.clientX, lastY: event.clientY,
                    moved: false, axis: null, hold: 0, repeat: 0, repeated: false };
  gesture = current;
  const edge = edgeOf(event.clientX, event.clientY);
  pad.dataset.dir = edge;
  if (edge !== "ok") {
    // Holding an edge repeats, like the real pad.
    current.hold = setTimeout(() => {
      current.repeated = true;
      current.repeat = setInterval(() => {
        if (state.status !== "connected") { clearInterval(current.repeat); return; }
        press(PAD_KEYS[edge]);
      }, REPEAT_EVERY_MS);
    }, REPEAT_DELAY_MS);
  }
});

pad.addEventListener("pointermove", (event) => {
  if (!gesture || event.pointerId !== gesture.id) return;
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
  if (!gesture || event.pointerId !== gesture.id) return;
  clearTimeout(gesture.hold);
  clearInterval(gesture.repeat);
  // A tap presses once on release; a hold already pressed while repeating.
  if (!gesture.moved && !gesture.repeated && event.type === "pointerup") press(PAD_KEYS[edgeOf(gesture.x, gesture.y)]);
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
$("open-settings").addEventListener("click", () => sendIfConnected({ type: "open_settings" }));
$("open-search").addEventListener("click", () => openSheet("search"));
$("sheet-close").addEventListener("click", closeSheet);
$("sheet").addEventListener("click", (event) => { if (event.target === $("sheet")) closeSheet(); });

$("sheet-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const text = $("sheet-input").value;
  if (!text.trim()) return;
  // Keep the text when it cannot go yet, so nothing typed is lost.
  if (sheetMode === "type" && !(state.field && state.field.active)) { toast("Select a text box on the TV first."); return; }
  if (sheetMode === "search" && text.length > MAX_SEARCH) { toast(`Search for up to ${MAX_SEARCH} characters.`); return; }
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
