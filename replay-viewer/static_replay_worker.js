'use strict';
// The replay Worker: owns the wasm runtime and the OffscreenCanvas, so the
// page thread never blocks while the module indexes 600 ticks of recorded
// state.
//
// broadcast_core.js is shared with the page shell and publishes through
// `window`; a classic Worker can provide that alias without a second bundle.
self.window = self;

// NON-MODULARIZED BOOTSTRAP. replay-viewer/config.nims links WITHOUT
// `-s MODULARIZE=1` and without `-s EXPORT_NAME`, so the emitted script
// patches this pre-declared `Module` object and calls
// `Module.onRuntimeInitialized` when the runtime is up. The link flags and
// this bootstrap are a MATCHED PAIR: a babel-lineage shell calls a factory
// `<X>(Module)`, a paintbot-lineage shell waits for onRuntimeInitialized, and
// a mixture throws nothing, logs nothing and hangs on "Loading replay..."
// forever (cogame-lantern, 2026-08-23).
var Module = {};
var runtimeReady = false;
var initMessage = null;
var runtimeLoaded = false;
var core = null;
var minimapSurface = null;
var failed = false;
var disposed = false;
var tickCount = 0;
var cursor = 0;
var meta = null;
var art = {};

function decodeString(pointer, length) {
  if (!pointer || !length) return '';
  return new TextDecoder().decode(Module.HEAPU8.slice(pointer, pointer + length));
}

function stageNote() {
  // The fixed progress buffer survives an ABORTING_MALLOC failure even though
  // the Emscripten call stack does not.
  try {
    var length = Module._mg_stage_len ? Module._mg_stage_len() : 0;
    if (!length) return '';
    return decodeString(Module._mg_stage_ptr(), length);
  } catch (ignored) {
    return '';
  }
}

function runtimeError() {
  var text = decodeString(Module._mg_error_ptr(), Module._mg_error_len());
  if (text) return text;
  var stage = stageNote();
  return stage
    ? 'Replay runtime failed while: ' + stage
    : 'Replay runtime rejected the replay';
}

function reportFailure(error) {
  if (failed || disposed) return;
  failed = true;
  postMessage({
    type: 'error',
    message: (error && error.message) ? error.message : String(error),
    stage: stageNote()
  });
}

function copyIntoRuntime(bytes, callback) {
  var pointer = Module._malloc(bytes.length);
  try {
    Module.HEAPU8.set(bytes, pointer);
    return callback(pointer, bytes.length);
  } finally {
    Module._free(pointer);
  }
}

// The platform stores the PUBLIC replay copy as gzip bytes when the manifest
// declares replay_compression (no Content-Encoding, unchanged URL), and the
// wasm module has no inflate of its own, so the Worker inflates here. The
// format is sniffed from the CONTENT (0x1f 0x8b gzip, 0x78 zlib), never from
// the URL suffix or a response header.
async function inflate(bytes, format) {
  var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream(format));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

function currentPacket() {
  return JSON.parse(decodeString(Module._mg_packet_ptr(), Module._mg_packet_len()));
}

function packetAt(tick) {
  var got = Module._mg_frame(tick);
  if (got < 0) throw new Error(runtimeError());
  return currentPacket();
}

async function loadArt(base, files) {
  var names = Object.keys(files);
  await Promise.all(names.map(async function (name) {
    try {
      var response = await fetch(new URL(files[name], base).toString());
      if (!response.ok) return;
      art[name] = await createImageBitmap(await response.blob());
    } catch (ignored) {
      // Art is real but not load-bearing: the board falls back to flat shapes
      // rather than showing nothing at all.
    }
  }));
}

function artFiles(variant) {
  var wire = self.MATRIX_WIRE || {};
  var spec = (wire.variants && wire.variants[variant]) || null;
  var manifest = spec ? spec.art : null;
  var files = {};
  if (!manifest) return files;
  files.floor = manifest.floor;
  files.wallH = manifest.wallH;
  files.wallV = manifest.wallV;
  files.burst = manifest.burst;
  files.spark = manifest.spark;
  Object.keys(manifest.rigs).forEach(function (livery) {
    Object.keys(manifest.rigs[livery]).forEach(function (pose) {
      files['rig_' + livery + '_' + pose] = manifest.rigs[livery][pose];
    });
    files['beam_' + livery] = manifest.beams[livery];
  });
  manifest.tokens.forEach(function (path, index) {
    files['token_' + index] = path;
  });
  return files;
}

