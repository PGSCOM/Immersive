#!/usr/bin/env node
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const net = require('net');
const dgram = require('dgram');
const crypto = require('crypto');

const PROTOCOL_VERSION = 1;

const MSG_HELLO = 0x01;
const MSG_HELLO_ACK = 0x02;
const MSG_MONITOR_LIST = 0x03;
const MSG_MONITOR_SELECT = 0x04;
const MSG_STREAM_START = 0x05;
const MSG_HELLO_REJECT = 0x09;
const MSG_INPUT_MOUSE = 0x10;
const MSG_INPUT_KEYBOARD = 0x11;
const MSG_STREAM_CONFIG = 0x21;
const MSG_REQUEST_KEYFRAME = 0x31;

const VIDEO_HEADER_SIZE = 9;

// HelloAck.flags / MonitorList flags (protocol/protocol.h).
const HOST_FLAG_VIEW_ONLY = 0x01;
const HOST_FLAG_VIRTUAL_DISPLAYS = 0x02;
const MONITOR_FLAG_VIRTUAL = 0x01;
const MONITOR_FLAG_PRIMARY = 0x02;

// HelloReject.reason (protocol/protocol.h). 1, 2 and 4 need the user; only a
// full host is worth retrying on our own.
const REJECT_REASONS = {
  1: 'The host wants its pairing PIN (printed in the host console).',
  2: 'Wrong PIN. Check the PIN printed in the host console.',
  3: 'The host is full (--max-clients). Retrying in a few seconds.',
  4: 'Too many wrong PINs from this address. Wait a minute, then try again.',
};
const RECONNECT_DELAY_MS = 3000;
// A slow reader (phone on bad Wi-Fi) must not buffer frames in our memory
// without bound; past this much unsent data we skip frames for it.
const MAX_CLIENT_BACKLOG = 4 * 1024 * 1024;

// VideoCodec enum (protocol/protocol.h)
const CODEC_H264 = 0;
const CODEC_MJPEG = 2;

const DEFAULT_BRIDGE_PORT = 19810;
const DEFAULT_HOST = '127.0.0.1';
const DEFAULT_TCP_PORT = 19800;
const DEFAULT_UDP_PORT = 19801;

const clientDir = path.resolve(__dirname, '..', 'client');

const state = {
  host: DEFAULT_HOST,
  tcpPort: DEFAULT_TCP_PORT,
  udpPort: DEFAULT_UDP_PORT,
  monitorId: 0,
  bridgePort: DEFAULT_BRIDGE_PORT,
  connected: false,
  monitors: [],
  stream: {
    monitorId: null,
    width: 0,
    height: 0,
    codec: null,
  },
  latestFrame: null,
  latestFrameSeq: 0,
  lastError: null,
  // Pairing: the host's PIN (0 = none sent). Loopback connections are exempt
  // on the host side, so a bridge on the PC itself needs none.
  pin: 0,
  pinRequired: false,
  rejectReason: null,
  hostName: '',
  // HELLO_ACK flags: the host takes no input / can make virtual monitors.
  viewOnly: false,
  virtualDisplays: false,
  // The user (or --connect) asked for a link: reconnect when it drops.
  wantConnected: false,
  // Last codec we asked the host to use via STREAM_CONFIG. The host streams a
  // single codec at a time, so we switch it depending on which kind of client
  // is connected (H.264 for VR/WebCodecs readers, MJPEG for the 2D preview).
  lastRequestedCodec: null,
};

let tcpSocket = null;
let tcpRxBuffer = Buffer.alloc(0);
let udpSocket = null;
let reconnectTimer = null;
const frameBuffer = new Map();
const mjpegClients = new Set();
// Binary H.264 readers (the WebXR/WebCodecs client). Each gets reassembled
// Annex-B access units framed as [uint32 LE length][uint8 flags][payload].
const videoClients = new Set();

