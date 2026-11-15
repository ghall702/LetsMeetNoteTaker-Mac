# Media statistics

Used by the Mac app's Videos dashboard. Nothing here is public: the gateway only answers a
token signed by the website, and the Mac app only talks to the website with its `ghln_` key.

```
Mac app ──GET /api/public/lesson-notes/media/stats (Bearer ghln_…)──▶ LetsMeet website
LetsMeet website ──GET https://mediahub-lm-1…/stats?t=<signed, 60 s>──▶ media gateway
```

The website proxies one small JSON document. Video uploads and playback never go through it.

## 1. Gateway: `GET /stats?t=<token>`

Token claims: `{"op":"stats","exp":<unix seconds>}` signed exactly like the other gateway tokens
(base64url(JSON) + "." + base64url(HMAC-SHA256(body, MEDIA_GATEWAY_SECRET))). No `ref`.
Wrong, expired or missing token → `403 {"error":"invalid_or_expired_token"}`.

```json
{
  "ok": true,
  "generated_at": "2026-11-15T19:02:11.123Z",
  "timezone": "Europe/London",
  "volume": { "path": "/srv/sftpgo/data/recordings", "real_path": "/mnt/storage/sftpgo/data/recordings",
              "total_bytes": 3170000000000, "used_bytes": 12000000000, "available_bytes": 3000000000000, "free_bytes": 3150000000000 },
  "recordings": { "count": 42, "bytes": 30100000000, "indexed_at": "2026-11-15T18:59:00.000Z" },
  "traffic": { "scope": "media-gateway", "since": "2026-11-15T18:58:40.000Z",
               "days": [ { "date": "2026-11-15", "upload_bytes": 734003200, "playback_bytes": 81000000 } ] },
  "server_traffic": { "scope": "host-network-interfaces", "available": true, "since": "2026-11-15T18:58:41.000Z",
                      "days": [ { "date": "2026-11-15", "rx_bytes": 801000000, "tx_bytes": 95000000 } ] }
}
```

- `volume` is `statfs` of the folder that holds the recordings, i.e. the 3 TB HDD (`/mnt/storage`),
  never the 30 GB system disk. `real_path` lets you confirm that.
- `recordings` is a cached index of finished `.mp4` files (in-progress `.part` files excluded). It is
  built at start-up, updated on every upload/replace/delete, and rechecked every 6 hours — requests never
  scan the disk. `count`/`bytes` are `null` for the few seconds while the first scan runs.
- `traffic` counts bytes the gateway itself received (uploads) and sent (playback/downloads), per local day.
- `server_traffic` is the whole server's network traffic from `/proc/net/dev` (all interfaces except
  loopback/Docker), so it includes SFTP, SSH, updates etc. `available` is false until the first sample.
- Counters are saved to `<DATA_DIR>/.gateway-stats/stats.json` (on the HDD) every 30 s and on shutdown, so
  they survive restarts. History starts when this version of the gateway is first started — earlier traffic
  is not known and is not invented. Up to 62 days are returned (400 kept).

## 2. Website: `GET /api/public/lesson-notes/media/stats` (for Lovable)

Auth: `Authorization: Bearer ghln_…` (same keys as the notes API; pupils cannot use it). Rate limit shared.

The website mints a 60-second `stats` token, calls the gateway server-side, and returns:

```json
{
  "fetched_at": "2026-11-15T19:02:11.500Z",
  "gateway": { …the gateway JSON above, unchanged… },
  "recordings": {
    "ready": 40, "uploading": 1, "failed": 0, "delete_pending": 0,
    "ready_bytes": 29400000000
  }
}
```

`recordings` comes from the website's own recordings table (status counts, excluding `deleted`;
`ready_bytes` = sum of `size_bytes` of ready recordings).

Errors (standard envelope):
- `503 storage_unavailable` (`"retryable": true`, `Retry-After: 30`) — gateway unreachable, timed out or 403.
  Optionally still include `"recordings"` in the body so the app can show the website counts.
- `401/403/429` as for other endpoints.

Until this endpoint exists the Mac app shows “Server statistics aren't available yet” and only displays
figures it knows itself (its own uploads and queue) — it never fills in zeros or estimates.
