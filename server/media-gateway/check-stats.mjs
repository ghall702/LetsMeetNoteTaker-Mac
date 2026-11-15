// Verifies the gateway's /stats endpoint on the server itself, using the existing secret file.
// Usage (as root):  node check-stats.mjs [/opt/media-gateway/.env] [http://127.0.0.1:8787]
// Prints a summary only — never the secret or the token.
import { readFileSync } from "node:fs";
import { createHmac } from "node:crypto";

const envFile = process.argv[2] || "/opt/media-gateway/.env";
const base = (process.argv[3] || "http://127.0.0.1:8787").replace(/\/$/, "");
const env = Object.fromEntries(readFileSync(envFile, "utf8").split("\n")
  .map(l => l.trim()).filter(l => l && !l.startsWith("#") && l.includes("="))
  .map(l => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim().replace(/^["']|["']$/g, "")]));
const secret = env.MEDIA_GATEWAY_SECRET;
if (!secret) { console.error(`MEDIA_GATEWAY_SECRET not found in ${envFile}`); process.exit(1); }

const body = Buffer.from(JSON.stringify({ op: "stats", exp: Math.floor(Date.now() / 1000) + 60 })).toString("base64url");
const token = body + "." + createHmac("sha256", secret).update(body).digest("base64url");

const unsigned = await fetch(`${base}/stats`);
console.log(`Without a token: HTTP ${unsigned.status} (expected 403)`);
const r = await fetch(`${base}/stats?t=${token}`);
console.log(`With a signed token: HTTP ${r.status} (expected 200)`);
if (r.status !== 200) { console.log(await r.text()); process.exit(1); }
const s = await r.json();
const gb = n => (n / 1e9).toFixed(1) + " GB";
console.log(`Volume: ${s.volume.real_path}  total ${gb(s.volume.total_bytes)}, used ${gb(s.volume.used_bytes)}, available ${gb(s.volume.available_bytes)}`);
console.log(`Recordings: ${s.recordings.count ?? "(still counting)"} files, ${s.recordings.bytes == null ? "?" : gb(s.recordings.bytes)}`);
const today = s.traffic.days.at(-1);
console.log(`Traffic today (${s.timezone}): ${today ? `uploads ${gb(today.upload_bytes)}, playback ${gb(today.playback_bytes)}` : "none yet"}`);
console.log(`Whole-server traffic: ${s.server_traffic.available ? "available" : "not yet sampled (wait a minute)"}`);
if (!String(s.volume.real_path).startsWith("/mnt/storage")) {
  console.log("WARNING: the recordings folder is not on /mnt/storage — check DATA_DIR.");
  process.exit(2);
}
console.log("OK");
