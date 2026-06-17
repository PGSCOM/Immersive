#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');
const net = require('net');
const dgram = require('dgram');

const PROTOCOL_VERSION = 1;

const MSG_HELLO = 0x01;
const MSG_MONITOR_LIST = 0x03;
const MSG_MONITOR_SELECT = 0x04;
const MSG_STREAM_START = 0x05;
const MSG_STREAM_CONFIG = 0x21;
const MSG_REQUEST_KEYFRAME = 0x31;

const VIDEO_HEADER_SIZE = 9;

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
    } else if (arg === '--connect') {
      options.autoConnect = true;
    }
  }

  return options;
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
  bindUdpSocket();

  tcpSocket = new net.Socket();
  tcpSocket.setNoDelay(true);

  tcpSocket.on('connect', () => {
    state.connected = true;
    state.lastError = null;
    state.lastRequestedCodec = null;
    tcpRxBuffer = Buffer.alloc(0);
    log(`Connected to host ${state.host}:${state.tcpPort}`);
    sendHello();
  });

  tcpSocket.on('data', (chunk) => {
    tcpRxBuffer = Buffer.concat([tcpRxBuffer, chunk]);
    processTcpMessages();
  });

  tcpSocket.on('error', (err) => {
    state.connected = false;
    setLastError(`TCP error: ${err.message}`);
  });

  tcpSocket.on('close', () => {
    state.connected = false;
    log('TCP connection closed');
  });

  tcpSocket.connect(state.tcpPort, state.host);
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

function sendHello() {
  const payload = Buffer.alloc(33);
  payload.writeUInt8(PROTOCOL_VERSION, 0);
  Buffer.from('Immersive-2 Web Bridge', 'utf8').copy(payload, 1, 0, 32);
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
      setLastError(`Refusing oversized control payload (${msgLen} bytes)`);
      tcpRxBuffer = Buffer.alloc(0);
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
  if (type === MSG_MONITOR_LIST) {
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

    monitors.push({ id, width, height, refreshRate, name });
    offset += 70;
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

  if (!frameBuffer.has(frameNum)) {
    frameBuffer.set(frameNum, {
      monitorId,
      total: chunkCnt,
      chunks: new Array(chunkCnt),
      received: 0,
    });
  }

  const entry = frameBuffer.get(frameNum);
  if (!entry) {
    return;
  }

  if (!entry.chunks[chunkIdx]) {
    entry.chunks[chunkIdx] = chunkData;
    entry.received += 1;
  }

  if (entry.received >= entry.total) {
    const fullFrame = Buffer.concat(entry.chunks.filter(Boolean));
    frameBuffer.delete(frameNum);

    if (isJpegFrame(fullFrame)) {
      // MJPEG: feeds the 2D preview (<img>/multipart) and /frame.jpg.
      state.latestFrame = fullFrame;
      state.latestFrameSeq = frameNum;
      pushFrameToMjpegClients(fullFrame);
    } else {
      // Encoded video (H.264 Annex-B): goes to the WebCodecs/VR readers.
      pushFrameToVideoClients(fullFrame, isAnnexBKeyframe(fullFrame) ? 1 : 0);
    }

    cleanupFrameBuffer(frameNum);
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

function cleanupFrameBuffer(currentFrame) {
  for (const key of frameBuffer.keys()) {
    if (key < currentFrame - 20) {
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
    try {
      res.write(header);
      res.write(frame);
    } catch (_) {
      videoClients.delete(res);
    }
  }
}

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
  return 'application/octet-stream';
}

function handleStaticRequest(req, res, requestPath) {
  const relative = requestPath === '/' ? '/index.html' : requestPath;
  const normalized = path.normalize(relative).replace(/^([\\/])+/, '');
  const filePath = path.join(clientDir, normalized);

  if (!filePath.startsWith(clientDir)) {
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

const server = http.createServer(async (req, res) => {
  const parsed = new URL(req.url, `http://${req.headers.host || 'localhost'}`);

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

      connectHost();
      sendJson(res, 200, { ok: true, status: getPublicStatus() });
    } catch (err) {
      sendJson(res, 400, { ok: false, error: err.message });
    }
    return;
  }

  if (req.method === 'POST' && parsed.pathname === '/api/disconnect') {
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

function main() {
  const options = parseArgs(process.argv);
  state.bridgePort = options.bridgePort;
  state.host = options.host;
  state.tcpPort = options.tcpPort;
  state.udpPort = options.udpPort;
  state.monitorId = options.monitorId;

  server.listen(state.bridgePort, () => {
    log(`Web bridge listening on http://0.0.0.0:${state.bridgePort}`);
    log(`Serving static client from ${clientDir}`);

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
