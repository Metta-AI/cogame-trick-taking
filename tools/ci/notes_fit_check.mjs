// notes_fit_check.mjs -- the gate on "a model's sentence is never cut".
//
// `viewer_smoke.mjs --strict-text-bounds` gates `never_inside`, which asks
// whether a string landed on the canvas at all. It reports `ellipsized` but
// cannot gate it: an ellipsis is correct on a nameplate in a 52 px card and
// correct at the end of a `notes` string the SERVER already truncated at its
// own cap. It is a defect only when the renderer runs out of room and cuts a
// model's sentence mid-word -- exactly what an undersized notes band does,
// and exactly what no counter can tell apart on its own.
//
// This script opens tools/ci/renderer_fixture.html (a full-cap 400-rune
// `notes` on every seat and a full-cap 120-rune `tell`), records every
// fillText the shipped client/renderer.js makes at each canvas size, and
// fails if any drawn string is a piece of the fixture's own notes/tell that
// ends in an ellipsis WITHOUT being that string's own tail. That is a
// renderer-added cut, and it means the reserved band is too small for the
// cap the server enforces.
//
// Usage:
//   node tools/ci/notes_fit_check.mjs --fixture dist/renderer-fixture
//     [--sizes 360x640,960x640,1440x900] [--timeout 60]
import { createServer } from "node:http";
import { createReadStream, existsSync, statSync } from "node:fs";
import { extname, join, resolve, sep } from "node:path";
import process from "node:process";

function die(code, message) {
  console.error(message);
  process.exit(code);
}

const args = { fixture: "dist/renderer-fixture", timeout: 60,
  sizes: "360x640,960x640,1440x900" };
for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  const next = () => {
    const value = process.argv[i + 1];
    if (value === undefined) die(2, `missing value for ${arg}`);
    i += 1;
    return value;
  };
  switch (arg) {
    case "--fixture": args.fixture = next(); break;
    case "--sizes": args.sizes = next(); break;
    case "--timeout": args.timeout = Number(next()); break;
    case "-h": case "--help":
      die(0, "usage: notes_fit_check.mjs --fixture <dir> [--sizes WxH,...]");
      break;
    default: die(2, `unknown argument: ${arg}`);
  }
}
const sizes = args.sizes.split(",").map((s) => s.split("x").map(Number));
const root = resolve(args.fixture);
if (!existsSync(join(root, "index.html"))) {
  die(2, `fixture has no index.html: ${root}`);
}

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript",
  ".css": "text/css", ".png": "image/png", ".ttf": "font/ttf",
  ".json": "application/json", ".replay": "application/json" };

const server = createServer((req, res) => {
  let pathname = "/index.html";
  try {
    pathname = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
  } catch {
    res.writeHead(400).end("bad url");
    return;
  }
  if (pathname === "/") pathname = "/index.html";
  const target = resolve(join(root, pathname));
  if (!(target === root || target.startsWith(root + sep)) ||
      !existsSync(target) || !statSync(target).isFile()) {
    res.writeHead(404).end("not found");
    return;
  }
  res.writeHead(200, { "content-type": TYPES[extname(target)] || "application/octet-stream" });
  createReadStream(target).pipe(res);
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const url = `http://127.0.0.1:${server.address().port}/index.html`;

let chromium = null;
for (const name of [process.env.PLAYWRIGHT_MODULE, "playwright", "playwright-core"]) {
  if (!name) continue;
  try {
    const mod = await import(name);
    chromium = (mod.chromium || (mod.default && mod.default.chromium));
    if (chromium) break;
  } catch { /* try the next one */ }
}
if (!chromium) {
  die(2, "could not load Playwright. Install the pinned version:\n" +
    "  npm install --no-save playwright@1.55.0\n" +
    "  npx --yes playwright@1.55.0 install --with-deps chromium");
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1200 } });
await page.addInitScript(() => {
  window.__drawn = [];
  const proto = CanvasRenderingContext2D.prototype;
  const real = proto.fillText;
  proto.fillText = function (text, x, y, ...rest) {
    try { window.__drawn.push(String(text)); } catch { /* keep drawing */ }
    return real.call(this, text, x, y, ...rest);
  };
});
const errors = [];
page.on("pageerror", (err) => errors.push(String(err && err.message)));
await page.goto(url, { waitUntil: "commit", timeout: args.timeout * 1000 });
await page.waitForFunction(
  "document.documentElement.getAttribute('data-replay-loaded') === 'true' || " +
  "document.documentElement.getAttribute('data-replay-error')",
  null, { timeout: args.timeout * 1000 });