function parseArgs(argv) {
  const options = {
    bridgePort: DEFAULT_BRIDGE_PORT,
    host: DEFAULT_HOST,
    tcpPort: DEFAULT_TCP_PORT,
    udpPort: DEFAULT_UDP_PORT,
    monitorId: 0,
    autoConnect: false,
    pin: 0,
    open: false,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === '--port' && next) {
      options.bridgePort = Number(next);
      i += 1;
    } else if (arg === '--host' && next) {
      options.host = next;
      i += 1;
    } else if (arg === '--tcp-port' && next) {
      options.tcpPort = Number(next);
      i += 1;
    } else if (arg === '--udp-port' && next) {
      options.udpPort = Number(next);
      i += 1;
    } else if (arg === '--monitor' && next) {
      options.monitorId = Number(next);
      i += 1;
    } else if (arg === '--pin' && next) {
      options.pin = parsePin(next);
      if (options.pin === null) {
        process.stderr.write('[WebBridge] --pin takes the 6-digit PIN printed by the host\n');
        process.exit(1);
      }
      i += 1;
    } else if (arg === '--open') {
      options.open = true;
    } else if (arg === '--connect') {
      options.autoConnect = true;
    }
  }

  return options;
}

// 6 digits (the host's PINs are 100000-999999); '' / 0 clears it.
function parsePin(value) {
  const text = String(value ?? '').trim();
  if (text === '' || text === '0') return 0;
  return /^\d{6}$/.test(text) ? Number(text) : null;
}

function log(message) {
  process.stdout.write(`[WebBridge] ${message}\n`);
}

function setLastError(message) {
  state.lastError = message;
  log(`ERROR: ${message}`);
}

function bindUdpSocket() {
  if (udpSocket) {
    try {
      udpSocket.close();
    } catch (_) {
      // ignore
    }
  }

  udpSocket = dgram.createSocket('udp4');
  udpSocket.on('message', onUdpPacket);
  udpSocket.on('error', (err) => {
    setLastError(`UDP socket error: ${err.message}`);
  });

  udpSocket.bind(state.udpPort, () => {
    log(`UDP listening on 0.0.0.0:${state.udpPort}`);
  });
}

function connectHost() {
  disconnectHost(false);
  state.wantConnected = true;
  state.monitors = [];
  state.hostName = '';
  state.viewOnly = false;
  state.virtualDisplays = false;
  state.rejectReason = null;
  bindUdpSocket();

  // Every handler checks it still owns the link: a destroyed socket's
  // 'close' fires a tick later and used to mark the NEW connection down.
  const sock = new net.Socket();
  tcpSocket = sock;
  sock.setNoDelay(true);

  sock.on('connect', () => {
    if (tcpSocket !== sock) return;
    state.connected = true;
    state.lastError = null;
    state.lastRequestedCodec = null;
    tcpRxBuffer = Buffer.alloc(0);
    log(`Connected to host ${state.host}:${state.tcpPort}`);
    sendHello();
  });

  sock.on('data', (chunk) => {
    if (tcpSocket !== sock) return;
    tcpRxBuffer = Buffer.concat([tcpRxBuffer, chunk]);
    processTcpMessages();
  });

  sock.on('error', (err) => {
    if (tcpSocket !== sock) return;
    state.connected = false;
    setLastError(`TCP error: ${err.message}`);
  });

  sock.on('close', () => {
    if (tcpSocket !== sock) return;
    state.connected = false;
    log('TCP connection closed');
    scheduleReconnect();
  });

  try {
    sock.connect(state.tcpPort, state.host);
  } catch (err) {
    // A bad port throws synchronously; don't leave a dead socket around.
    tcpSocket = null;
    state.wantConnected = false;
    throw err;
  }
}

// Retry after the host went away (restart, Wi-Fi drop), unless the user
// hung up or the host refused us for a reason only the user can fix.
function scheduleReconnect() {
  const blocked = [1, 2, 4].includes(state.rejectReason);
  if (!state.wantConnected || blocked || reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (state.wantConnected) connectHost();
  }, RECONNECT_DELAY_MS);
}

function disconnectHost(logMessage = true) {
  state.connected = false;

  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }

  if (tcpSocket) {
    try {
      tcpSocket.destroy();
    } catch (_) {
      // ignore
    }
    tcpSocket = null;
  }

  if (udpSocket) {
    try {
      udpSocket.close();
    } catch (_) {
      // ignore
    }
    udpSocket = null;
  }

  frameBuffer.clear();
  state.stream = { monitorId: null, width: 0, height: 0, codec: null };
  // A frame from the last link is not a live picture.
  state.latestFrame = null;
  state.lastRequestedCodec = null;

  if (logMessage) {
    log('Disconnected from host');
  }
}

function sendControlMessage(type, payloadBuffer) {
  if (!tcpSocket || !state.connected) {
    return;
  }

  const payload = payloadBuffer || Buffer.alloc(0);
  const header = Buffer.alloc(5);
  header.writeUInt8(type, 0);
  header.writeUInt32LE(payload.length, 1);

  tcpSocket.write(header);
  if (payload.length > 0) {
    tcpSocket.write(payload);
  }
}

