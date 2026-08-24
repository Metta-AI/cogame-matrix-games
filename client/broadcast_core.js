'use strict';
// broadcast_core.js -- the Matrix Games board renderer.
//
// Runs inside the replay Worker on an OffscreenCanvas (and would run on a
// plain canvas unchanged), so it touches no DOM: this file draws the WORLD
// (yard floor, walls, token spawners, eight cogs in their liveries, the
// inventory bars over their heads, beams, resets and pickups) while the
// page's DOM chrome draws the scorebug, the matrix panel, the index line, the
// feed, the transport and the endcard.
//
// One packet per tick comes out of the wasm module:
//   {t, b:{t, c:[x,y,facing,freeze] x8, inv:[8 x K], tok:[0/1 per spawner],
//          sc:[8]},
//    s:<the chrome state frame>, meta:<once, on the first packet>}

(function (scope) {
  var CELL = 40;

  function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }

  function create(config) {
    var canvas = config.canvas;
    var ctx = canvas.getContext('2d', { alpha: false });
    var art = config.art || {};
    var wire = config.wire || {};
    var meta = config.meta || null;
    var packet = null;
    var draws = 0;
    var firstFrameSent = false;
    var beams = [];      // {t, seat, x, y, dir, len, hit}
    var bursts = [];     // {t, x, y}
    var sparks = [];     // {t, x, y, token}
    var viewport = {
      w: config.viewportWidth || 960,
      h: config.viewportHeight || 540,
      dpr: config.devicePixelRatio || 1
    };
    var view = { zoom: 1, focusX: 0, focusY: 0 };
    var minimap = null;
    var minimapCtx = null;

    function boardW() { return (meta && meta.map ? meta.map.w : 24) * CELL; }
    function boardH() { return (meta && meta.map ? meta.map.h : 14) * CELL; }
    function tokenCount() {
      return (meta && meta.config && meta.config.K) ? meta.config.K : 2;
    }
    function tokenCap() {
      return (meta && meta.config && meta.config.tokenCap)
        ? meta.config.tokenCap : 8;
    }
    function liveryOf(slot) {
      if (meta && meta.liveries && meta.liveries[slot]) return meta.liveries[slot];
      var table = wire.liveries || [];
      return table[slot] ? table[slot].key : 'cobalt';
    }
    function colorOf(slot) {
      var table = wire.liveries || [];
      return table[slot] ? table[slot].hex : '#3f7cc4';
    }
    function tokenColor(index) {
      return ['#e0523a', '#3f7cc4', '#45a85e'][index] || '#e0523a';
    }

    function transform() {
      var fit = Math.min(viewport.w / boardW(), viewport.h / boardH());
      var scale = fit * view.zoom;
      return {
        scale: scale,
        offsetX: (viewport.w - boardW() * scale) / 2,
        offsetY: (viewport.h - boardH() * scale) / 2,
        nativeW: boardW(), nativeH: boardH(),
        zoom: view.zoom, minZoom: 1, maxZoom: 4, fitScale: fit,
        focusX: view.focusX, focusY: view.focusY,
        visW: viewport.w / scale, visH: viewport.h / scale
      };
    }

    function setViewportSize(w, h, dpr) {
      viewport = {
        w: Math.max(1, w || viewport.w),
        h: Math.max(1, h || viewport.h),
        dpr: dpr || viewport.dpr
      };
      canvas.width = Math.round(viewport.w * viewport.dpr);
      canvas.height = Math.round(viewport.h * viewport.dpr);
      if (packet) draw();
    }

    // ---- world drawing ----------------------------------------------------

    function drawFloor() {
      if (art.floor) {
        var pattern = ctx.createPattern(art.floor, 'repeat');
        ctx.fillStyle = pattern || '#3a3630';
      } else {
        ctx.fillStyle = '#3a3630';
      }
      ctx.fillRect(0, 0, boardW(), boardH());
    }

    function drawWalls() {
      var rows = (meta && meta.map && meta.map.walls) ? meta.map.walls : [];
      for (var y = 0; y < rows.length; y++) {
        for (var x = 0; x < rows[y].length; x++) {
          if (rows[y][x] !== '#') continue;
          var horizontal = (y === 0 || y === rows.length - 1);
          var tile = horizontal ? art.wallH : art.wallV;
          if (tile) {
            ctx.drawImage(tile, x * CELL, y * CELL, CELL, CELL);
          } else {
            ctx.fillStyle = '#241b14';
            ctx.fillRect(x * CELL, y * CELL, CELL, CELL);
          }
          ctx.strokeStyle = 'rgba(10,7,4,0.55)';
          ctx.lineWidth = 2;
          ctx.strokeRect(x * CELL + 1, y * CELL + 1, CELL - 2, CELL - 2);
        }
      }
    }

    function drawSpawners() {
      if (!meta || !meta.spawners || !packet) return;
      var live = packet.b.tok || [];
      for (var i = 0; i < meta.spawners.length; i++) {
        var s = meta.spawners[i];
        var cx = s.x * CELL + CELL / 2;
        var cy = s.y * CELL + CELL / 2;
        if (!live[i]) {
          // an emptied spawner still reads as a socket, so denial is visible
          ctx.strokeStyle = 'rgba(240,230,210,0.16)';
          ctx.lineWidth = 2;
          ctx.beginPath();
          ctx.arc(cx, cy, 7, 0, Math.PI * 2);
          ctx.stroke();
          continue;
        }
        var sprite = art['token_' + s.token];
        if (sprite) {
          ctx.drawImage(sprite, cx - 11, cy - 11, 22, 22);
        } else {
          ctx.fillStyle = tokenColor(s.token);
          ctx.beginPath();
          ctx.arc(cx, cy, 8, 0, Math.PI * 2);
          ctx.fill();
        }
      }
    }

    function drawBeams(tick) {
      var life = wire.beamDrawTicks || 4;
      for (var i = 0; i < beams.length; i++) {
        var b = beams[i];
        var age = tick - b.t;
        if (age < 0 || age > life) continue;
        var dx = [0, 1, 0, -1][b.dir];
        var dy = [-1, 0, 1, 0][b.dir];
        var x0 = b.x * CELL + CELL / 2;
        var y0 = b.y * CELL + CELL / 2;
        var x1 = x0 + dx * b.len * CELL;
        var y1 = y0 + dy * b.len * CELL;
        ctx.globalAlpha = 1 - age / (life + 1);
        if (b.hit < 0) {
          ctx.strokeStyle = 'rgba(200,190,175,0.5)';
          ctx.lineWidth = 3;
        } else {
          ctx.strokeStyle = colorOf(b.seat);
          ctx.lineWidth = 7;
        }
        ctx.beginPath();
        ctx.moveTo(x0, y0);
        ctx.lineTo(x1, y1);
        ctx.stroke();
        ctx.strokeStyle = 'rgba(255,246,232,0.9)';
        ctx.lineWidth = 2;
        ctx.stroke();
        ctx.globalAlpha = 1;
      }
    }

    function drawEffects(tick) {
      var i, e, age;
      for (i = 0; i < bursts.length; i++) {
        e = bursts[i];
        age = tick - e.t;
        if (age < 0 || age > 12) continue;
        ctx.globalAlpha = 1 - age / 13;
        var size = 26 + age * 3;
        if (art.burst) {
          ctx.drawImage(art.burst, e.x * CELL + CELL / 2 - size / 2,
            e.y * CELL + CELL / 2 - size / 2, size, size);
        } else {
          ctx.strokeStyle = '#ffecce';
          ctx.lineWidth = 3;
          ctx.beginPath();
          ctx.arc(e.x * CELL + CELL / 2, e.y * CELL + CELL / 2, size / 2, 0,
            Math.PI * 2);
          ctx.stroke();
        }
        ctx.globalAlpha = 1;
      }
      for (i = 0; i < sparks.length; i++) {
        e = sparks[i];
        age = tick - e.t;
        if (age < 0 || age > 8) continue;
        ctx.globalAlpha = 1 - age / 9;
        if (art.spark) {
          ctx.drawImage(art.spark, e.x * CELL + 8, e.y * CELL + 8, 24, 24);
        } else {
          ctx.fillStyle = tokenColor(e.token);
          ctx.fillRect(e.x * CELL + 16, e.y * CELL + 16, 8, 8);
        }
        ctx.globalAlpha = 1;
      }
    }

    function poseFor(slot, tick, frozen) {
      if (frozen) return 'hold';
      for (var i = 0; i < beams.length; i++) {
        if (beams[i].seat === slot && tick - beams[i].t >= 0 &&
            tick - beams[i].t <= 3) return 'fire';
      }
      return 'idle';
    }

    function drawCogs(tick) {
      var frame = packet.b;
      var k = tokenCount();
      for (var slot = 0; slot < 8; slot++) {
        var x = frame.c[slot * 4];
        var y = frame.c[slot * 4 + 1];
        var facing = frame.c[slot * 4 + 2];
        var frozen = frame.c[slot * 4 + 3] > 0;
        var px = x * CELL;
        var py = y * CELL;
        var sprite = art['rig_' + liveryOf(slot) + '_' + poseFor(slot, tick, frozen)];
        ctx.globalAlpha = frozen ? 0.55 : 1;
        if (sprite) {
          ctx.drawImage(sprite, px - 4, py - 12, CELL + 8, CELL + 8);
        } else {
          ctx.fillStyle = colorOf(slot);
          ctx.beginPath();
          ctx.arc(px + CELL / 2, py + CELL / 2, 13, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.globalAlpha = 1;
        // Facing pip: which way the beam would go.
        var dx = [0, 1, 0, -1][facing];
        var dy = [-1, 0, 1, 0][facing];
        ctx.fillStyle = '#f2e8d8';
        ctx.beginPath();
        ctx.arc(px + CELL / 2 + dx * 15, py + CELL / 2 + dy * 15, 3, 0,
          Math.PI * 2);
        ctx.fill();
        // INVENTORY BARS -- the headline readout. K slim bars over the cog's
        // head, one per token type in its chrome colour, width proportional
        // to inv[i] / tokenCap. This is what makes commitment visible.
        var barW = CELL - 6;
        for (var i = 0; i < k; i++) {
          var value = frame.inv[slot * k + i];
          var top = py - 11 + i * 4;
          ctx.fillStyle = 'rgba(18,13,9,0.7)';
          ctx.fillRect(px + 3, top, barW, 3);
          ctx.fillStyle = tokenColor(i);
          ctx.fillRect(px + 3, top,
            Math.max(1, barW * clamp(value / tokenCap(), 0, 1)), 3);
        }
      }
    }

    function draw() {
      if (!packet) return;
      var tick = packet.t;
      var t = transform();
      ctx.setTransform(viewport.dpr, 0, 0, viewport.dpr, 0, 0);
      ctx.fillStyle = '#120d09';
      ctx.fillRect(0, 0, viewport.w, viewport.h);
      ctx.save();
      ctx.translate(t.offsetX, t.offsetY);
      ctx.scale(t.scale, t.scale);
      drawFloor();
      drawWalls();
      drawSpawners();
      drawEffects(tick);
      drawCogs(tick);
      drawBeams(tick);
      ctx.restore();
      draws++;
      if (!firstFrameSent) {
        firstFrameSent = true;
        if (config.onFirstFrame) config.onFirstFrame();
        if (config.onTransform) config.onTransform(t);
      }
      if (minimapCtx) drawMinimap();
    }

    function drawMinimap() {
      var scale = Math.min(minimap.width / boardW(), minimap.height / boardH());
      minimapCtx.fillStyle = '#1a140e';
      minimapCtx.fillRect(0, 0, minimap.width, minimap.height);
      var frame = packet.b;
      for (var slot = 0; slot < 8; slot++) {
        minimapCtx.fillStyle = colorOf(slot);
        minimapCtx.fillRect(frame.c[slot * 4] * CELL * scale,
          frame.c[slot * 4 + 1] * CELL * scale,
          Math.max(2, CELL * scale), Math.max(2, CELL * scale));
      }
    }

    function ingest(next) {
      if (next.meta) meta = next.meta;
      packet = next;
      var events = (next.s && next.s.events) || [];
      for (var i = 0; i < events.length; i++) {
        var e = events[i];
        if (e.k === 'beam') {
          beams.push({ t: e.t, seat: e.seat, x: e.x, y: e.y, dir: e.dir,
            len: e.len, hit: e.hitSeat });
          if (beams.length > 64) beams.shift();
        } else if (e.k === 'reset') {
          var slot = e.seat;
          bursts.push({ t: e.t, x: next.b.c[slot * 4], y: next.b.c[slot * 4 + 1] });
          if (bursts.length > 64) bursts.shift();
        } else if (e.k === 'pickup') {
          sparks.push({ t: e.t, x: e.x, y: e.y, token: e.token });
          if (sparks.length > 64) sparks.shift();
        }
      }
      draw();
    }

    return {
      ingest: ingest,
      setMeta: function (next) { meta = next; },
      setViewportSize: setViewportSize,
      attachMinimap: function (surface) {
        minimap = surface;
        minimapCtx = surface ? surface.getContext('2d') : null;
      },
      zoomAt: function (factor) {
        view.zoom = clamp(view.zoom * (factor || 1), 1, 4);
        draw();
      },
      setZoom: function (level) { view.zoom = clamp(level || 1, 1, 4); draw(); },
      panBy: function () {},
      panByMap: function () {},
      panTo: function () {},
      resetView: function () { view.zoom = 1; draw(); },
      getTransform: transform,
      getPaceStats: function () {
        return { enabled: false, queued: 0, presented: draws, interval: 1000 / 24,
          draws: draws };
      },
      stop: function () {}
    };
  }

  scope.MatrixBroadcastCore = { create: create };
})(typeof window !== 'undefined' ? window : self);
