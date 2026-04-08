const hostInput = document.getElementById('host');
const tcpInput = document.getElementById('tcpPort');
const udpInput = document.getElementById('udpPort');
const monitorSelect = document.getElementById('monitorId');
const statusBox = document.getElementById('statusBox');
const streamImg = document.getElementById('streamImg');
const streamMeta = document.getElementById('streamMeta');

const connectBtn = document.getElementById('connectBtn');
const disconnectBtn = document.getElementById('disconnectBtn');
const selectBtn = document.getElementById('selectBtn');
const refreshBtn = document.getElementById('refreshBtn');
const vrBtn = document.getElementById('vrBtn');

let statusTimer = null;

function setStatusHtml(html) {
  statusBox.innerHTML = html;
}

function setStreamMeta(status) {
  const stream = status.stream || {};
  const codec = stream.codec == null ? '-' : stream.codec;
  const dim = stream.width > 0 ? `${stream.width}x${stream.height}` : '-';
  streamMeta.textContent = `monitor=${stream.monitorId ?? '-'} codec=${codec} size=${dim}`;
}

function updateMonitorOptions(monitors, selectedId) {
  monitorSelect.innerHTML = '';
  if (!monitors || monitors.length === 0) {
    const opt = document.createElement('option');
    opt.value = '0';
    opt.textContent = 'No monitors yet';
    monitorSelect.appendChild(opt);
    return;
  }

  monitors.forEach((mon) => {
    const opt = document.createElement('option');
    opt.value = String(mon.id);
    opt.textContent = `[${mon.id}] ${mon.name} (${mon.width}x${mon.height})`;
    if (Number(selectedId) === Number(mon.id)) {
      opt.selected = true;
    }
    monitorSelect.appendChild(opt);
  });
}

async function requestJson(url, method = 'GET', payload = null) {
  const init = { method, headers: {} };
  if (payload) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(payload);
  }

  const res = await fetch(url, init);
  if (!res.ok) {
    throw new Error(`HTTP ${res.status}`);
  }
  return res.json();
}

async function refreshStatus() {
  try {
    const status = await requestJson('/api/status');

    hostInput.value = status.host || hostInput.value;
    tcpInput.value = status.tcpPort || tcpInput.value;
    udpInput.value = status.udpPort || udpInput.value;

    updateMonitorOptions(status.monitors || [], status.monitorId);
    setStreamMeta(status);

    const connection = status.connected ? 'Connected' : 'Disconnected';
    const monitorCount = (status.monitors || []).length;
    const frameTag = status.hasFrame ? `frame #${status.latestFrameSeq}` : 'no frame yet';
    const err = status.lastError ? `<br/><span style="color:#ff9f89">${status.lastError}</span>` : '';

    setStatusHtml(
      `<strong>${connection}</strong><br/>` +
      `Host: ${status.host}:${status.tcpPort} / UDP ${status.udpPort}<br/>` +
      `Monitors: ${monitorCount}<br/>` +
      `Stream: ${frameTag}${err}`
    );
  } catch (err) {
    setStatusHtml(`<strong>Bridge offline</strong><br/>${err.message}`);
  }
}

async function connectHost() {
  const payload = {
    host: hostInput.value.trim(),
    tcpPort: Number(tcpInput.value),
    udpPort: Number(udpInput.value),
    monitorId: Number(monitorSelect.value || 0),
  };

  await requestJson('/api/connect', 'POST', payload);
  streamImg.src = `/stream.mjpg?ts=${Date.now()}`;
  await refreshStatus();
}

async function disconnectHost() {
  await requestJson('/api/disconnect', 'POST', {});
  await refreshStatus();
}

async function selectMonitor() {
  const monitorId = Number(monitorSelect.value || 0);
  await requestJson('/api/select-monitor', 'POST', { monitorId });
  streamImg.src = `/stream.mjpg?ts=${Date.now()}`;
  await refreshStatus();
}

connectBtn.addEventListener('click', () => {
  connectHost().catch((err) => setStatusHtml(`<strong>Connect failed</strong><br/>${err.message}`));
});

disconnectBtn.addEventListener('click', () => {
  disconnectHost().catch((err) => setStatusHtml(`<strong>Disconnect failed</strong><br/>${err.message}`));
});

selectBtn.addEventListener('click', () => {
  selectMonitor().catch((err) => setStatusHtml(`<strong>Select failed</strong><br/>${err.message}`));
});

refreshBtn.addEventListener('click', () => {
  refreshStatus().catch((err) => setStatusHtml(`<strong>Refresh failed</strong><br/>${err.message}`));
});

vrBtn.addEventListener('click', () => {
  window.open('/vr.html', '_blank', 'noopener,noreferrer');
});

statusTimer = setInterval(() => {
  refreshStatus().catch(() => {});
}, 1000);

refreshStatus().catch(() => {});
streamImg.src = `/stream.mjpg?ts=${Date.now()}`;
