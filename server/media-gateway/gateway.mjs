// George Hall Tuition media gateway — streams, receives and deletes lesson recordings.
// Zero dependencies (Node 20+). Every request needs a short-lived HMAC token minted by the website.
import http from "node:http";
import { createHmac, timingSafeEqual, randomBytes } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { stat, rename, unlink, mkdir } from "node:fs/promises";
import path from "node:path";
import { pipeline } from "node:stream/promises";

const SECRET = process.env.MEDIA_GATEWAY_SECRET;
const DATA_DIR = path.resolve(process.env.DATA_DIR || "/srv/recordings");
const PORT = Number(process.env.PORT || 8787);
const ORIGINS = (process.env.ALLOWED_ORIGINS || "https://georgehalltuition.com,https://www.georgehalltuition.com").split(",").map(s => s.trim()).filter(Boolean);
if (!SECRET || SECRET.length < 32) { console.error("MEDIA_GATEWAY_SECRET (32+ chars) is required"); process.exit(1); }
const REF_RE = /^rooms\/[a-f0-9]{32}\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.mp4$/;

function verify(token) {
  const [body, sig, extra] = String(token || "").split(".");
  if (!body || !sig || extra !== undefined) return null;
  const want = createHmac("sha256", SECRET).update(body).digest();
  const got = Buffer.from(sig, "base64url");
  if (got.length !== want.length || !timingSafeEqual(got, want)) return null;
  try {
    const t = JSON.parse(Buffer.from(body, "base64url").toString());
    if (typeof t.exp !== "number" || t.exp * 1000 < Date.now() || !REF_RE.test(t.ref)) return null;
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
    return pipeline(createReadStream(file, { start, end }), res).catch(() => {});
  }
  res.writeHead(200, { ...headers, "Content-Length": size });
  if (req.method === "HEAD") return res.end();
  return pipeline(createReadStream(file), res).catch(() => {});
}

async function receive(req, res, t) {
  const file = fileFor(t.ref);
  const declared = Number(req.headers["content-length"] || 0);
  if (t.max && declared > t.max) return json(res, 413, { error: "too_large" });
  await mkdir(path.dirname(file), { recursive: true });
  const part = `${file}.part-${randomBytes(6).toString("hex")}`;
  let seen = 0;
  req.on("data", c => { seen += c.length; if (t.max && seen > t.max) req.destroy(new Error("too_large")); });
  try {
    await pipeline(req, createWriteStream(part, { flags: "wx" }));
    await rename(part, file); // atomic: a failed upload never replaces a working file
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
  const route = { "/v": "get", "/u": "put", "/stat": "stat", "/del": "del" }[url.pathname];
  if (!route) { log(req, 404); return json(res, 404, { error: "not_found" }); }
  if (!t || t.op !== route) { log(req, 403, route); return json(res, 403, { error: "invalid_or_expired_token" }); }
  try {
    if (route === "get" && (req.method === "GET" || req.method === "HEAD")) return await serve(req, res, t);
    if (route === "put" && req.method === "PUT") return await receive(req, res, t);
    if (route === "stat" && req.method === "GET") {
      try { const s = await stat(fileFor(t.ref)); return json(res, 200, { exists: true, size: s.size }); }
      catch { return json(res, 200, { exists: false, size: 0 }); }
    }
    if (route === "del" && req.method === "POST") {
      await unlink(fileFor(t.ref)).catch(e => { if (e.code !== "ENOENT") throw e; });
      return json(res, 200, { ok: true });
    }
    return json(res, 405, { error: "method_not_allowed" });
  } catch (e) { console.error("gateway error", e.code || e.message); if (!res.headersSent) json(res, 500, { error: "server_error" }); }
  finally { log(req, res.statusCode, route); }
}).listen(PORT, () => console.log(`media gateway on :${PORT}, data ${DATA_DIR}`));