// protocol::Hello: version u8, client_name[32], flags u8, pin u32 LE.
function sendHello() {
  const payload = Buffer.alloc(38);
  payload.writeUInt8(PROTOCOL_VERSION, 0);
  Buffer.from('Immersive-2 Web Bridge', 'utf8').copy(payload, 1, 0, 32);
  payload.writeUInt8(0, 33); // flags: video over UDP
  payload.writeUInt32LE(state.pin >>> 0, 34);
  sendControlMessage(MSG_HELLO, payload);
}

function sendMonitorSelect(monitorId) {
  state.monitorId = monitorId;
  const payload = Buffer.from([monitorId & 0xff]);
  sendControlMessage(MSG_MONITOR_SELECT, payload);
  log(`Selecting monitor ${monitorId}`);
}

// Ask the host for a codec. Layout mirrors protocol::StreamConfig (packed):
// codec u8, bitrate_kbps u32, jpeg_quality u8, max_width u16, max_fps u8.
// Zero fields mean "keep the host default" — we only override the codec.
function sendStreamConfig(codec) {
  const payload = Buffer.alloc(9);
  payload.writeUInt8(codec, 0);
  payload.writeUInt32LE(0, 1); // bitrate_kbps (host default = 20 Mbps)
  payload.writeUInt8(0, 5);    // jpeg_quality
  payload.writeUInt16LE(0, 6); // max_width (native)
  payload.writeUInt8(0, 8);    // max_fps (auto)
  sendControlMessage(MSG_STREAM_CONFIG, payload);
}

// protocol::RequestKeyframe { uint8 monitor_id } — ask for an IDR so a freshly
// connected H.264 reader can start decoding without waiting for the GOP boundary.
function sendRequestKeyframe(monitorId) {
  sendControlMessage(MSG_REQUEST_KEYFRAME, Buffer.from([monitorId & 0xff]));
}

// The host streams one codec at a time. Prefer H.264 whenever a VR/WebCodecs
// reader is attached; otherwise serve MJPEG for the 2D preview. Only sends a
// STREAM_CONFIG when the desired codec actually changes (each one restarts the
// host's active streams).
function negotiateCodec() {
  let desired = null;
  if (videoClients.size > 0) {
    desired = CODEC_H264;
  } else if (mjpegClients.size > 0) {
    desired = CODEC_MJPEG;
  }

  if (desired === null || !state.connected) {
    return;
  }
  if (state.lastRequestedCodec === desired) {
    return;
  }

  state.lastRequestedCodec = desired;
  log(`Requesting codec ${desired === CODEC_H264 ? 'H.264' : 'MJPEG'} from host`);
  sendStreamConfig(desired);
}

function processTcpMessages() {
  while (tcpRxBuffer.length >= 5) {
    const msgType = tcpRxBuffer.readUInt8(0);
    const msgLen = tcpRxBuffer.readUInt32LE(1);

    if (msgLen > 1024 * 1024) {
      // The stream is out of sync; carrying on would parse garbage.
      setLastError(`Refusing oversized control payload (${msgLen} bytes)`);
      tcpRxBuffer = Buffer.alloc(0);
      if (tcpSocket) tcpSocket.destroy();
      return;
    }

    if (tcpRxBuffer.length < 5 + msgLen) {
      return;
    }

    const payload = tcpRxBuffer.subarray(5, 5 + msgLen);
    tcpRxBuffer = tcpRxBuffer.subarray(5 + msgLen);

    handleControlMessage(msgType, payload);
  }
}

