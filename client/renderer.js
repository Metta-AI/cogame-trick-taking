// Trick-taking shared renderer + drivers.
//
// One canvas scene -- a felt card table with four cogs at N/E/S/W in TABLE
// order, every hand fanned face up (spectators see everything), the current
// trick laid toward the centre in play order, a trump indicator, the dealer
// button, the up-card / turn-up beside the kitty, a bid chip and trick pips
// per seat, and each seat's private notes on a parchment beneath it -- fed
// by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle).
//
// All state derivation happens server-side / wasm-side; this file only draws
// state objects of exactly one shape:
//   {module, displayName, hand, hands, dealer, seatOrder, trump, trumpName,
//    upcard, turnup, kitty, discard, maker, alone, broken, passDir, phase,
//    actor, leader, trick, tricks, table:[{slot,card}],
//    seats:[{slot,pos,name,team,hand[],bid,made,tricks,points,net,score,
//            penalty,void[],notes,acting,sittingOut,dealer} x4],
//    teams:[{points,bid,tricks}]|null, tell, handDone, gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  var CARD_RED = "#b03a2a";
  // The trick verdict holds for a beat, then fades to a resting tint so a
  // paused frame still reads.
  var PICK_HOLD_MS = 2000;
  var PICK_FADE_MS = 700;
  var PICK_REST = 0.35;
  var SWEEP_MS = 420;

  var GLYPH_FONT = "'rajdhani', 'Apple Symbols', 'Segoe UI Symbol', " +
    "'Noto Sans Symbols 2', system-ui, sans-serif";
  var UI_FONT = "'rajdhani', system-ui, sans-serif";

  var RANKS = ["2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
    "A"];
  var SUIT_GLYPHS = ["\u2663", "\u2666", "\u2665", "\u2660"];
  var SUIT_NAMES = ["clubs", "diamonds", "hearts", "spades"];

  // Every beat kind buildTrickBeats can emit. ci.yml greps this list against
  // chrome.css and fails if any kind has no rule, so a beat can never render
  // as an unstyled div.
  var BEAT_KINDS = ["trick", "bid", "nil", "trump", "march", "euchred",
    "moon", "void", "end"];

  function suitOf(card) { return card % 4; }
  function rankOf(card) { return Math.floor(card / 4); }

  // Rank ten renders as "10", NEVER "T" -- in prompts and on the canvas.
  function cardGlyph(card) {
    if (typeof card !== "number" || card < 0 || card > 51) return "?";
    return RANKS[rankOf(card)] + SUIT_GLYPHS[suitOf(card)];
  }

  function suitGlyph(suit) {
    return (suit >= 0 && suit < 4) ? SUIT_GLYPHS[suit] : "";
  }

  function suitName(suit) {
    return (suit >= 0 && suit < 4) ? SUIT_NAMES[suit] : "";
  }

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["soldier_red_front.png", "soldier_blue_front.png",
      "soldier_green_front.png", "soldier_yellow_front.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Text that always has somewhere to go --------------------------------
  //
  // A canvas silently accepts a draw at a negative coordinate, which reads as
  // a sliver and is invisible to a load signal, a soak and a screenshot
  // (cogchemists, 2026-08-24). Every string this renderer draws goes through
  // drawText, which ellipsizes to the room it has and then CLAMPS the box
  // inside the canvas, so `viewer_smoke.mjs --strict-text-bounds` can hold
  // `canvas_text.never_inside` at 0 on a fixed arena.
  function drawText(ctx, cv, text, x, y, maxWidth, fontPx, align) {
    if (text === undefined || text === null || text === "") return;
    var room = Math.max(12, Math.min(maxWidth, cv.width - 8));
    var out = ellipsize(ctx, String(text), room);
    var w = ctx.measureText(out).width;
    var left = align === "center" ? x - w / 2 :
      align === "right" ? x - w : x;
    left = Math.max(4, Math.min(left, cv.width - w - 4));
    var top = Math.max(4, Math.min(y, cv.height - fontPx * 1.6 - 4));
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText(out, left, top);
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = String(text).split(/\s+/);
    var lines = [];
    var line = "";
    // A single token wider than the box - a run of suit glyphs, a long id -
    // is the one thing word wrapping cannot place, so it is broken on rune
    // boundaries instead of being cut with an ellipsis.
    function chunks(word) {
      if (ctx.measureText(word).width <= maxWidth) return [word];
      var runes = Array.from(word);
      var out = [];
      var start = 0;
      while (start < runes.length) {
        var take = runes.length - start;
        var piece = runes.slice(start, start + take).join("");
        while (take > 1 && ctx.measureText(piece).width > maxWidth) {
          take = Math.max(1, Math.min(take - 1, Math.floor(take *
            (maxWidth / ctx.measureText(piece).width))));
          piece = runes.slice(start, start + take).join("");
        }
        out.push(piece);
        start += take;
      }
      return out;
    }
    words.forEach(function (word) {
      chunks(word).forEach(function (part) {
        var probe = line ? line + " " + part : part;
        if (ctx.measureText(probe).width > maxWidth && line) {
          lines.push(line);
          line = part;
        } else {
          line = probe;
        }
      });
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  // ---- The card table ------------------------------------------------------

  // Table position -> screen anchor. Clockwise on a clock face is
  // 12 -> 3 -> 6 -> 9, so from the bottom seat clockwise is
  // bottom -> left -> top -> right. Seating the four positions that way is
  // what makes the seeded seating visible on the board.
  var ANCHORS = ["S", "W", "N", "E"];

  // The notes band is derived from the cap the SERVER enforces, not from
  // eye. `notes` is truncated to MaxNotesLen runes (src/tricks/types.nim),
  // so a seat can hand the viewer a 400-rune paragraph at any moment; the
  // parchment reserves room for one of exactly that length, measured in the
  // font the note is drawn in, whether or not the seat has written anything.
  // Undersizing it cuts a model's sentence mid-word, which is the defect
  // this reserve exists to prevent.
  var NOTES_CAP_RUNES = 400;
  // Measuring the cap needs a string of cap length: this alphabet is the one
  // notes are written in (prose, digits, the suit glyphs and the em-dash the
  // prompt uses), and its mean advance in the note font is deliberately
  // wider than running prose, which is mostly lower case and spaces.
  var NOTE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
    "abcdefghijklmnopqrstuvwxyz0123456789 ,.;:'?!-\u2014\u2660\u2665\u2666\u2663";

  function computeLayout(ctx, w, h) {
    var pad = Math.max(6, Math.min(w, h) * 0.02);
    var scale = Math.max(0.55, Math.min(1.25, Math.min(w / 960, h / 640)));
    var cardH = Math.max(26, Math.min(h * 0.13, 74 * scale));
    var cardW = cardH * 0.7;
    var cog = Math.max(26, Math.min(72 * scale, h * 0.12));
    var notePad = 4 * scale;
    var noteLineH = 11 * scale;
    var notePx = Math.round(9.5 * scale);
    // Wide enough that a full-cap note is a paragraph and not a column.
    var noteW = Math.min(w * 0.46, Math.max(w * 0.3, cog * 4.6));
    ctx.save();
    ctx.font = notePx + "px " + UI_FONT;
    var advance = ctx.measureText(NOTE_ALPHABET).width /
      Array.from(NOTE_ALPHABET).length;
    ctx.restore();
    var capW = advance * NOTES_CAP_RUNES;
    // +1 line of slack: wrapping breaks on words, so every line but the last
    // gives up to one word's width back.
    var noteLines = Math.max(2,
      Math.ceil(capW / Math.max(24, noteW - notePad * 2)) + 1);
    var noteH = noteLines * noteLineH + notePad * 2;
    var cx = w / 2;
    var cy = h / 2 - cardH * 0.15;
    var seats = {};
    // South: cog low, fan above it. North: cog high, fan below it.
    seats.S = { cog: { x: cx, y: h - pad - noteH - cog * 0.62 - 34 * scale },
      fanY: h - pad - noteH - cog - 34 * scale - cardH * 0.9,
      fanX: cx, dir: 1, wide: true };
    seats.N = { cog: { x: cx, y: pad + cardH * 0.9 + cog * 0.62 },
      fanY: pad, fanX: cx, dir: -1, wide: true };
    seats.W = { cog: { x: pad + cog * 0.5, y: cy },
      fanY: cy - cardH / 2, fanX: pad + cog * 1.1, dir: 0, wide: false };
    seats.E = { cog: { x: w - pad - cog * 0.5, y: cy },
      fanY: cy - cardH / 2, fanX: w - pad - cog * 1.1, dir: 0, wide: false };
    return {
      w: w, h: h, pad: pad, scale: scale, cardW: cardW, cardH: cardH,
      cog: cog, cx: cx, cy: cy, seats: seats, noteLines: noteLines,
      noteH: noteH, noteW: noteW, notePad: notePad, noteLineH: noteLineH,
      notePx: notePx
    };
  }

  function drawCardBack(ctx, x, y, w, h, scale) {
    ctx.save();
    ctx.fillStyle = "#7a2f28";
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.strokeStyle = CARD_EDGE;
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.35)";
    roundRect(ctx, x + 3, y + 3, w - 6, h - 6, 2 * scale);
    ctx.stroke();
    ctx.restore();
  }

  function drawCardFace(ctx, cv, x, y, w, h, card, scale, opts) {
    opts = opts || {};
    ctx.save();
    if (opts.dim) ctx.globalAlpha = 0.42;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x, y, w, h, 3.5 * scale);
    ctx.fill();
    ctx.strokeStyle = opts.accent || CARD_EDGE;
    ctx.lineWidth = opts.accent ? 2 : 1;
    ctx.stroke();
    var suit = suitOf(card);
    var red = suit === 1 || suit === 2;
    ctx.fillStyle = red ? CARD_RED : INK;
    var rankPx = Math.max(8, Math.round(h * 0.27));
    ctx.font = "700 " + rankPx + "px " + UI_FONT;
    drawText(ctx, cv, RANKS[rankOf(card)], x + w * 0.11, y + h * 0.07,
      w * 0.8, rankPx, "left");
    var suitPx = Math.max(9, Math.round(h * 0.40));
    ctx.font = "700 " + suitPx + "px " + GLYPH_FONT;
    drawText(ctx, cv, SUIT_GLYPHS[suit], x + w * 0.55, y + h * 0.44,
      w * 0.7, suitPx, "center");
    ctx.restore();
  }

  function drawFan(ctx, cv, layout, seat, anchor, view) {
    var cards = seat.hand || [];
    var spot = layout.seats[anchor];
    var cw = layout.cardW;
    var ch = layout.cardH;
    var dim = !!seat.sittingOut;
    if (spot.wide) {
      var room = Math.min(layout.w - 2 * layout.pad, cw * 13);
      var step = cards.length > 1 ?
        Math.min(cw * 0.92, room / cards.length) : cw;
      var total = step * (cards.length - 1) + cw;
      var x0 = spot.fanX - total / 2;
      cards.forEach(function (card, i) {
        drawCardFace(ctx, cv, x0 + i * step, spot.fanY, cw, ch, card,
          layout.scale, { dim: dim });
      });
    } else {
      var vstep = cards.length > 1 ?
        Math.min(ch * 0.34, (layout.h * 0.5) / cards.length) : ch * 0.34;
      var totalH = vstep * (cards.length - 1) + ch;
      var y0 = layout.cy - totalH / 2;
      var x = anchor === "W" ? spot.fanX :
        spot.fanX - cw;
      cards.forEach(function (card, i) {
        drawCardFace(ctx, cv, x, y0 + i * vstep, cw, ch, card, layout.scale,
          { dim: dim });
      });
    }
  }

  function drawParchment(ctx, cv, x, y, w, layout, text) {
    var scale = layout.scale;
    var pad = layout.notePad;
    var lineH = layout.noteLineH;
    var h = layout.noteH;
    ctx.save();
    var px = layout.notePx;
    var lines = [];
    if (text) {
      // The band holds a cap-length note in the nominal font. A note whose
      // glyphs run wider than that (a suit-glyph-heavy remark) is set a
      // point smaller until it fits the reserved lines: the sentence is
      // never cut, and the band keeps its size, so the scene does not jump.
      var floorPx = Math.max(4, Math.round(layout.notePx * 0.6));
      ctx.font = px + "px " + UI_FONT;
      lines = wrapLines(ctx, text, w - pad * 2, 9999);
      while (lines.length > layout.noteLines && px > floorPx) {
        px -= 1;
        ctx.font = px + "px " + UI_FONT;
        lines = wrapLines(ctx, text, w - pad * 2, 9999);
      }
      if (lines.length > layout.noteLines) {
        lines = wrapLines(ctx, text, w - pad * 2, layout.noteLines);
      }
    }
    ctx.font = px + "px " + UI_FONT;
    ctx.fillStyle = text ? "rgba(242, 232, 216, 0.92)" :
      "rgba(242, 232, 216, 0.08)";
    ctx.strokeStyle = text ? CARD_EDGE : "rgba(242, 232, 216, 0.16)";
    ctx.lineWidth = 1;
    ctx.setLineDash(text ? [] : [3, 3]);
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);
    if (text) {
      ctx.fillStyle = INK;
      lines.forEach(function (line, i) {
        drawText(ctx, cv, line, x + pad, y + pad + i * lineH, w - pad * 2,
          px, "left");
      });
    } else {
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(8 * scale) + "px " + UI_FONT;
      drawText(ctx, cv, "NO NOTES YET", x + pad, y + pad, w - pad * 2,
        8 * scale, "left");
    }
    ctx.restore();
  }

  function drawChip(ctx, cv, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) + "px " + UI_FONT;
    var pad = 5 * scale;
    var bw = ctx.measureText(text).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    drawText(ctx, cv, text, x, y - bh / 2 + 2 * scale, bw, 10 * scale,
      "center");
    ctx.restore();
  }

  function drawSeat(ctx, cv, images, layout, view, seat, anchor) {
    var spot = layout.seats[anchor];
    var color = seatColor(seat.slot);
    var sprite = images["soldier_" + color + "_front.png"];
    var size = layout.cog;
    var scale = layout.scale;

    ctx.save();
    if (seat.sittingOut) ctx.globalAlpha = 0.4;
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, spot.cog.x - size / 2, spot.cog.y - size / 2,
        size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(spot.cog.x - size / 3, spot.cog.y - size / 3,
        size / 1.5, size / 1.5);
    }
    ctx.restore();

    if (seat.acting && !view.gameDone) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 3;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(spot.cog.x, spot.cog.y, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // Nameplate + tricks + bid, under (S/W/E) or over (N) the cog.
    var labelY = anchor === "N" ? spot.cog.y + size * 0.55 :
      spot.cog.y + size * 0.55;
    ctx.save();
    var namePx = Math.max(10, Math.round(12 * scale));
    ctx.font = "600 " + namePx + "px " + UI_FONT;
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.85)";
    ctx.shadowBlur = 4;
    drawText(ctx, cv, seat.name || "", spot.cog.x, labelY, size * 2.4,
      namePx, "center");
    var linePx = Math.max(9, Math.round(11 * scale));
    ctx.font = "700 " + linePx + "px " + UI_FONT;
    ctx.fillStyle = AMBER;
    var line = String(seat.tricks || 0) + " tricks";
    if (typeof seat.bid === "number" && seat.bid >= 0) {
      line = "bid " + seat.bid + " / " + (seat.made || 0);
    }
    if (view.module === "hearts") {
      line = (seat.penalty || 0) + " pts · " + (seat.tricks || 0) + " tricks";
    }
    drawText(ctx, cv, line, spot.cog.x, labelY + namePx * 1.25, size * 2.6,
      linePx, "center");
    ctx.restore();

    if (seat.dealer) {
      drawChip(ctx, cv, spot.cog.x - size * 0.72, spot.cog.y - size * 0.42,
        "D", AMBER, scale);
    }
    if (seat.slot === view.maker && view.maker >= 0) {
      drawChip(ctx, cv, spot.cog.x + size * 0.72, spot.cog.y - size * 0.42,
        view.alone ? "ALONE" : "MAKER", COLOR_HEX[color], scale);
    }

    // Notes parchment, always reserved: notes arrive without warning, and
    // the band is the cap-sized one computeLayout measured.
    var noteW = layout.noteW;
    var noteX = Math.max(2, Math.min(spot.cog.x - noteW / 2,
      layout.w - noteW - 2));
    var noteY = anchor === "N" ? labelY + namePx * 2.6 :
      Math.min(layout.h - layout.noteH - 2, labelY + namePx * 2.6);
    drawParchment(ctx, cv, noteX, noteY, noteW, layout, seat.notes || "");
  }

  // The tell ribbon unrolls DOWNWARD from the acting cog, clamped inside the
  // canvas; a band is reserved for it from the server's own 120-rune cap.
  function drawTell(ctx, cv, layout, view, seatsByPos) {
    if (!view.tell) return;
    var actor = -1;
    view.seats.forEach(function (seat) {
      if (seat.acting) actor = seat.pos;
    });
    if (actor < 0 && view.leader >= 0) {
      view.seats.forEach(function (seat) {
        if (seat.slot === view.leader) actor = seat.pos;
      });
    }
    if (actor < 0) actor = 0;
    var seat = seatsByPos[actor];
    var color = COLOR_HEX[seatColor(seat ? seat.slot : 0)];
    var scale = layout.scale;
    var fontPx = Math.max(9, Math.round(11 * scale));
    ctx.save();
    ctx.font = "600 " + fontPx + "px " + UI_FONT;
    // The band is sized from the SERVER's own cap (120 runes), measured in
    // the font it is drawn in, so the whole annotation has somewhere to go
    // at every width this viewer is embedded at.
    var maxLines = layout.w < 520 ? 3 : 2;
    var maxW = Math.min(layout.w - 20, 640 * scale);
    var lines = wrapLines(ctx, view.tell, maxW - 16, maxLines);
    var textW = 0;
    lines.forEach(function (line) {
      textW = Math.max(textW, ctx.measureText(line).width);
    });
    var lineH = fontPx * 1.32;
    var w = Math.min(maxW, textW + 16);
    var h = lines.length * lineH + fontPx * 0.7;
    var x = Math.max(6, Math.min(layout.cx - w / 2, layout.w - w - 6));
    var y = Math.max(6, Math.min(layout.cy + layout.cardH * 1.15,
      layout.h - h - 6));
    ctx.fillStyle = "rgba(242, 232, 216, 0.94)";
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    roundRect(ctx, x, y, w, h, 3 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    lines.forEach(function (line, index) {
      drawText(ctx, cv, line, x + 8, y + fontPx * 0.35 + index * lineH,
        w - 16, fontPx, "left");
    });
    ctx.restore();
  }

  function drawTrickPile(ctx, cv, layout, view, seatsByPos, fx, now) {
    var table = view.table || [];
    if (!table.length) return;
    var cw = layout.cardW * 1.05;
    var ch = layout.cardH * 1.05;
    var sweep = typeof fx.trickAt === "number" ?
      Math.min(1, (now - fx.trickAt) / SWEEP_MS) : 1;
    var winnerPos = -1;
    if (view.handDone || fx.trickWinner >= 0) {
      view.seats.forEach(function (seat) {
        if (seat.slot === fx.trickWinner) winnerPos = seat.pos;
      });
    }
    var offsets = { S: [0, 1], W: [-1, 0], N: [0, -1], E: [1, 0] };
    table.forEach(function (entry) {
      var seat = null;
      view.seats.forEach(function (s) { if (s.slot === entry.slot) seat = s; });
      var anchor = seat ? ANCHORS[seat.pos] : "S";
      var off = offsets[anchor] || [0, 0];
      var spread = Math.min(layout.cardH * 0.95, layout.h * 0.14);
      var x = layout.cx + off[0] * spread - cw / 2;
      var y = layout.cy + off[1] * spread - ch / 2;
      if (winnerPos >= 0 && sweep < 1) {
        var woff = offsets[ANCHORS[winnerPos]] || [0, 0];
        var eased = 1 - Math.pow(1 - sweep, 3);
        x += (woff[0] * spread * 1.6) * eased;
        y += (woff[1] * spread * 1.6) * eased;
      }
      var accent = (fx.trickWinner === entry.slot && winnerPos >= 0) ?
        COLOR_HEX[seatColor(entry.slot)] : null;
      drawCardFace(ctx, cv, x, y, cw, ch, entry.card, layout.scale,
        { accent: accent });
    });
  }

  function drawTableFurniture(ctx, cv, layout, view) {
    var scale = layout.scale;
    var pad = layout.pad;
    var cw = layout.cardW * 0.85;
    var ch = layout.cardH * 0.85;
    // Trump indicator, top-left corner of the felt.
    ctx.save();
    var labelPx = Math.max(8, Math.round(9 * scale));
    ctx.font = "600 " + labelPx + "px " + UI_FONT;
    ctx.fillStyle = GHOST;
    var x = pad + layout.cog * 1.7;
    var y = pad + 2;
    if (view.trump >= 0) {
      drawText(ctx, cv, "TRUMP", x, y, cw * 2, labelPx, "left");
      ctx.font = "700 " + Math.round(20 * scale) + "px " + GLYPH_FONT;
      ctx.fillStyle = (view.trump === 1 || view.trump === 2) ? CARD_RED :
        PAPER;
      drawText(ctx, cv, suitGlyph(view.trump), x, y + labelPx * 1.3,
        cw * 2, 20 * scale, "left");
    } else if (view.module === "hearts") {
      drawText(ctx, cv, "NO TRUMP", x, y, cw * 2.4, labelPx, "left");
    }
    // Up-card / turn-up beside the kitty, top-right.
    var extra = (typeof view.upcard === "number" && view.upcard >= 0) ?
      view.upcard : ((typeof view.turnup === "number" && view.turnup >= 0) ?
        view.turnup : -1);
    if (extra >= 0) {
      var ex = layout.w - pad - layout.cog * 1.7 - cw;
      ctx.font = "600 " + labelPx + "px " + UI_FONT;
      ctx.fillStyle = GHOST;
      drawText(ctx, cv, view.module === "euchre" ? "UP-CARD" : "TURN-UP",
        ex, y, cw * 2, labelPx, "left");
      var kitty = view.kitty || [];
      for (var k = 0; k < Math.max(0, kitty.length - 1); k++) {
        drawCardBack(ctx, ex - 8 * scale - k * 4 * scale,
          y + labelPx * 1.3 + k * 2, cw, ch, scale);
      }
      drawCardFace(ctx, cv, ex, y + labelPx * 1.3, cw, ch, extra,
        layout.scale, {});
    }
    ctx.restore();
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    // An unlaid-out canvas has no room for anything; drawing into it would
    // put every string outside its bounds for the frames before the first
    // resize lands.
    if (w < 32 || h < 32) return;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var layout = computeLayout(ctx, w, h);
    var fx = view.effects || { trickAt: null, trickWinner: -1 };

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    ctx.fillRect(0, 0, w, h);

    // Felt.
    ctx.save();
    ctx.fillStyle = "#1d4531";
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.ellipse(layout.cx, layout.cy, Math.min(w * 0.34, 340),
      Math.min(h * 0.26, 190), 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();
    ctx.restore();

    var seatsByPos = [];
    seats.forEach(function (seat) { seatsByPos[seat.pos] = seat; });

    drawTableFurniture(ctx, canvas, layout, view);

    for (var pos = 0; pos < 4; pos++) {
      var seat = seatsByPos[pos];
      if (!seat) continue;
      drawFan(ctx, canvas, layout, seat, ANCHORS[pos], view);
      drawSeat(ctx, canvas, images, layout, view, seat, ANCHORS[pos]);
    }

    drawTrickPile(ctx, canvas, layout, view, seatsByPos, fx, now);
    drawTell(ctx, canvas, layout, view, seatsByPos);

    if (view.gameDone) {
      ctx.save();
      var px = Math.max(11, Math.round(13 * layout.scale));
      ctx.font = "700 " + px + "px " + UI_FONT;
      ctx.fillStyle = AMBER;
      drawText(ctx, canvas, "FINAL", layout.cx, layout.cy - layout.cardH * 1.6,
        200, px, "center");
      ctx.restore();
    }
  }

  // ---- Names ---------------------------------------------------------------

  // The cogs only ever hear anonymous table aliases ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(typeof seat.slot === "number" ? seat.slot : i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function escapeHtml(text) {
    return String(text).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function describeEvent(event, nameMap, ctx) {
    function name(i) { return clampName(nameMap.seat(i)); }
    switch (event.kind) {
      case "start":
        return "Cards on the table — no talking allowed.";
      case "hand":
        return "Dealer " + name(ctx.dealerSlot) + ".";
      case "pass":
        return name(event.slot) + " passes three cards to " +
          name(event.other) + ".";
      case "bid":
        if (event.action === "bid") {
          return name(event.slot) + " bids " + event.value +
            (event.value === 0 ? " — NIL" : "");
        }
        if (event.action === "pass") return name(event.slot) + " passes.";
        if (event.action === "order") {
          return name(event.slot) + " orders it up (" +
            suitName(event.suit) + ").";
        }
        if (event.action === "alone") {
          return name(event.slot) + " goes ALONE in " + suitName(event.suit) +
            ".";
        }
        return name(event.slot) + " names " + suitName(event.suit) + ".";
      case "trump":
        return "Trump is " + suitName(event.suit) + suitGlyph(event.suit) +
          (event.slot >= 0 ? " — made by " + name(event.slot) : "") +
          (event.text ? " (" + event.text + ")" : "") + ".";
      case "discard":
        return name(event.slot) + " discards face down.";
      case "play":
        return name(event.slot) + (event.trickPos === 0 ? " leads " :
          " plays ") + cardGlyph(event.card);
      case "trick":
        return name(event.slot) + " takes trick " + (event.trick + 1) +
          (event.value ? " (+" + event.value + " penalty)" : "") + ".";
      case "broken":
        return suitName(event.suit) + " are broken.";
      case "handEnd":
        return "Hand " + (event.hand + 1) + " — " + (event.text || "scored") +
          ".";
      case "handVoid":
        return "Hand " + (event.hand + 1) +
          " abandoned at the deadline — not scored.";
      case "audit":
        return "Soft-play audit recorded (diagnostic only).";
      case "end":
        return "Final — " + (event.text || "complete") + ".";
      default:
        return JSON.stringify(event);
    }
  }

  function auditLines(results, nameMap) {
    var audit = results && results.audit;
    if (!audit || !audit.yieldRate) return [];
    var lines = [];
    for (var a = 0; a < (audit.yieldRate || []).length; a++) {
      for (var b = 0; b < audit.yieldRate[a].length; b++) {
        if (a === b) continue;
        var chance = audit.chance[a][b];
        if (!chance) continue;
        var declined = audit["yield"][a][b];
        var field = (audit.field || [])[a] || 0;
        if (declined === 0) continue;
        lines.push(clampName(nameMap.seat(a)) +
          " declined a winnable trick against " + clampName(nameMap.seat(b)) +
          " " + declined + "/" + chance + " times (field " +
          Math.round(field * 100) + "%)");
      }
    }
    return lines;
  }

  function finalLine(results, nameMap, partnership) {
    if (!results) return "";
    var net = results.net || [];
    var scores = results.scores || [];
    var best = 0;
    for (var i = 1; i < net.length; i++) if (net[i] > net[best]) best = i;
    var who = clampName(nameMap.seat(best));
    if (partnership && results.seatOrder) {
      var order = results.seatOrder;
      var pos = order.indexOf(best);
      var partner = order[(pos + 2) % 4];
      who += " & " + clampName(nameMap.seat(partner));
    }
    return "Final — " + who + " " + (net[best] >= 0 ? "+" : "") +
      (Math.round((net[best] || 0) * 10) / 10) + " (" +
      (scores[best] || 0).toFixed(2) + ")";
  }

  function handHead(event, nameMap, trumpSuit) {
    return "HAND " + (event.hand + 1) + " — DEALER " +
      clampName(nameMap.seat(event.dealerSlot)).toUpperCase() +
      (trumpSuit >= 0 ? " · " + suitGlyph(trumpSuit).toUpperCase() +
        " TRUMP" : "");
  }

  // Renders the full transcript grouped into one section per HAND.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex, payload) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastHand = null;
    var ctx = { dealerSlot: 0, seatOrder: (payload && payload.config &&
      payload.config.seatOrder) || [0, 1, 2, 3] };
    var lastNotes = {};
    var pendingTrump = -1;
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var hand = event.kind === "start" ? -1 :
        (typeof event.hand === "number" ? event.hand : lastHand);
      if (event.kind === "hand") {
        ctx.dealerSlot = ctx.seatOrder[event.dealer % 4];
        pendingTrump = typeof event.turnup === "number" && event.turnup >= 0 ?
          event.turnup % 4 : -1;
      }
      if (event.kind === "trump") pendingTrump = event.suit;
      if (hand !== lastHand) {
        html += '<div class="feed-round-head">' +
          (hand < 0 ? "SETUP" :
            handHead({ hand: hand, dealerSlot: ctx.dealerSlot }, nameMap,
              pendingTrump)) + "</div>";
        lastHand = hand;
      }
      var cls = "feed-line feed-" + event.kind +
        (typeof event.slot === "number" && event.slot >= 0 ?
          " seat" + (event.slot % COLORS.length) : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' +
        escapeHtml(describeEvent(event, nameMap, ctx)) + "</div>";
      if (event.tell) {
        html += '<div class="feed-line feed-tell' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(event.tell) + "</div>";
      }
      if (event.text && (event.kind === "play" || event.kind === "bid" ||
          event.kind === "pass" || event.kind === "discard") &&
          event.text !== lastNotes[event.slot]) {
        lastNotes[event.slot] = event.text;
        html += '<div class="feed-line feed-notes' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.slot)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    if (payload && payload.results) {
      auditLines(payload.results, nameMap).forEach(function (line) {
        html += '<div class="feed-line feed-audit' +
          (limit < events.length ? " feed-future" : "") + '">' +
          escapeHtml(line) + "</div>";
      });
      var final = finalLine(payload.results, nameMap,
        payload.config && payload.config.partnership);
      if (final) {
        html += '<div class="feed-line feed-final' +
          (limit < events.length ? " feed-future" : "") + '">' +
          escapeHtml(final) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  // ---- Animation bookkeeping ----------------------------------------------

  function makeEffects() {
    var seen = 0;
    var trickAt = null;
    var trickWinner = -1;
    return {
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "play" && event.trickPos === 0) {
            trickAt = null;
            trickWinner = -1;
          } else if (event.kind === "trick") {
            trickAt = animate ? now : null;
            trickWinner = event.slot;
          }
        }
      },
      reset: function () { seen = 0; trickAt = null; trickWinner = -1; },
      view: function () {
        return { effects: { trickAt: trickAt, trickWinner: trickWinner } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, nameMap) {
    if (!state) return "";
    var parts = [];
    var hand = (state.hand || 0) + 1;
    parts.push("HAND " + Math.max(1, hand) + " / " + (state.hands || 0));
    if (state.module === "hearts" && state.passDir) {
      parts.push("PASS " + String(state.passDir).toUpperCase());
    } else if (state.trump >= 0) {
      parts.push(suitGlyph(state.trump) + " TRUMP");
    } else {
      parts.push("NO TRUMP");
    }
    if (state.tricks) {
      parts.push("TRICK " + Math.min(state.tricks, (state.trick || 0) + 1) +
        " / " + state.tricks);
    }
    if (state.gameDone) {
      parts.push("FINAL");
    } else if (state.broken && state.module === "hearts") {
      parts.push("HEARTS BROKEN");
    } else if (typeof state.actor === "number" && state.actor >= 0) {
      parts.push(clampName(nameMap ? nameMap.seat(state.actor) : "").
        toUpperCase() + " TO PLAY");
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    var ordered = state.seats.slice().sort(function (a, b) {
      return (a.pos || 0) - (b.pos || 0);
    });
    ordered.forEach(function (seat) {
      var pips = "";
      for (var p = 0; p < Math.min(seat.tricks || 0, 13); p++) {
        pips += '<span class="plate-pip"></span>';
      }
      var plateName = nameMap ? nameMap.seat(seat.slot) : seat.name;
      var bidText = (typeof seat.bid === "number" && seat.bid >= 0) ?
        '<span class="plate-bid">' + seat.bid + "/" + (seat.made || 0) +
        "</span>" : "";
      html += '<div class="plate ' + seatColor(seat.slot) +
        (seat.team >= 0 ? " team" + seat.team : "") + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.dealer ? '<span class="plate-d">D</span>' : "") +
        (seat.acting && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' +
        (Math.round((seat.points || 0) * 10) / 10) + "</span>" +
        '<span class="plate-label">points</span>' + bidText +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.handsScored || 0) +
          " of " + (results.hands || 0) + " hands";
      case "budget":
        return "decision budget spent: scored on " +
          (results.handsScored || 0) + " of " + (results.hands || 0) +
          " hands";
      default: return "";
    }
  }

  function updateEndscreen(container, results, show, nameMap, config) {
    if (!container) return;
    // Toggled on EVERY index change, so any scrub away from the end takes
    // the endcard down.
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var net = results.net || [];
    var points = results.points || [];
    var tricks = results.tricks || [];
    var bids = results.bids || [];
    var bidsMade = results.bidsMade || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byNet = (net[b] || 0) - (net[a] || 0);
      if (byNet) return byNet;
      return (points[b] || 0) - (points[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return Math.abs((net[i] || 0) - (net[topIndex] || 0)) < 1e-9;
    });
    var partnership = config && config.partnership;
    var verdict = "ALL LEVEL";
    var verdictColor = "";
    if (!level && topIndex >= 0) {
      verdictColor = seatColor(topIndex);
      var who = names[topIndex];
      if (partnership && results.seatOrder) {
        var pos = results.seatOrder.indexOf(topIndex);
        var partner = results.seatOrder[(pos + 2) % 4];
        who += " & " + names[partner];
        verdict = escapeHtml(who) + " TAKE THE TABLE";
      } else {
        verdict = escapeHtml(who) + " TAKES THE TABLE";
      }
    }
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.handsScored || 0) +
      " HAND" + ((results.handsScored || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">points</span>' +
      '<span class="end-head">tricks</span>' +
      '<span class="end-head">bid/made</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell((scores[i] || 0).toFixed(2)) +
        cell(Math.round((points[i] || 0) * 10) / 10) +
        cell(tricks[i] || 0) +
        cell((bids[i] || 0) + "/" + (bidsMade[i] || 0));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  // ---- Transport geometry --------------------------------------------------

  // Publishes --band (the transport bar's height) and --hudscale on
  // document.documentElement (:root) -- never on #stage, where a
  // :root-scoped consumer would never see them.
  function relayout() {
    var root = document.documentElement;
    var transport = document.getElementById("transport");
    var stage = document.getElementById("stage");
    var band = transport ? transport.offsetHeight : 0;
    var width = stage ? stage.clientWidth : window.innerWidth;
    var hudscale = Math.max(0.72, Math.min(1.25, width / 960));
    root.style.setProperty("--band", band + "px");
    root.style.setProperty("--hudscale", String(Math.round(hudscale * 100) /
      100));
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
        relayout();
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
      relayout();
    };
    refresh();
    window.addEventListener("resize", relayout);
    window.addEventListener("load", relayout);
    relayout();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    Object.assign(view, state);
    view.seats = applyNames(state.seats, nameMap);
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen, modulechip,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, null);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, nameMap);
              }
              if (options.modulechip) {
                options.modulechip.textContent =
                  String(latest.displayName || "").toUpperCase();
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap, null);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () { setStatus("live", true); };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          renderer.draw(stateToView(latest, nameMap, effects, {
            gameDone: !!(latest.done || latest.gameDone)
          }));
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per HAND and one
  // labelled, clickable button per beat. The builder is deliberately NOT
  // called markBeat: a game-block function named like a chrome alias gets
  // shadowed by a hoisted `var markBeat = C.markBeat` (tandem, 2026-08-23).
  function buildTrickBeats(container, events, onSeek, nameMap) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);

    var handStarts = [];
    var lastHand = null;
    events.forEach(function (event, i) {
      var hand = event.kind === "start" ? -1 :
        (typeof event.hand === "number" ? event.hand : lastHand);
      if (hand !== lastHand) {
        handStarts.push(i);
        lastHand = hand;
      }
    });
    handStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < handStarts.length ?
        handStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });

    function beatFor(event) {
      switch (event.kind) {
        case "trick":
          return { kind: "trick", seat: event.slot,
            label: "Hand " + (event.hand + 1) + " · " +
              clampName(nameMap.seat(event.slot)) + " takes trick " +
              (event.trick + 1) };
        case "bid":
          return { kind: "bid" + (event.action === "bid" && event.value === 0 ?
              " nil" : ""), seat: event.slot,
            label: "Hand " + (event.hand + 1) + " · " +
              clampName(nameMap.seat(event.slot)) + " " +
              (event.action === "bid" ? "bids " + event.value : event.action) };
        case "trump":
          return { kind: "trump", seat: event.slot,
            label: "Hand " + (event.hand + 1) + " · trump is " +
              suitName(event.suit) };
        case "handEnd":
          var text = String(event.text || "");
          var kind = /moon/.test(text) ? "moon" :
            (/march|nil made/.test(text) ? "march" :
              (/euchred|set|nil failed/.test(text) ? "euchred" : "trick"));
          return { kind: kind, seat: -1,
            label: "Hand " + (event.hand + 1) + " — " + (text || "scored") };
        case "handVoid":
          return { kind: "void", seat: -1,
            label: "Hand " + (event.hand + 1) + " abandoned at the deadline" };
        case "end":
          return { kind: "end", seat: -1, label: "Final — " + (event.text ||
            "complete") };
        default:
          return null;
      }
    }

    events.forEach(function (event, i) {
      var beat = beatFor(event);
      if (!beat) return;
      var marker = document.createElement("button");
      marker.type = "button";
      marker.className = "beat-marker " + beat.kind +
        (beat.seat >= 0 ? " seat" + (beat.seat % COLORS.length) : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      marker.setAttribute("aria-label", beat.label);
      marker.title = beat.label;
      marker.onclick = function (evt) {
        evt.stopPropagation();
        onSeek(i + 1);
      };
      container.appendChild(marker);
    });

    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () { dragging = false; });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  var DWELL = {
    start: 600, hand: 1400, pass: 700, bid: 800, trump: 900, discard: 800,
    play: 700, trick: 1200, broken: 500, handEnd: 1600, handVoid: 1200,
    audit: 800, end: 1800
  };

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, modulechip, assetBase, payload, onFirstFrame}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;
    var announced = false;

    if (options.modulechip) {
      options.modulechip.textContent =
        String(config.displayName || "").toUpperCase();
    }

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildTrickBeats(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      }, nameMap);
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], table: [], phase: "", hand: -1 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) effects.reset();
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index, payload);
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), nameMap);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap, config);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown ? (DWELL[shown.kind] || 700) : 600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        renderer.draw(stateToView(currentState(), nameMap, effects, {
          gameDone: index >= events.length && events.length > 0
        }));
        if (!announced) {
          announced = true;
          // The attribute and the postMessage bridge can never disagree:
          // both fire here, after the first frame is PAINTED.
          document.documentElement.setAttribute("data-replay-loaded", "true");
          if (options.onFirstFrame) options.onFirstFrame();
        }
        requestAnimationFrame(frame);
      })(0);
    });
  }

  window.TrickTakingRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle,
    relayout: relayout,
    beatKinds: BEAT_KINDS
  };
})();
