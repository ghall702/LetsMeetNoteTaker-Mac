// George Hall Tuition media gateway — streams, receives and deletes lesson recordings.
// Zero dependencies (Node 20+). Every request needs a short-lived HMAC token minted by the website.
import http from "node:http";
import { createHmac, timingSafeEqual, randomBytes } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { stat, rename, unlink, mkdir, readdir, readFile, writeFile, statfs, realpath } from "node:fs/promises";
import path from "node:path";
import { pipeline } from "node:stream/promises";

const SECRET = process.env.MEDIA_GATEWAY_SECRET;
const DATA_DIR = path.resolve(process.env.DATA_DIR || "/srv/recordings");
const PORT = Number(process.env.PORT || 8787);
const ORIGINS = (process.env.ALLOWED_ORIGINS || "https://georgehalltuition.com,https://www.georgehalltuition.com").split(",").map(s => s.trim()).filter(Boolean);
if (!SECRET || SECRET.length < 32) { console.error("MEDIA_GATEWAY_SECRET (32+ chars) is required"); process.exit(1); }
const REF_RE = /^rooms\/[a-f0-9]{32}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.mp4$/;
// Statistics (see STATS.md). Counters live on the storage volume next to the recordings.
const STATS_DIR = path.resolve(process.env.STATS_DIR || path.join(DATA_DIR, ".gateway-stats"));
const STATS_TZ = process.env.STATS_TZ || "Europe/London";
const RESCAN_HOURS = Number(process.env.RESCAN_HOURS || 6);
const KEEP_DAYS = 400;

function verify(token) {
  const [body, sig, extra] = String(token || "").split(".");
  if (!body || !sig || extra !== undefined) return null;
  const want = createHmac("sha256", SECRET).update(body).digest();
  const got = Buffer.from(sig, "base64url");
  if (got.length !== want.length || !timingSafeEqual(got, want)) return null;
  try {
    const t = JSON.parse(Buffer.from(body, "base64url").toString());
    if (typeof t.exp !== "number" || t.exp * 1000 < Date.now()) return null;
    if (t.op !== "stats" && !REF_RE.test(t.ref)) return null; // stats tokens carry no file ref
    return t;
  } catch { return null; }
}
function fileFor(ref) {
  const f = path.resolve(DATA_DIR, ref);
  if (!f.startsWith(DATA_DIR + path.sep)) throw new Error("bad path");
  return f;
}
function cors(req, res) {
  const o = req.headers.origin;
  if (o && ORIGINS.includes(o)) {
    res.setHeader("Access-Control-Allow-Origin", o);
    res.setHeader("Vary", "Origin");
    res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, PUT, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type, Range");
    res.setHeader("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges");
    res.setHeader("Access-Control-Max-Age", "600");
  }
}
const json = (res, status, body) => { res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" }); res.end(JSON.stringify(body)); };
const log = (req, status, op) => console.log(new Date().toISOString(), req.method, req.url.split("?")[0], op ?? "-", status); // never logs tokens

async function serve(req, res, t) {
  const file = fileFor(t.ref);
  let st; try { st = await stat(file); } catch { return json(res, 404, { error: "not_found" }); }
  const size = st.size;
  const headers = { "Content-Type": "video/mp4", "Accept-Ranges": "bytes", "Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff",
    "Content-Disposition": t.dl ? `attachment; filename*=UTF-8''${encodeURIComponent(t.dl)}` : "inline" };
  const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || "");
  if (req.headers.range && m) {
    let start = m[1] === "" ? size - Number(m[2]) : Number(m[1]);
    let end = m[1] === "" || m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1);
    if (start < 0) start = 0;
    if (start > end || start >= size) { res.writeHead(416, { "Content-Range": `bytes */${size}` }); return res.end(); }
    res.writeHead(206, { ...headers, "Content-Range": `bytes ${start}-${end}/${size}`, "Content-Length": end - start + 1 });
    if (req.method === "HEAD") return res.end();
    return pipeline(counted(createReadStream(file, { start, end }), "playback_bytes"), res).catch(() => {});
  }
  res.writeHead(200, { ...headers, "Content-Length": size });
  if (req.method === "HEAD") return res.end();
  return pipeline(counted(createReadStream(file), "playback_bytes"), res).catch(() => {});
}