function handleControlMessage(type, payload) {
  if (type === MSG_HELLO_ACK) {
    // Older hosts stop after monitor_count; newer ones add host_name[64].
    if (payload.length >= 68) {
      state.hostName = payload.subarray(4, 68).toString('utf8').replace(/\0.*$/su, '').trim();
    }
    // ...and newer still a flags byte.
    const flags = payload.length >= 69 ? payload.readUInt8(68) : 0;
    state.viewOnly = (flags & HOST_FLAG_VIEW_ONLY) !== 0;
    state.virtualDisplays = (flags & HOST_FLAG_VIRTUAL_DISPLAYS) !== 0;
    if (state.viewOnly) log('The host is view-only: input is not forwarded');
    state.pinRequired = false;
  } else if (type === MSG_HELLO_REJECT) {
    const reason = payload.length >= 1 ? payload.readUInt8(0) : 0;
    state.rejectReason = reason;
    state.pinRequired = reason === 1 || reason === 2 || (reason === 4 && state.pinRequired);
    setLastError(REJECT_REASONS[reason] || `The host refused the connection (reason ${reason}).`);
    // Only the user can fix a PIN problem: this attempt is over. (The host
    // closes right after; 'close' retries only a full host.)
    if (reason !== 3) state.wantConnected = false;
  } else if (type === MSG_MONITOR_LIST) {
    state.pinRequired = false;
    parseMonitorList(payload);
  } else if (type === MSG_STREAM_START) {
    if (payload.length >= 6) {
      state.stream.monitorId = payload.readUInt8(0);
      state.stream.width = payload.readUInt16LE(1);
      state.stream.height = payload.readUInt16LE(3);
      state.stream.codec = payload.readUInt8(5);
      log(
        `STREAM_START monitor=${state.stream.monitorId} ` +
        `${state.stream.width}x${state.stream.height} codec=${state.stream.codec}`
      );
    }
  }
}

function parseMonitorList(payload) {
  if (!payload || payload.length < 1) {
    return;
  }

  const count = payload.readUInt8(0);
  const monitors = [];
  let offset = 1;

  for (let i = 0; i < count; i += 1) {
    if (offset + 70 > payload.length) {
      break;
    }

    const id = payload.readUInt8(offset);
    const width = payload.readUInt16LE(offset + 1);
    const height = payload.readUInt16LE(offset + 3);
    const refreshRate = payload.readUInt8(offset + 5);
    const name = payload
      .subarray(offset + 6, offset + 70)
      .toString('utf8')
      .replace(/\0.*$/u, '')
      .trim();

    monitors.push({ id, width, height, refreshRate, name, virtual: false, primary: false });
    offset += 70;
  }
  // Newer hosts append one MONITOR_FLAG_* byte per monitor.
  if (payload.length >= offset + monitors.length) {
    monitors.forEach((m, i) => {
      const f = payload.readUInt8(offset + i);
      m.virtual = (f & MONITOR_FLAG_VIRTUAL) !== 0;
      m.primary = (f & MONITOR_FLAG_PRIMARY) !== 0;
    });
  }

  state.monitors = monitors;
  log(`Received monitor list (${monitors.length})`);

  // Set the codec before selecting a monitor so the very first stream starts
  // with the right encoder (the host snapshots stream config at start time).
  negotiateCodec();

  const selected = monitors.find((m) => m.id === state.monitorId);
  if (selected) {
    sendMonitorSelect(selected.id);
  } else if (monitors.length > 0) {
    sendMonitorSelect(monitors[0].id);
  }
}

function onUdpPacket(packet) {
  if (!packet || packet.length < VIDEO_HEADER_SIZE) {
    return;
  }

  const monitorId = packet.readUInt8(0);
  const frameNum = packet.readUInt32LE(1);
  const chunkIdx = packet.readUInt16LE(5);
  const chunkCnt = packet.readUInt16LE(7);
  const chunkData = packet.subarray(VIDEO_HEADER_SIZE);

  // Reject a header that cannot describe a real chunk before it is used to
  // index the chunk array.
  if (chunkCnt === 0 || chunkIdx >= chunkCnt) {
    return;
  }

  // Key on monitor AND frame number: the host numbers frames per monitor, so
  // keying on the frame number alone interleaves chunks from two monitors into
  // one corrupt frame as soon as more than one stream is running.
  const key = `${monitorId}:${frameNum}`;

  let entry = frameBuffer.get(key);
  if (entry && entry.total !== chunkCnt) {
    // Stale entry from a restarted stream that reused this frame number.
    frameBuffer.delete(key);
    entry = undefined;
  }
  if (!entry) {
    entry = {
      monitorId,
      total: chunkCnt,
      chunks: new Array(chunkCnt),
      received: 0,
      createdMs: Date.now(),
    };
    frameBuffer.set(key, entry);
  }

  if (!entry.chunks[chunkIdx]) {
    entry.chunks[chunkIdx] = chunkData;
    entry.received += 1;
  }

  if (entry.received >= entry.total) {
    const fullFrame = Buffer.concat(entry.chunks.filter(Boolean));
    frameBuffer.delete(key);

    if (isJpegFrame(fullFrame)) {
      // MJPEG: feeds the 2D preview (<img>/multipart) and /frame.jpg.
      state.latestFrame = fullFrame;
      state.latestFrameSeq = frameNum;
      pushFrameToMjpegClients(fullFrame);
    } else {
      // Encoded video (H.264 Annex-B): goes to the WebCodecs/VR readers.
      pushFrameToVideoClients(fullFrame, isAnnexBKeyframe(fullFrame) ? 1 : 0);
    }

    cleanupFrameBuffer();
  }
}

