'use strict';

const $ = (id) => document.getElementById(id);

const form = $('linkForm');
const hostInput = $('host');
const tcpInput = $('tcpPort');
const udpInput = $('udpPort');
const pinField = $('pinField');
const pinInput = $('pin');
const connectBtn = $('connectBtn');
const notice = $('notice');
const monitorBlock = $('monitorBlock');
const monitorList = $('monitorList');
const monitorEmpty = $('monitorEmpty');
const selection = $('selection');
const frame = $('frame');
const screen = $('screen');
const streamImg = $('streamImg');
const nosignalTitle = $('nosignalTitle');
const nosignalText = $('nosignalText');
const tally = $('tally');
const stateLabel = $('stateLabel');
const urlList = $('urlList');

const CODECS = { 0: 'H.264', 1: 'HEVC', 2: 'MJPEG', 3: 'AV1' };

let status = null;
let fieldsFilled = false;
let monitorsKey = '';
let urlsKey = '';
let lastPhase = '';
let busy = false;

// --- Phase: one word for where the link is, derived from /api/status --------

function phaseOf(s) {
  if (!s) return 'offline';
  const linked = s.connected && s.monitors.length > 0;
  if (linked && s.videoClients > 0) return 'headset';
  if (linked) return s.hasFrame ? 'live' : 'waiting';
  if (s.pinRequired) return s.wantConnected ? 'checking' : 'pin';
  if (s.wantConnected) return s.lastError ? 'retrying' : 'linking';
  return s.lastError ? 'error' : 'idle';
}

const PHASES = {
  offline: { label: 'Bridge offline', title: 'Bridge offline', text: 'Start it with node web/bridge/bridge.js. This page picks it up on its own.' },
  idle: { label: 'Not connected', title: 'No signal', text: 'Connect a host to see its desktop here.' },
  error: { label: 'Not connected', title: 'No signal', text: 'The last attempt failed. Check the address and connect again.' },
  pin: { label: 'PIN needed', title: 'Pairing', text: 'This host shares its screen only after its PIN is entered.' },
  checking: { label: 'Checking the PIN…', title: 'Pairing', text: 'This host shares its screen only after its PIN is entered.' },
  linking: { label: 'Connecting…', title: 'Connecting…', text: 'Reaching the host.' },
  retrying: { label: 'Host unreachable, retrying', title: 'No signal', text: 'The bridge keeps retrying every few seconds.' },
  waiting: { label: 'Connected', title: 'Waiting for video', text: 'The host is starting the stream.' },
  live: { label: 'Live', title: '', text: '' },
  headset: { label: 'Live in the headset', title: 'Watching in the headset', text: 'The host is streaming H.264 to the WebXR scene. This preview resumes when it closes.' },
};

// --- Rendering ---------------------------------------------------------------

function render() {
  const phase = phaseOf(status);
  const copy = PHASES[phase];
  const live = phase === 'live';

  tally.dataset.on = String(live || phase === 'headset');
  // A view-only host shares its screens but ignores clicks and keys.
  const viewOnly = Boolean(status && status.viewOnly) && (live || phase === 'headset' || phase === 'waiting');
  stateLabel.textContent = viewOnly ? `${copy.label}, view only` : copy.label;
  stateLabel.title = viewOnly ? 'The host was started with --view-only: it takes no clicks or keys.' : '';
  frame.classList.toggle('is-live', live);
  streamImg.hidden = !live;
  $('nosignal').hidden = live;
  nosignalTitle.textContent = copy.title;
  nosignalText.textContent = copy.text;

  // (Re)attach the MJPEG preview whenever a signal comes back: the old
  // multipart response died with the previous link.
  if (live && lastPhase !== 'live') attachPreview();
  lastPhase = phase;

  renderSlate(phase);
  renderForm(phase);
  renderMonitors(phase);
  renderUrls();
}

function renderSlate(phase) {
  const s = status;
  const stream = (s && s.stream) || {};
  const linked = phase === 'live' || phase === 'waiting' || phase === 'headset';
  const mon = linked && s.monitors.find((m) => m.id === stream.monitorId);
  $('slateMonitor').textContent = mon ? `${mon.id} · ${mon.name || 'Monitor'}` : '–';
  $('slateSize').textContent = linked && stream.width > 0 ? `${stream.width}×${stream.height}` : '–';
  $('slateCodec').textContent = linked && stream.codec != null ? (CODECS[stream.codec] || `codec ${stream.codec}`) : '–';
  $('slateFrame').textContent = phase === 'live' ? `#${s.latestFrameSeq}` : '–';
  if (linked && stream.width > 0) {
    screen.style.aspectRatio = `${stream.width} / ${stream.height}`;
  }
}

function renderForm(phase) {
  const s = status;
  if (s && !fieldsFilled) {
    // Once, on the first status: after that the fields belong to the user.
    hostInput.value = s.host || hostInput.value;
    tcpInput.value = s.tcpPort || tcpInput.value;
    udpInput.value = s.udpPort || udpInput.value;
    fieldsFilled = true;
  }

  const active = Boolean(s && (s.wantConnected || s.connected));
  const linked = phase === 'live' || phase === 'waiting' || phase === 'headset';
  connectBtn.dataset.mode = active ? 'stop' : 'go';
  connectBtn.textContent = linked ? 'Disconnect' : active ? 'Cancel' : 'Connect';
  connectBtn.disabled = busy || phase === 'offline';

  for (const input of [hostInput, tcpInput, udpInput]) input.disabled = active;

  const wantPin = phase === 'pin' || phase === 'checking';
  if (wantPin && pinField.hidden) {
    pinField.hidden = false;
    pinInput.focus();
  } else if (!wantPin) {
    pinField.hidden = true;
  }

  // A first "PIN required" is already said by the PIN field itself.
  const said = phase === 'pin' && s.rejectReason === 1;
  const message = s && s.lastError && !said && (phase === 'pin' || phase === 'error' || phase === 'retrying') ? s.lastError : '';
  showNotice(message);
}