async function receive(req, res, t) {
  const file = fileFor(t.ref);
  const declared = Number(req.headers["content-length"] || 0);
  if (t.max && declared > t.max) return json(res, 413, { error: "too_large" });
  await mkdir(path.dirname(file), { recursive: true });
  const part = `${file}.part-${randomBytes(6).toString("hex")}`;
  let seen = 0;
  req.on("data", c => { seen += c.length; addTraffic("upload_bytes", c.length); if (t.max && seen > t.max) req.destroy(new Error("too_large")); });
  try {
    await pipeline(req, createWriteStream(part, { flags: "wx" }));
    const before = await stat(file).catch(() => null);
    await rename(part, file); // atomic: a failed upload never replaces a working file
    indexAdd(seen, before ? before.size : null);
    return json(res, 201, { ok: true, size: seen });
  } catch (e) {
    await unlink(part).catch(() => {});
    if (!res.headersSent) json(res, e.message === "too_large" ? 413 : 400, { error: e.message === "too_large" ? "too_large" : "upload_incomplete" });
  }
}

http.createServer(async (req, res) => {
  cors(req, res);
  if (req.method === "OPTIONS") { res.writeHead(204); return res.end(); }
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/health") return json(res, 200, { ok: true });
  const t = verify(url.searchParams.get("t"));
  const route = { "/v": "get", "/u": "put", "/stat": "stat", "/del": "del", "/stats": "stats" }[url.pathname];
  if (!route) { log(req, 404); return json(res, 404, { error: "not_found" }); }
  if (!t || t.op !== route) { log(req, 403, route); return json(res, 403, { error: "invalid_or_expired_token" }); }
  try {
    if (route === "get" && (req.method === "GET" || req.method === "HEAD")) return await serve(req, res, t);
    if (route === "put" && req.method === "PUT") return await receive(req, res, t);
    if (route === "stat" && req.method === "GET") {
      try { const s = await stat(fileFor(t.ref)); return json(res, 200, { exists: true, size: s.size }); }
      catch { return json(res, 200, { exists: false, size: 0 }); }
    }
    if (route === "stats" && req.method === "GET") return json(res, 200, await statsReport());
    if (route === "del" && req.method === "POST") {
      const f = fileFor(t.ref);
      const before = await stat(f).catch(() => null);
      await unlink(f).catch(e => { if (e.code !== "ENOENT") throw e; });
      if (before) indexRemove(before.size);
      return json(res, 200, { ok: true });
    }
    return json(res, 405, { error: "method_not_allowed" });
  } catch (e) { console.error("gateway error", e.code || e.message); if (!res.headersSent) json(res, 500, { error: "server_error" }); }
  finally { log(req, res.statusCode, route); }
}).listen(PORT, () => console.log(`media gateway on :${PORT}, data ${DATA_DIR}`));

// ───────────────────────── Statistics ─────────────────────────
// Persistent per-day counters (local days in STATS_TZ) and a cached recording index. Nothing
// here scans the recordings on request: the index is built at start-up, updated on every
// upload/delete, and re-checked every RESCAN_HOURS.

const STATS_FILE = path.join(STATS_DIR, "stats.json");
let stats = { version: 1, started_at: new Date().toISOString(), days: {}, server_since: null, net_last: null,
              index: { count: null, bytes: null, indexed_at: null } };
let dirty = false;

export function dayKey(d = new Date(), tz = STATS_TZ) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

function bucket(key = dayKey()) {
  return (stats.days[key] ||= { upload_bytes: 0, playback_bytes: 0, server_rx_bytes: 0, server_tx_bytes: 0 });
}

function addTraffic(field, n) { bucket()[field] += n; dirty = true; }

function counted(stream, field) {
  stream.on("data", c => addTraffic(field, c.length));
  return stream;
}

function indexAdd(size, replacedSize) {
  if (stats.index.count === null) return; // initial scan still running; it will see the file
  if (replacedSize === null) stats.index.count += 1; else stats.index.bytes -= replacedSize;
  stats.index.bytes += size;
  dirty = true;
}
function indexRemove(size) {
  if (stats.index.count === null) return;
  stats.index.count = Math.max(0, stats.index.count - 1);
  stats.index.bytes = Math.max(0, stats.index.bytes - size);
  dirty = true;
}

/** Counts finished recordings (*.mp4, not in-progress .part files) under DATA_DIR/rooms. */
export async function scanRecordings(root = DATA_DIR) {
  let count = 0, bytes = 0;
  async function walk(dir) {
    let entries;
    try { entries = await readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory()) await walk(p);
      else if (e.isFile() && e.name.endsWith(".mp4") && !e.name.includes(".part-")) {
        try { bytes += (await stat(p)).size; count += 1; } catch {}
      }
    }
  }
  await walk(path.join(root, "rooms"));
  return { count, bytes };
}