// Scan an H.264 Annex-B access unit for an IDR (NAL type 5) or SPS (type 7),
// either of which marks a point a decoder can start from.
function isAnnexBKeyframe(buffer) {
  for (let i = 0; i + 4 < buffer.length; i += 1) {
    if (buffer[i] === 0x00 && buffer[i + 1] === 0x00 && buffer[i + 2] === 0x01) {
      const nalType = buffer[i + 3] & 0x1f;
      if (nalType === 5 || nalType === 7) {
        return true;
      }
      i += 2;
    }
  }
  return false;
}

// Drop partial frames that will never complete. Age-based rather than
// frame-number based: keys are now per monitor, and a stream that dies
// mid-frame would otherwise leak its chunks for the life of the process.
function cleanupFrameBuffer() {
  const cutoff = Date.now() - 5000;
  for (const [key, entry] of frameBuffer) {
    if (entry.createdMs < cutoff) {
      frameBuffer.delete(key);
    }
  }
}

function isJpegFrame(buffer) {
  return (
    buffer.length > 4 &&
    buffer[0] === 0xff &&
    buffer[1] === 0xd8 &&
    buffer[2] === 0xff
  );
}

function pushFrameToMjpegClients(frameBufferData) {
  if (mjpegClients.size === 0) {
    return;
  }

  const header = Buffer.from(
    `--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${frameBufferData.length}\r\n\r\n`,
    'utf8'
  );

  for (const res of mjpegClients) {
    // Every JPEG stands alone, so a lagging reader just skips frames.
    if (res.writableLength > MAX_CLIENT_BACKLOG) continue;
    try {
      res.write(header);
      res.write(frameBufferData);
      res.write('\r\n');
    } catch (_) {
      mjpegClients.delete(res);
    }
  }
}

// Frame the Annex-B access unit for the binary /stream.h264 readers as
// [uint32 LE payload length][uint8 flags][payload]. flags bit0 = keyframe.
function pushFrameToVideoClients(frame, flags) {
  if (videoClients.size === 0) {
    return;
  }

  const header = Buffer.allocUnsafe(5);
  header.writeUInt32LE(frame.length, 0);
  header.writeUInt8(flags, 4);

  for (const res of videoClients) {
    // H.264 frames depend on each other: once a reader falls behind, skip
    // until the next keyframe so it resyncs cleanly instead of smearing.
    if (res.writableLength > MAX_CLIENT_BACKLOG) res.im2WaitKey = true;
    if (res.im2WaitKey) {
      if (!(flags & 1) || res.writableLength > MAX_CLIENT_BACKLOG) continue;
      res.im2WaitKey = false;
    }
    try {
      res.write(header);
      res.write(frame);
    } catch (_) {
      videoClients.delete(res);
    }
  }
}

// --- Input from the browser --------------------------------------------------
// The browser sends where its pointer is on the screen as u,v (0..1), so a
// resolution change on the host between the two cannot misplace a click; the
// bridge turns that into stream pixels of the current stream. Each input
// source (one WebSocket, or the POST fallback) remembers what it holds down so
// a closed tab never leaves a button or key pressed on the PC.

function newInputSource() {
  return { buttons: 0, monitorId: 0, x: 0, y: 0, keys: new Set() };
}

function inputLive() {
  return state.connected && !state.viewOnly &&
    state.stream.monitorId !== null && state.stream.width > 0;
}

function sendMouse(src, x, y, buttons, scroll, scrollH) {
  const payload = Buffer.alloc(10);
  payload.writeUInt8(src.monitorId & 0xff, 0);
  payload.writeUInt16LE(x, 1);
  payload.writeUInt16LE(y, 3);
  payload.writeUInt8(buttons & 0xff, 5);
  payload.writeInt16LE(scroll, 6);
  payload.writeInt16LE(scrollH, 8);
  sendControlMessage(MSG_INPUT_MOUSE, payload);
}

