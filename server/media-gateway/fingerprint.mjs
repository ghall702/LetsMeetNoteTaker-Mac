// Prints a short fingerprint of MEDIA_GATEWAY_SECRET so it can be compared with the website's
// without showing either value: first 16 hex chars of HMAC-SHA256(secret, "letsmeet-media-gateway-fingerprint").
// Usage: node fingerprint.mjs [/opt/media-gateway/.env]
import { readFileSync } from "node:fs";
import { createHmac } from "node:crypto";
const file = process.argv[2] || "/opt/media-gateway/.env";
const line = readFileSync(file, "utf8").split("\n").find(l => l.trim().startsWith("MEDIA_GATEWAY_SECRET="));
if (!line) { console.error("MEDIA_GATEWAY_SECRET not found"); process.exit(1); }
const raw = line.slice(line.indexOf("=") + 1);
const value = raw.trim().replace(/^["']|["']$/g, "");
const fp = v => createHmac("sha256", v).update("letsmeet-media-gateway-fingerprint").digest("hex").slice(0, 16);
console.log(`fingerprint: ${fp(value)}   (length ${value.length})`);
if (raw !== value) console.log("note: the file's value has surrounding quotes or spaces; the fingerprint is of the value without them");