async function rescan() {
  const r = await scanRecordings();
  stats.index = { count: r.count, bytes: r.bytes, indexed_at: new Date().toISOString() };
  dirty = true;
}

/** Whole-server traffic from the host's network interfaces (Linux only; deltas survive reboots). */
async function sampleNetwork() {
  let text;
  try { text = await readFile("/proc/net/dev", "utf8"); } catch { return; }
  const now = {};
  for (const line of text.split("\n").slice(2)) {
    const m = /^\s*([^:]+):\s*(\d+)(?:\s+\d+){7}\s+(\d+)/.exec(line);
    if (!m) continue;
    const name = m[1].trim();
    if (name === "lo" || name.startsWith("docker") || name.startsWith("veth") || name.startsWith("br-")) continue;
    now[name] = { rx: Number(m[2]), tx: Number(m[3]) };
  }
  if (stats.net_last) {
    const b = bucket();
    for (const [name, c] of Object.entries(now)) {
      const last = stats.net_last[name];
      // Counter reset (reboot): count from zero.
      const drx = last && c.rx >= last.rx ? c.rx - last.rx : c.rx;
      const dtx = last && c.tx >= last.tx ? c.tx - last.tx : c.tx;
      if (last) { b.server_rx_bytes += drx; b.server_tx_bytes += dtx; }
    }
  } else {
    stats.server_since = new Date().toISOString();
  }
  stats.net_last = now;
  dirty = true;
}

async function loadStats() {
  try {
    const saved = JSON.parse(await readFile(STATS_FILE, "utf8"));
    if (saved && saved.version === 1 && saved.days) stats = { ...stats, ...saved, index: { count: null, bytes: null, indexed_at: null } };
  } catch {}
}

export async function saveStats() {
  if (!dirty) return;
  // Keep about 13 months of days.
  const keys = Object.keys(stats.days).sort();
  for (const k of keys.slice(0, Math.max(0, keys.length - KEEP_DAYS))) delete stats.days[k];
  await mkdir(STATS_DIR, { recursive: true });
  const tmp = `${STATS_FILE}.tmp-${randomBytes(4).toString("hex")}`;
  await writeFile(tmp, JSON.stringify(stats));
  await rename(tmp, STATS_FILE); // atomic
  dirty = false;
}

export async function statsReport() {
  await mkdir(DATA_DIR, { recursive: true }); // a fresh install may not have the folder yet
  const fs = await statfs(DATA_DIR);
  const total = fs.blocks * fs.bsize, free = fs.bfree * fs.bsize, avail = fs.bavail * fs.bsize;
  const days = Object.keys(stats.days).sort().slice(-62).map(date => ({ date, ...stats.days[date] }));
  return {
    ok: true,
    generated_at: new Date().toISOString(),
    timezone: STATS_TZ,
    volume: { path: DATA_DIR, real_path: await realpath(DATA_DIR).catch(() => DATA_DIR),
              total_bytes: total, used_bytes: total - free, available_bytes: avail, free_bytes: free },
    recordings: { count: stats.index.count, bytes: stats.index.bytes, indexed_at: stats.index.indexed_at },
    traffic: { scope: "media-gateway", since: stats.started_at,
               days: days.map(d => ({ date: d.date, upload_bytes: d.upload_bytes, playback_bytes: d.playback_bytes })) },
    server_traffic: { scope: "host-network-interfaces", available: stats.server_since !== null, since: stats.server_since,
                      days: days.map(d => ({ date: d.date, rx_bytes: d.server_rx_bytes, tx_bytes: d.server_tx_bytes })) },
  };
}

if (process.env.GATEWAY_NO_STATS_TIMERS !== "1") {
  await loadStats();
  rescan().catch(e => console.error("recording scan failed", e.code || e.message));
  sampleNetwork();
  setInterval(() => sampleNetwork(), 60_000).unref();
  setInterval(() => saveStats().catch(e => console.error("stats save failed", e.code || e.message)), 30_000).unref();
  setInterval(() => rescan().catch(() => {}), RESCAN_HOURS * 3600_000).unref();
  for (const sig of ["SIGTERM", "SIGINT"]) process.on(sig, () => { saveStats().finally(() => process.exit(0)); });
}