function sendKey(src, vk, pressed) {
  const payload = Buffer.alloc(5);
  payload.writeUInt8(src.monitorId & 0xff, 0);
  payload.writeUInt16LE(vk, 1);
  payload.writeUInt8(pressed ? 1 : 0, 3);
  payload.writeUInt8(0, 4); // modifiers travel as their own key events
  sendControlMessage(MSG_INPUT_KEYBOARD, payload);
}

const clampInt = (v, lo, hi) => Math.min(hi, Math.max(lo, Math.round(Number(v) || 0)));

// ev: { t: 'm', u, v, b, sy, sx } pointer (b = button mask: 1 left, 2 right,
// 4 middle; sy/sx = wheel units, 120 a notch) or { t: 'k', vk, p } key.
function handleInputEvent(src, ev) {
  if (!ev || typeof ev !== 'object' || !inputLive()) return;
  if (ev.t === 'm') {
    const { width, height } = state.stream;
    src.monitorId = state.stream.monitorId;
    src.x = clampInt(Number(ev.u) * (width - 1), 0, width - 1);
    src.y = clampInt(Number(ev.v) * (height - 1), 0, height - 1);
    src.buttons = clampInt(ev.b, 0, 7);
    sendMouse(src, src.x, src.y, src.buttons, clampInt(ev.sy, -32768, 32767), clampInt(ev.sx, -32768, 32767));
  } else if (ev.t === 'k') {
    const vk = clampInt(ev.vk, 0, 255);
    if (vk === 0) return;
    src.monitorId = state.stream.monitorId;
    if (ev.p) src.keys.add(vk); else src.keys.delete(vk);
    sendKey(src, vk, Boolean(ev.p));
  }
}

function releaseInput(src) {
  if (!state.connected) return;
  if (src.buttons) sendMouse(src, src.x, src.y, 0, 0, 0);
  for (const vk of src.keys) sendKey(src, vk, false);
  src.buttons = 0;
  src.keys.clear();
}