async function start() {
  if (!runtimeReady || !initMessage || runtimeLoaded || failed || disposed) return;
  var message = initMessage;
  initMessage = null;
  try {
    postMessage({ type: 'phase', phase: 'replay_fetch_start' });
    var response = await fetch(message.replayUrl, { credentials: 'omit', mode: 'cors' });
    if (!response.ok) throw new Error('Replay request returned HTTP ' + response.status);
    var bytes = new Uint8Array(await response.arrayBuffer());
    if (!bytes.length) throw new Error('Replay response was empty');
    var gzip = bytes[0] === 0x1f && bytes[1] === 0x8b;
    var zlib = bytes[0] === 0x78;
    postMessage({ type: 'phase', phase: 'replay_fetch_end',
                  bytes: bytes.byteLength, compressed: gzip || zlib });
    if (gzip) bytes = await inflate(bytes, 'gzip');
    else if (zlib) bytes = await inflate(bytes, 'deflate');
    var ok = copyIntoRuntime(bytes, function (pointer, length) {
      return Module._mg_load_replay(pointer, length);
    });
    if (!ok) throw new Error(runtimeError());
    runtimeLoaded = true;
    postMessage({ type: 'phase', phase: 'replay_parsed' });
    // Read the packet mg_load_replay just built: it is the ONLY packet that
    // carries `meta` (renderCurrent emits it once, on the first build). Going
    // through packetAt(0) here would call mg_frame(0), rebuild the packet
    // with firstPacketDone=true, and lose the meta — the starter's worker
    // likewise ingests after load without calling _ctf_frame first.
    var first = currentPacket();
    meta = first.meta;
    tickCount = Math.max(1, first.s.mx);
    await loadArt(self.location.href, artFiles(meta.variant));
    core = self.MatrixBroadcastCore.create({
      canvas: message.canvas,
      viewportWidth: message.width,
      viewportHeight: message.height,
      devicePixelRatio: message.dpr,
      art: art,
      wire: self.MATRIX_WIRE || {},
      meta: meta,
      onFirstFrame: function () { postMessage({ type: 'firstFrame' }); },
      onTransform: function (t) { postMessage({ type: 'transform', transform: t }); }
    });
    if (minimapSurface) core.attachMinimap(minimapSurface);
    core.setViewportSize(message.width, message.height, message.dpr);
    core.ingest(first);
    cursor = 0;
    postMessage({ type: 'meta', meta: first.meta });
    postMessage({
      type: 'loaded', tickCount: tickCount, mismatchTick: -1, frame: first
    });
  } catch (error) {
    reportFailure(error);
  }
}

function show(tick) {
  cursor = Math.max(0, Math.min(tickCount - 1, tick));
  var payload = packetAt(cursor);
  core.ingest(payload);
  return payload;
}

function advance(frames) {
  if (!runtimeLoaded || failed || disposed) return;
  try {
    var count = Math.max(1, Math.min(64, Number(frames) || 1));
    var payload = show(cursor + count);
    postMessage({
      type: 'advanced', tick: cursor, frame: payload,
      atEnd: cursor >= tickCount - 1,
      draws: core ? core.getPaceStats().draws : 0
    });
  } catch (error) {
    reportFailure(error);
  }
}

Module.locateFile = function (path) {
  return new URL(path, self.location.href).toString();
};
Module.onAbort = function (what) {
  var stage = stageNote();
  reportFailure(new Error('Replay runtime ran out of memory (' + what +
    ') - wasm32 is limited to 2 GB' + (stage ? '. Failed while: ' + stage : '')));
};
Module.onRuntimeInitialized = function () {
  runtimeReady = true;
  postMessage({ type: 'phase', phase: 'bundle_ready' });
  start();
};
self.Module = Module;

self.onmessage = function (event) {
  var message = event.data || {};
  try {
    if (message.type === 'init') {
      initMessage = message;
      start();
    } else if (message.type === 'advance') {
      advance(message.frames);
    } else if (message.type === 'seek' && runtimeLoaded) {
      var payload = show(Number(message.tick) || 0);
      postMessage({
        type: 'advanced', tick: cursor, frame: payload,
        atEnd: cursor >= tickCount - 1,
        draws: core ? core.getPaceStats().draws : 0
      });
    } else if (message.type === 'resize' && core) {
      core.setViewportSize(message.width, message.height, message.dpr);
    } else if (message.type === 'view' && core) {
      if (message.action === 'zoom') core.zoomAt(message.factor, message.x, message.y);
      else if (message.action === 'setZoom') core.setZoom(message.level);
      else if (message.action === 'pan') core.panBy(message.dx, message.dy);
      else if (message.action === 'panMap') core.panByMap(message.dx, message.dy);
      else if (message.action === 'panTo') core.panTo(message.x, message.y);
      else if (message.action === 'reset') core.resetView();
    } else if (message.type === 'minimap') {
      minimapSurface = message.canvas || null;
      if (core && minimapSurface) core.attachMinimap(minimapSurface);
    } else if (message.type === 'dispose') {
      disposed = true;
      if (core) core.stop();
      close();
    }
  } catch (error) {
    reportFailure(error);
  }
};

importScripts('./wire_constants.js', './broadcast_core.js', './matrix_games_replay.js');
