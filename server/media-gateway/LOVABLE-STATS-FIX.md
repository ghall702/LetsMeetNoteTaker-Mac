# /media/stats: the gateway rejects the website's token (HTTP 403)

The media gateway's log shows the website's requests to `GET /stats` rejected with **403** (invalid
token). The gateway itself is fine: a token signed on the server with the real secret returns 200. Upload
links signed by the website are accepted, so the upload code has the right secret and signing. The stats
code is doing something different. Please check, most likely first:

1. **Secret** — use exactly the same `MEDIA_GATEWAY_SECRET` value (and the same way of reading it) as the
   code that signs upload links. No extra spaces or newline. If the stats endpoint is a separate function,
   make sure it has access to the secret at all (an empty/undefined secret produces a wrong signature).
2. **Claims** — exactly `{"op":"stats","exp":<unix time in seconds, now + 60>}`. `stats`, not `stat`. No other
   requirements (no `ref`).
3. **Encoding** — token = `base64url(JSON)` + `"."` + `base64url(HMAC-SHA256(key = secret, message = that
   base64url string))`. base64url without padding (`-` and `_`, no `=`). Not hex, not standard base64, and the
   HMAC is over the **base64url string**, not over the raw JSON.
4. **Method/URL** — `GET https://mediahub-lm-1.georgehalltuition.com/stats?t=<token>`. POST is always rejected.

## Test vector (check your signing function with this)

```
secret: test-secret-0123456789abcdef0123456789abcdef
json:   {"op":"stats","exp":1800000000}
body:   eyJvcCI6InN0YXRzIiwiZXhwIjoxODAwMDAwMDAwfQ
sig:    SgRxk-q_dfQxUZChIRLvwCOptwoKzb4Mu6bn6BTeNis
token:  eyJvcCI6InN0YXRzIiwiZXhwIjoxODAwMDAwMDAwfQ.SgRxk-q_dfQxUZChIRLvwCOptwoKzb4Mu6bn6BTeNis
```

Your code, given that secret and that exact JSON string, must produce exactly that token.

## Secret fingerprint (compare without revealing the secret)

Compute and send this from the website side; the server side runs `node fingerprint.mjs`:

```ts
// Deno / edge function
async function secretFingerprint(secret: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode("letsmeet-media-gateway-fingerprint")));
  return Array.from(mac).map(b => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
}
```

For the test secret above the fingerprint is `cecd259d9dacf710`. Also report the secret's length.
Log/compare the fingerprint of the value **the stats code actually uses**.

## Also please

- When the gateway doesn't return 200, log its status code and body (they contain no secrets).