// Minimal RFC 6455 server side: the browser only ever sends small text frames
// (JSON input events); we answer pings and closes and never send data.
function acceptWebSocket(req, socket) {
  const key = req.headers['sec-websocket-key'];
  if (!key || String(req.headers.upgrade).toLowerCase() !== 'websocket') {
    socket.destroy();
    return;
  }
  const accept = crypto.createHash('sha1')
    .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n' +
               `Connection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.setNoDelay(true);

  const src = newInputSource();
  let buf = Buffer.alloc(0);
  const done = () => releaseInput(src);
  socket.on('close', done);
  socket.on('error', () => socket.destroy());
  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 2) {
      const op = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0;
      let len = buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        socket.destroy(); // no input event is anywhere near 64 KB
        return;
      }
      if (buf.length < off + (masked ? 4 : 0) + len) return;
      const data = Buffer.from(buf.subarray(off + (masked ? 4 : 0), off + (masked ? 4 : 0) + len));
      if (masked) {
        for (let i = 0; i < data.length; i += 1) data[i] ^= buf[off + (i & 3)];
      }
      buf = buf.subarray(off + (masked ? 4 : 0) + len);
      if (op === 0x8) {        // close
        socket.end(Buffer.from([0x88, 0x00]));
        return;
      }
      if (op === 0x9) {        // ping -> pong
        socket.write(Buffer.concat([Buffer.from([0x8a, data.length]), data]));
      } else if (op === 0x1) { // text
        try {
          handleInputEvent(src, JSON.parse(data.toString('utf8')));
        } catch (_) {
          // a malformed event is dropped, not fatal
        }
      }
    }
  });
}

// POST /api/input: the fallback when a WebSocket can't be opened. One shared
// source: there is no socket to notice a closed tab by.
const httpInput = newInputSource();

function sendJson(res, statusCode, payload) {
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(payload));
}

function parseJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      if (chunks.length === 0) {
        resolve({});
        return;
      }

      try {
        const data = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        resolve(data);
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

function getPublicStatus() {
  return {
    host: state.host,
    tcpPort: state.tcpPort,
    udpPort: state.udpPort,
    monitorId: state.monitorId,
    connected: state.connected,
    monitors: state.monitors,
    stream: state.stream,
    latestFrameSeq: state.latestFrameSeq,
    hasFrame: Boolean(state.latestFrame),
    lastError: state.lastError,
    hostName: state.hostName,
    viewOnly: state.viewOnly,
    virtualDisplays: state.virtualDisplays,
    pinRequired: state.pinRequired,
    rejectReason: state.rejectReason,
    hasPin: state.pin > 0,
    wantConnected: state.wantConnected,
    headsetUrls: headsetUrls(),
    requestedCodec: state.lastRequestedCodec,
    videoClients: videoClients.size,
    mjpegClients: mjpegClients.size,
  };
}

function contentTypeFor(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  if (ext === '.html') return 'text/html; charset=utf-8';
  if (ext === '.css') return 'text/css; charset=utf-8';
  if (ext === '.js') return 'application/javascript; charset=utf-8';
  if (ext === '.json') return 'application/json; charset=utf-8';
  if (ext === '.svg') return 'image/svg+xml';
  if (ext === '.png') return 'image/png';
  if (ext === '.jpg' || ext === '.jpeg') return 'image/jpeg';
  if (ext === '.woff2') return 'font/woff2';
  if (ext === '.txt') return 'text/plain; charset=utf-8';
  return 'application/octet-stream';
}

function handleStaticRequest(req, res, requestPath) {
  const relative = requestPath === '/' ? '/index.html' : requestPath;
  const normalized = path.normalize(relative).replace(/^([\\/])+/, '');
  const filePath = path.join(clientDir, normalized);

  if (!filePath.startsWith(clientDir + path.sep)) {
    sendJson(res, 400, { error: 'Invalid path' });
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      sendJson(res, 404, { error: 'Not found' });
      return;
    }

    res.writeHead(200, {
      'Content-Type': contentTypeFor(filePath),
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
}

// --- Access gate ------------------------------------------------------------
// The bridge reaches the host from 127.0.0.1, which the host lets in without
// a PIN, and re-serves the desktop over HTTP. Open to the whole LAN, that
// would hand anyone on the network a live view of the screen (and the host's
// PIN would be pointless). So, like Jupyter: the PC itself is always allowed,
// anything else needs the random key printed at startup (then a cookie).
const accessKey = crypto.randomBytes(12).toString('base64url');
let openAccess = false;

function isLoopback(address) {
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

function sameKey(candidate) {
  const a = Buffer.from(String(candidate || ''));
  const b = Buffer.from(accessKey);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// Whether a request may go through: the PC itself, the key, or its cookie.
function allowed(req, parsed) {
  if (openAccess || isLoopback(req.socket.remoteAddress)) return true;
  if (sameKey(parsed.searchParams.get('key'))) return true;
  const cookie = /(?:^|;\s*)im2key=([^;]+)/u.exec(req.headers.cookie || '');
  return Boolean(cookie && sameKey(cookie[1]));
}

// A page from another site must not drive the bridge: its requests would
// ride on the PC's own loopback (or the headset's cookie) and could click and
// type on the PC. Browsers always send Origin on WebSocket handshakes and on
// cross-site POSTs; it must name this bridge. (Tools like curl send none.)
function sameOrigin(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  try {
    return new URL(origin).host === String(req.headers.host || '');
  } catch (_) {
    return false;
  }
}

function authorize(req, res, parsed) {
  if (allowed(req, parsed)) {
    if (sameKey(parsed.searchParams.get('key'))) {
      res.setHeader('Set-Cookie', `im2key=${accessKey}; Path=/; HttpOnly; SameSite=Strict`);
    }
    return true;
  }
  res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end('Immersive-2 web bridge: open the address the bridge printed at startup ' +
          '(it ends in ?key=...), or the page on the PC itself.\n');
  return false;
}

// Addresses to type on the headset, one per LAN interface.
function headsetUrls() {
  const urls = [];
  for (const addrs of Object.values(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family === 'IPv4' && !a.internal) {
        urls.push(`http://${a.address}:${state.bridgePort}/vr.html` + (openAccess ? '' : `?key=${accessKey}`));
      }
    }
  }
  return urls;
}

