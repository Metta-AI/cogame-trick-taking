// chrome_geometry_check.mjs -- the endcard can never cover the scrubber.
//
// The design note claims `viewer_smoke.mjs` asserts this; it does not, and
// that file is byte-identical to the coworld-builder template and stays that
// way. The claim itself is worth holding, because the failure it describes is
// invisible to every other gate: a replay whose endcard overlaps the
// transport band still loads, still soaks, still draws every string inside
// the canvas, and simply cannot be scrubbed back from the score screen.
//
// `#endscreen` is a child of `#board-wrap`, which is `#transport`'s sibling
// directly above it in `#stage`, so the band's top edge IS the board's
// bottom edge. This measures that in a real browser, with the endcard shown.
//
// Usage:
//   node tools/ci/chrome_geometry_check.mjs --bundle <dir> --replay <file>
//   node tools/ci/chrome_geometry_check.mjs --url <url with ?replay=>
import { createServer } from "node:http";
import { basename, extname, join, resolve, sep } from "node:path";
import { createReadStream, existsSync, statSync } from "node:fs";
import process from "node:process";

function die(code, message) {
  console.error(message);
  process.exit(code);
}

const args = { timeout: 60 };
for (let i = 2; i < process.argv.length; i += 1) {
  const arg = process.argv[i];
  const next = () => {
    const value = process.argv[i + 1];
    if (value === undefined) die(2, `missing value for ${arg}`);
    i += 1;
    return value;
  };
  switch (arg) {
    case "--bundle": args.bundle = resolve(next()); break;
    case "--replay": args.replay = resolve(next()); break;
    case "--url": args.url = next(); break;
    case "--timeout": args.timeout = Number(next()); break;
    default: die(2, `unknown argument: ${arg}`);
  }
}
if (!args.url && !(args.bundle && args.replay)) {
  die(2, "usage: chrome_geometry_check.mjs (--bundle <dir> --replay <file> | --url <url>)");
}

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript",
  ".css": "text/css", ".png": "image/png", ".ttf": "font/ttf",
  ".wasm": "application/wasm", ".json": "application/json",
  ".replay": "application/json" };

let server = null;
let target = args.url;
if (!target) {
  const root = args.bundle;
  const replayName = basename(args.replay);
  if (!existsSync(join(root, "index.html"))) die(2, `no index.html in ${root}`);
  server = createServer((req, res) => {
    let pathname = "/index.html";
    try {
      pathname = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
    } catch {
      res.writeHead(400).end("bad url");
      return;
    }
    if (pathname === "/") pathname = "/index.html";
    const file = pathname === `/${replayName}`
      ? args.replay
      : resolve(join(root, pathname));
    if (file !== args.replay && !(file === root || file.startsWith(root + sep))) {
      res.writeHead(403).end("forbidden");
      return;
    }
    if (!existsSync(file) || !statSync(file).isFile()) {
      res.writeHead(404).end("not found");
      return;
    }
    res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream" });
    createReadStream(file).pipe(res);
  });
  await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
  const port = server.address().port;
  target = `http://127.0.0.1:${port}/index.html?replay=` +
    encodeURIComponent(`http://127.0.0.1:${port}/${replayName}`);
}

let chromium = null;
for (const name of [process.env.PLAYWRIGHT_MODULE, "playwright", "playwright-core"]) {
  if (!name) continue;
  try {
    const mod = await import(name);
    chromium = mod.chromium || (mod.default && mod.default.chromium);
    if (chromium) break;
  } catch { /* try the next one */ }
}
if (!chromium) die(2, "could not load Playwright (npm install playwright@1.55.0)");

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto(target, { waitUntil: "commit", timeout: args.timeout * 1000 });
await page.waitForFunction(
  "document.documentElement.getAttribute('data-replay-loaded') === 'true' || " +
  "document.documentElement.getAttribute('data-replay-error')",
  null, { timeout: args.timeout * 1000 });

// Seek to the end: that is what puts the endcard up in the first place.
try {
  const box = await page.locator("#scrub").first().boundingBox();
  if (box) {
    await page.mouse.click(box.x + box.width - 1, box.y + box.height / 2);
    await page.waitForTimeout(800);
  }
} catch { /* measured with the class forced below instead */ }

const geometry = await page.evaluate(() => {
  const end = document.getElementById("endscreen");
  const transport = document.getElementById("transport");
  const board = document.getElementById("board-wrap");
  if (!end || !transport || !board) {
    return { missing: [["endscreen", end], ["transport", transport],
      ["board-wrap", board]].filter((p) => !p[1]).map((p) => p[0]) };
  }
  // The endcard is display:none until a replay ends. The claim is about its
  // box, so show it if the seek did not.
  const seeded = end.classList.contains("show");
  if (!seeded) end.classList.add("show");
  const rect = (el) => {
    const r = el.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom, left: r.left, right: r.right,
      height: r.height };
  };
  const out = { shownBySeek: seeded, end: rect(end), transport: rect(transport),
    board: rect(board), parent: end.parentElement && end.parentElement.id };
  if (!seeded) end.classList.remove("show");
  return out;
});
await browser.close();
if (server) await new Promise((done) => server.close(done));

if (geometry.missing) {
  die(1, `::error::the page is missing ${geometry.missing.join(", ")}: the ` +
    "endcard/transport relationship cannot exist without all three");
}
const problems = [];
const TOL = 1;
if (geometry.parent !== "board-wrap") {
  problems.push(`#endscreen's parent is #${geometry.parent}, not #board-wrap: ` +
    "the band's top edge is only the endcard's floor while it is inside the board");
}
if (geometry.transport.height <= 0) {
  problems.push("#transport has no height: nothing is reserving the band");
}
if (geometry.end.height <= 0) {
  problems.push("#endscreen has no height even with .show: it cannot be measured");
}
if (geometry.end.bottom > geometry.transport.top + TOL) {
  problems.push(`#endscreen's bottom (${geometry.end.bottom.toFixed(1)}) is ` +
    `below #transport's top (${geometry.transport.top.toFixed(1)}): the ` +
    "endcard covers the scrubber and the match cannot be pulled back from it");
}
if (geometry.end.bottom > geometry.board.bottom + TOL) {
  problems.push(`#endscreen (bottom ${geometry.end.bottom.toFixed(1)}) escapes ` +
    `#board-wrap (bottom ${geometry.board.bottom.toFixed(1)})`);
}
if (problems.length) {
  for (const line of problems) console.log(`::error::${line}`);
  die(1, "::error::transport-band geometry check failed");
}
console.log("endcard geometry OK: #endscreen bottom " +
  `${geometry.end.bottom.toFixed(1)} <= #transport top ` +
  `${geometry.transport.top.toFixed(1)} (shown by seek: ${geometry.shownBySeek})`);