const capped = await page.evaluate("window.__FIXTURE_TEXT || null");
if (!capped || !capped.notes || !capped.tell) {
  die(1, "::error::the fixture does not publish window.__FIXTURE_TEXT " +
    "{notes, tell}; without the cap strings nothing here can be checked");
}
const CAPS = [["notes", capped.notes], ["tell", capped.tell]];
if (!capped.astral) {
  die(1, "::error::the fixture does not publish an astral rune; the " +
    "lone-surrogate check below would be vacuous");
}

// A lone surrogate is what a UTF-16 slice leaves behind when it cuts an
// astral rune in half. Every string that reaches the replay is truncated on
// RUNE boundaries server-side (truncateRunes, src/tricks/types.nim); the
// viewer's own cosmetic cut has to hold to the same rule, or a model that
// writes one emoji gets a replacement glyph on the canvas.
const LONE_SURROGATE =
  /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:^|[^\uD800-\uDBFF])([\uDC00-\uDFFF])/;
let surrogates = 0;
let astralDraws = 0;

// The fixture cycles its own canvas sizes on a timer; drive them here so
// every size is measured deliberately and reported by name.
await page.evaluate("(() => { for (let i = 1; i < 9999; i++) window.clearInterval(i); })()");

let cuts = 0;
let checked = 0;
for (const [w, h] of sizes) {
  await page.evaluate(([w, h]) => {
    window.__drawn = [];
    const canvas = document.getElementById("table");
    canvas.width = w;
    canvas.height = h;
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";
    const stage = document.getElementById("stage");
    if (stage) stage.style.maxWidth = w + "px";
    window.TrickTakingRenderer.relayout();
  }, [w, h]);
  await page.waitForTimeout(600);
  const drawn = await page.evaluate("window.__drawn");
  const bad = new Map();
  let seen = 0;
  for (const text of drawn) {
    if (!/\u2026\s*$/.test(text)) continue;
    const core = text.replace(/\u2026\s*$/, "");
    if (core.length <= 8) continue;          // a nameplate, not a sentence
    for (const [name, full] of CAPS) {
      if (!full.includes(core)) continue;
      seen += 1;
      // The server truncates at its cap and appends the ellipsis itself, so
      // a draw carrying the tail of the capped string is that ellipsis. Any
      // other cut came from the renderer.
      if (!full.endsWith(core) && !full.endsWith(core + "\u2026")) {
        bad.set(text, (bad.get(text) || 0) + 1);
      }
      break;
    }
  }
  checked += seen;

  const split = new Map();
  for (const text of drawn) {
    if (text.includes(capped.astral)) astralDraws += 1;
    if (LONE_SURROGATE.test(text)) split.set(text, (split.get(text) || 0) + 1);
  }
  if (split.size) {
    surrogates += split.size;
    console.log(`::error::${w}x${h}: ${split.size} drawn string(s) carry a ` +
      `lone surrogate -- a cut landed inside an astral rune`);
    for (const [text, count] of split) {
      console.log(`::error::  ${count} draw(s): ${JSON.stringify(text)}`);
    }
  }
  if (bad.size) {
    cuts += bad.size;
    console.log(`::error::${w}x${h}: the renderer cut ${bad.size} model ` +
      `sentence(s) mid-string -- the reserved band is smaller than the ` +
      `server's cap`);
    for (const [text, count] of bad) {
      console.log(`::error::  ${count} draw(s): ${JSON.stringify(text.slice(-48))}`);
    }
  } else {
    console.log(`  ${w}x${h}: ${drawn.length} strings drawn, no mid-string cut`);
  }
}

const errorAttr = await page.evaluate(
  "document.documentElement.getAttribute('data-replay-error')");
await browser.close();
await new Promise((done) => server.close(done));

if (errorAttr) die(1, `::error::fixture reported data-replay-error: ${errorAttr}`);
if (errors.length) die(1, `::error::uncaught page error: ${errors[0]}`);
if (cuts > 0) die(1, `::error::${cuts} mid-string cut(s); widen the notes band`);
if (surrogates > 0) {
  die(1, `::error::${surrogates} drawn string(s) cut an astral rune in half; ` +
    `the renderer must ellipsize on rune boundaries`);
}
if (astralDraws === 0) {
  die(1, "::error::the fixture's astral rune was never drawn: the " +
    "lone-surrogate check covered nothing");
}
if (checked === 0) {
  die(1, "::error::no capped string was ever drawn with an ellipsis: the " +
    "fixture is not exercising the notes/tell chrome any more");
}
console.log(`notes fit OK: ${checked} capped-string ellipses, all of them ` +
  `the server's own cap`);
