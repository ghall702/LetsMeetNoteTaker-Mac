// Run: node --test test/gateway.test.mjs   (Node 20+). Starts the real gateway on a temporary folder.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const SECRET = "test-secret-".padEnd(48, "x");
const ROOM = "3ae368a1b979e5f6e0aba39d3103b7e1";

function token(claims) {
  const body = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 60, ...claims })).toString("base64url");
  return body + "." + createHmac("sha256", SECRET).update(body).digest("base64url");
}

async function start(dataDir, port) {
  const child = spawn(process.execPath, [new URL("../gateway.mjs", import.meta.url).pathname], {
    env: { ...process.env, MEDIA_GATEWAY_SECRET: SECRET, DATA_DIR: dataDir, PORT: String(port), STATS_TZ: "Europe/London" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return child; } catch {}
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error("gateway did not start");
}

async function stop(child) {
  const done = new Promise(r => child.on("exit", r));
  child.kill("SIGTERM");
  await done;
}

test("stats: storage, index, upload/playback traffic, auth, persistence", async () => {
  const dataDir = await mkdtemp(path.join(tmpdir(), "gw-"));
  const port = 18000 + Math.floor(Math.random() * 1000);
  const base = `http://127.0.0.1:${port}`;
  let gw = await start(dataDir, port);
  try {
    // Stats need a valid signed token.
    assert.equal((await fetch(`${base}/stats`)).status, 403);
    assert.equal((await fetch(`${base}/stats?t=${token({ op: "get", ref: "x" })}`)).status, 403, "wrong op");
    const empty = await (await fetch(`${base}/stats?t=${token({ op: "stats" })}`)).json();
    assert.equal(empty.recordings.count, 0);
    assert.ok(empty.volume.total_bytes > 0 && empty.volume.available_bytes > 0);
    assert.equal(empty.traffic.scope, "media-gateway");

    // Upload two recordings, replace one.
    const ref1 = `rooms/${ROOM}/${randomUUID()}/${randomUUID()}.mp4`;
    const ref2 = `rooms/${ROOM}/${randomUUID()}/${randomUUID()}.mp4`;
    const a = Buffer.alloc(100_000, 1), b = Buffer.alloc(50_000, 2), c = Buffer.alloc(70_000, 3);
    for (const [ref, body] of [[ref1, a], [ref2, b], [ref2, c]]) {
      const r = await fetch(`${base}/u?t=${token({ op: "put", ref, max: 1_000_000 })}`, { method: "PUT", body, headers: { "Content-Type": "video/mp4" } });
      assert.equal(r.status, 201);
    }
    // Playback: a full read and a 1,000-byte range.
    await (await fetch(`${base}/v?t=${token({ op: "get", ref: ref1 })}`)).arrayBuffer();
    const part = await fetch(`${base}/v?t=${token({ op: "get", ref: ref1 })}`, { headers: { Range: "bytes=0-999" } });
    assert.equal(part.status, 206);
    await part.arrayBuffer();

    let s = await (await fetch(`${base}/stats?t=${token({ op: "stats" })}`)).json();
    assert.equal(s.recordings.count, 2, "replacing a file doesn't double count");
    assert.equal(s.recordings.bytes, 100_000 + 70_000);
    const today = s.traffic.days.at(-1);
    assert.equal(today.upload_bytes, 100_000 + 50_000 + 70_000, "every received byte counts as upload traffic");
    assert.equal(today.playback_bytes, 100_000 + 1_000);

    // Delete one.
    assert.equal((await fetch(`${base}/del?t=${token({ op: "del", ref: ref2 })}`, { method: "POST" })).status, 200);
    s = await (await fetch(`${base}/stats?t=${token({ op: "stats" })}`)).json();
    assert.equal(s.recordings.count, 1);
    assert.equal(s.recordings.bytes, 100_000);

    // Restart: counters persist; the index is rebuilt from disk.
    await stop(gw);
    const saved = JSON.parse(await readFile(path.join(dataDir, ".gateway-stats", "stats.json"), "utf8"));
    assert.equal(saved.days[today.date].upload_bytes, 220_000);
    gw = await start(dataDir, port);
    await new Promise(r => setTimeout(r, 300));
    s = await (await fetch(`${base}/stats?t=${token({ op: "stats" })}`)).json();
    assert.equal(s.traffic.days.at(-1).upload_bytes, 220_000);
    assert.equal(s.traffic.days.at(-1).playback_bytes, 101_000);
    assert.equal(s.recordings.count, 1);
    assert.equal(s.recordings.bytes, 100_000);
  } finally {
    await stop(gw);
  }
});

test("existing behaviour unchanged: expiry, forgery, size limit, missing files, Range", async () => {
  const dataDir = await mkdtemp(path.join(tmpdir(), "gw-"));
  const port = 19000 + Math.floor(Math.random() * 1000);
  const base = `http://127.0.0.1:${port}`;
  const gw = await start(dataDir, port);
  try {
    const ref = `rooms/${ROOM}/${randomUUID()}/${randomUUID()}.mp4`;
    const expired = token({ op: "put", ref, exp: Math.floor(Date.now() / 1000) - 5 });
    assert.equal((await fetch(`${base}/u?t=${expired}`, { method: "PUT", body: "x" })).status, 403);
    const forged = token({ op: "put", ref }).slice(0, -2) + "AA";
    assert.equal((await fetch(`${base}/u?t=${forged}`, { method: "PUT", body: "x" })).status, 403);
    assert.equal((await fetch(`${base}/u?t=${token({ op: "put", ref: "../../etc/passwd" })}`, { method: "PUT", body: "x" })).status, 403);
    const big = await fetch(`${base}/u?t=${token({ op: "put", ref, max: 10 })}`, { method: "PUT", body: Buffer.alloc(100) });
    assert.equal(big.status, 413);
    assert.equal((await fetch(`${base}/v?t=${token({ op: "get", ref })}`)).status, 404, "nothing stored after a rejected upload");
    assert.equal((await fetch(`${base}/u?t=${token({ op: "put", ref, max: 1000 })}`, { method: "PUT", body: Buffer.alloc(500, 7) })).status, 201);
    const r = await fetch(`${base}/v?t=${token({ op: "get", ref })}`, { headers: { Range: "bytes=100-199" } });
    assert.equal(r.status, 206);
    assert.equal(r.headers.get("content-range"), "bytes 100-199/500");
    assert.equal((await r.arrayBuffer()).byteLength, 100);
    const st = await (await fetch(`${base}/stat?t=${token({ op: "stat", ref })}`)).json();
    assert.deepEqual(st, { exists: true, size: 500 });
  } finally {
    await stop(gw);
  }
});

test("stats work before the recordings folder exists (fresh install)", async () => {
  const parent = await mkdtemp(path.join(tmpdir(), "gw-"));
  const dataDir = path.join(parent, "recordings-not-created-yet");
  const port = 17000 + Math.floor(Math.random() * 1000);
  const gw = await start(dataDir, port);
  try {
    const r = await fetch(`http://127.0.0.1:${port}/stats?t=${token({ op: "stats" })}`);
    assert.equal(r.status, 200);
    const s = await r.json();
    assert.ok(s.volume.total_bytes > 0);
  } finally {
    await stop(gw);
  }
});