function showNotice(text) {
  notice.textContent = text;
  notice.hidden = !text;
}

function renderMonitors(phase) {
  const s = status;
  const monitors = (s && s.connected && s.monitors) || [];
  // The requested monitor, so a click does not bounce back while the host
  // restarts the stream.
  const selectedId = s && s.monitorId;
  monitorBlock.disabled = !(phase === 'live' || phase === 'waiting' || phase === 'headset');

  const key = JSON.stringify(monitors);
  if (key !== monitorsKey) {
    monitorsKey = key;
    for (const row of monitorList.querySelectorAll('.monitor-row')) row.remove();
    for (const mon of monitors) {
      const row = document.createElement('label');
      row.className = 'monitor-row';
      const radio = document.createElement('input');
      radio.type = 'radio';
      radio.name = 'monitor';
      radio.value = String(mon.id);
      const name = document.createElement('span');
      name.className = 'monitor-name';
      name.textContent = mon.name || `Monitor ${mon.id}`;
      const id = document.createElement('span');
      id.className = 'monitor-id';
      id.textContent = `#${mon.id}`;
      const spec = document.createElement('span');
      spec.className = 'monitor-spec';
      spec.textContent = `${mon.width}×${mon.height} · ${mon.refreshRate} Hz` + (mon.virtual ? ' · virtual' : '');
      row.append(radio, name, id, spec);
      monitorList.append(row);
    }
  }
  monitorEmpty.hidden = monitors.length > 0;

  let selectedRow = null;
  for (const row of monitorList.querySelectorAll('.monitor-row')) {
    const radio = row.querySelector('input');
    const on = Number(radio.value) === Number(selectedId);
    radio.checked = on;
    row.classList.toggle('is-selected', on);
    if (on) selectedRow = row;
  }
  placeSelection(selectedRow);
}

function placeSelection(row) {
  selection.hidden = !row;
  if (!row) return;
  selection.style.height = `${row.offsetHeight}px`;
  selection.style.transform = `translateY(${row.offsetTop}px)`;
}

function renderUrls() {
  const urls = (status && status.headsetUrls) || [];
  const key = urls.join('\n');
  if (key === urlsKey) return;
  urlsKey = key;
  urlList.replaceChildren();
  if (urls.length === 0) {
    const li = document.createElement('li');
    const code = document.createElement('code');
    code.textContent = status ? 'No network address found on this PC.' : '–';
    li.append(code);
    urlList.append(li);
    return;
  }
  for (const url of urls) {
    const li = document.createElement('li');
    const code = document.createElement('code');
    code.textContent = url;
    li.append(code);
    // The clipboard API only exists in a secure context (localhost counts).
    if (navigator.clipboard) {
      const copy = document.createElement('button');
      copy.type = 'button';
      copy.className = 'copy';
      copy.textContent = 'Copy';
      copy.addEventListener('click', () => {
        navigator.clipboard.writeText(url).then(() => {
          copy.textContent = 'Copied';
          setTimeout(() => { copy.textContent = 'Copy'; }, 1400);
        }, () => { copy.textContent = 'Select it'; });
      });
      li.append(copy);
    }
    urlList.append(li);
  }
}

function attachPreview() {
  streamImg.src = `/stream.mjpg?ts=${Date.now()}`;
}

// A dropped multipart response fires 'error'; reattach while still live.
streamImg.addEventListener('error', () => {
  setTimeout(() => {
    if (phaseOf(status) === 'live') attachPreview();
  }, 1500);
});

// --- Talking to the bridge -----------------------------------------------------

async function api(url, payload) {
  const init = payload
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) }
    : { cache: 'no-store' };
  const res = await fetch(url, init);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

async function refresh() {
  try {
    status = await api('/api/status');
  } catch (_) {
    status = null;
  }
  render();
}

async function run(action) {
  busy = true;
  render();
  try {
    const data = await action();
    if (data && data.status) status = data.status;
  } catch (err) {
    showNotice(err.message);
  } finally {
    busy = false;
    render();
  }
}

form.addEventListener('submit', (event) => {
  event.preventDefault();
  if (status && (status.wantConnected || status.connected)) {
    run(() => api('/api/disconnect', {}));
    return;
  }

  const payload = {
    host: hostInput.value.trim(),
    tcpPort: Number(tcpInput.value),
    udpPort: Number(udpInput.value),
  };
  if (!pinField.hidden) {
    const pin = pinInput.value.trim();
    const valid = /^\d{6}$/.test(pin);
    pinInput.setAttribute('aria-invalid', String(!valid));
    if (!valid) {
      showNotice('The PIN is 6 digits.');
      pinInput.focus();
      return;
    }
    payload.pin = pin;
  }
  run(() => api('/api/connect', payload));
});

pinInput.addEventListener('input', () => pinInput.removeAttribute('aria-invalid'));

monitorList.addEventListener('change', (event) => {
  const monitorId = Number(event.target.value);
  // Slide the selection now; the next status confirms it.
  const row = event.target.closest('.monitor-row');
  for (const r of monitorList.querySelectorAll('.monitor-row')) r.classList.toggle('is-selected', r === row);
  placeSelection(row);
  run(() => api('/api/select-monitor', { monitorId }).then((data) => {
    attachPreview();
    return data;
  }));
});

window.addEventListener('resize', () => placeSelection(monitorList.querySelector('.monitor-row.is-selected')));

refresh();
setInterval(refresh, 1000);