const server = http.createServer(async (req, res) => {
  const parsed = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (req.method !== 'GET' && req.method !== 'HEAD' && !sameOrigin(req)) {
    sendJson(res, 403, { error: 'cross-site request refused' });
    return;
  }
  if (!authorize(req, res, parsed)) return;

  if (req.method === 'GET' && parsed.pathname === '/api/status') {
    sendJson(res, 200, getPublicStatus());
    return;
  }

  if (req.method === 'POST' && parsed.pathname === '/api/connect') {
    try {
      const body = await parseJsonBody(req);
      state.host = body.host || state.host;
      state.tcpPort = Number(body.tcpPort || state.tcpPort);
      state.udpPort = Number(body.udpPort || state.udpPort);
      state.monitorId = Number(body.monitorId ?? state.monitorId);
      if (body.pin !== undefined) {
        const pin = parsePin(body.pin);
        if (pin === null) {
          sendJson(res, 400, { ok: false, error: 'The PIN is the 6 digits printed by the host.' });
          return;
        }
        state.pin = pin;
      }

      connectHost();
      sendJson(res, 200, { ok: true, status: getPublicStatus() });
    } catch (err) {
      sendJson(res, 400, { ok: false, error: err.message });
    }
    return;
  }

  if (req.method === 'POST' && parsed.pathname === '/api/disconnect') {
    state.wantConnected = false;
    disconnectHost();
    sendJson(res, 200, { ok: true, status: getPublicStatus() });
    return;
  }

  if (req.method === 'POST' && parsed.pathname === '/api/select-monitor') {
    try {
      const body = await parseJsonBody(req);
      const monitorId = Number(body.monitorId);
      if (Number.isNaN(monitorId)) {
        sendJson(res, 400, { ok: false, error: 'monitorId is required' });
        return;
      }

      sendMonitorSelect(monitorId);
      sendJson(res, 200, { ok: true, status: getPublicStatus() });
    } catch (err) {
      sendJson(res, 400, { ok: false, error: err.message });
    }
    return;
  }

  if (req.method === 'POST' && parsed.pathname === '/api/input') {
    try {
      const body = await parseJsonBody(req);
      for (const ev of Array.isArray(body) ? body : [body]) handleInputEvent(httpInput, ev);
      sendJson(res, 200, { ok: true, applied: inputLive() });
    } catch (err) {
      sendJson(res, 400, { ok: false, error: err.message });
    }
    return;
  }

  if (req.method === 'GET' && parsed.pathname === '/frame.jpg') {
    if (!state.latestFrame) {
      sendJson(res, 404, { error: 'No frame available yet' });
      return;
    }

    res.writeHead(200, {
      'Content-Type': 'image/jpeg',
      'Cache-Control': 'no-store',
    });
    res.end(state.latestFrame);
    return;
  }

  if (req.method === 'GET' && parsed.pathname === '/stream.h264') {
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
      Pragma: 'no-cache',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    // Low latency: flush each frame immediately rather than coalescing.
    if (res.socket) {
      res.socket.setNoDelay(true);
    }

    videoClients.add(res);
    // Switch the host to H.264 and ask for an IDR so this reader can start
    // decoding right away instead of waiting for the next GOP boundary.
    negotiateCodec();
    sendRequestKeyframe(state.monitorId);

    req.on('close', () => {
      videoClients.delete(res);
      // No more H.264 readers — fall back to MJPEG for the 2D preview.
      negotiateCodec();
    });
    return;
  }

  if (req.method === 'GET' && parsed.pathname === '/stream.mjpg') {
    res.writeHead(200, {
      'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
      Pragma: 'no-cache',
      Connection: 'keep-alive',
    });

    mjpegClients.add(res);
    negotiateCodec();

    if (state.latestFrame) {
      pushFrameToMjpegClients(state.latestFrame);
    }

    req.on('close', () => {
      mjpegClients.delete(res);
    });
    return;
  }

  handleStaticRequest(req, res, parsed.pathname);
});

// Input WebSocket at /input, behind the same access rules as every page.
server.on('upgrade', (req, socket) => {
  const parsed = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  if (parsed.pathname !== '/input' || !sameOrigin(req) || !allowed(req, parsed)) {
    socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
    return;
  }
  acceptWebSocket(req, socket);
});

function main() {
  const options = parseArgs(process.argv);
  state.bridgePort = options.bridgePort;
  state.host = options.host;
  state.tcpPort = options.tcpPort;
  state.udpPort = options.udpPort;
  state.monitorId = options.monitorId;
  state.pin = options.pin;
  openAccess = options.open;

  server.listen(state.bridgePort, () => {
    log(`Web bridge listening on http://0.0.0.0:${state.bridgePort}`);
    log(`Serving static client from ${clientDir}`);
    log(`On this PC: http://localhost:${state.bridgePort}/`);
    for (const url of headsetUrls()) {
      log(`On the headset: ${url}`);
    }

    if (options.autoConnect) {
      connectHost();
    }
  });

  process.on('SIGINT', () => {
    log('Shutting down...');
    disconnectHost(false);
    server.close(() => process.exit(0));
  });
}

main();
