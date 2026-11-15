# Task for the LetsMeet website: `GET /api/public/lesson-notes/media/stats`

The Mac app's Videos dashboard needs live storage and bandwidth figures from the media server. The media
gateway now has a signed `/stats` endpoint. Please add one API endpoint that fetches it server-side and
returns it together with recording counts from the database.

## Endpoint

`GET /api/public/lesson-notes/media/stats`

- Auth: the same `Authorization: Bearer ghln_…` API keys as the other lesson-notes endpoints (same key
  checks, revocation and shared rate limit). Pupil sign-ins must not be able to use it.
- `Cache-Control: no-store`.

## What it does

1. Mint a gateway token exactly like the existing upload/playback tokens, with claims
   `{"op":"stats","exp": <now + 60 seconds, unix seconds>}` — no `ref`.
   Format: `base64url(JSON) + "." + base64url(HMAC-SHA256(that base64url string, MEDIA_GATEWAY_SECRET))`.
2. Server-side `GET https://mediahub-lm-1.georgehalltuition.com/stats?t=<token>` (10 s timeout).
   This is a small JSON request — no video passes through the website.
3. Count recordings in the recordings table (excluding `deleted`): how many are `ready`, `uploading`,
   `failed`, `delete_pending`, and the sum of `size_bytes` of `ready` ones.

## Response 200

```json
{
  "fetched_at": "2026-11-15T19:02:11.500Z",
  "gateway": { …the gateway's JSON, passed through unchanged… },
  "recordings": { "ready": 40, "uploading": 1, "failed": 0, "delete_pending": 0, "ready_bytes": 29400000000 }
}
```

The gateway's JSON looks like this (pass it through as-is):

```json
{
  "ok": true, "generated_at": "…", "timezone": "Europe/London",
  "volume": { "path": "…", "real_path": "/mnt/storage/sftpgo/data/recordings", "total_bytes": 0, "used_bytes": 0, "available_bytes": 0, "free_bytes": 0 },
  "recordings": { "count": 0, "bytes": 0, "indexed_at": "…" },
  "traffic": { "scope": "media-gateway", "since": "…", "days": [ { "date": "2026-11-15", "upload_bytes": 0, "playback_bytes": 0 } ] },
  "server_traffic": { "scope": "host-network-interfaces", "available": true, "since": "…", "days": [ { "date": "2026-11-15", "rx_bytes": 0, "tx_bytes": 0 } ] }
}
```

## Errors (standard `{"error":{"code","message"}}` envelope)

- Gateway unreachable, timed out, non-200, or 403 → `503`, code `storage_unavailable`, `"retryable": true`,
  header `Retry-After: 30`. Please still include `"recordings": {…}` in the body if the database counts worked.
- `401 / 403 / 429` as for the other endpoints.

## Notes

- Use the existing `MEDIA_GATEWAY_SECRET`; don't expose it or the gateway URL with a token to the client.
- Don't add caching longer than a few seconds — the app polls about once a minute only while its
  Videos page is open.
