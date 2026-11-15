# Task for the VPS (mediahub-lm-1): add statistics to the media gateway

**Goal:** the media gateway that is already running gets a signed `/stats` endpoint (storage of the 3 TB
volume, recording count/size, upload/playback traffic). Uploads, playback and deletion must keep working
exactly as now. Do not change SFTPGo, the storage mount, the secret or any credentials.

Files in this pack:
- `gateway.mjs` — the updated gateway (the original plus statistics; the original behaviour is unchanged)
- `check-stats.mjs` — checks `/stats` on the server using the existing secret file; prints no secrets
- `test/gateway.test.mjs` — automated tests (`node --test test/gateway.test.mjs`, optional)
- `Caddyfile.existing-server` — example Caddy config with `/stats` routed to the gateway
- `STATS.md` — what `/stats` returns

## 1. Look before changing (read-only)

```bash
systemctl cat media-gateway             # note: ExecStart (path of gateway.mjs), User, EnvironmentFile, DATA_DIR, ReadWritePaths
systemctl status media-gateway --no-pager
node --version                          # must be 20 or newer
cat /etc/caddy/Caddyfile                # how /u, /v, /stat, /del, /health reach the gateway
readlink -f "$(systemctl show -p Environment media-gateway | grep -o 'DATA_DIR=[^ ]*' | cut -d= -f2)"   # should be under /mnt/storage
curl -s -o /dev/null -w '%{http_code}\n' https://mediahub-lm-1.georgehalltuition.com/stats            # today: 404 (not routed / not present)
```

## 2. Back up

```bash
GW=$(systemctl show -p ExecStart media-gateway | grep -o '/[^ ;]*gateway.mjs' | head -1); echo "$GW"
cp "$GW" "$GW.bak-$(date +%F)"
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%F)
```

## 3. Install the updated gateway

Copy this pack's `gateway.mjs` over the file at `$GW` (same path, same owner/permissions as before):

```bash
install -m 0644 -o root -g root gateway.mjs "$GW"
```

The gateway stores its statistics in `<DATA_DIR>/.gateway-stats/stats.json` (on the HDD, next to the
recordings). That folder must be writable by the service user — it is if `ReadWritePaths` (if used) covers
`DATA_DIR`. If not, add the real path of `DATA_DIR` to `ReadWritePaths` with `systemctl edit media-gateway`.

Optional settings (Environment= in the unit; defaults shown): `STATS_TZ=Europe/London`, `RESCAN_HOURS=6`.

```bash
systemctl daemon-reload
systemctl restart media-gateway
sleep 2 && systemctl status media-gateway --no-pager
```

## 4. Route /stats through Caddy

In `/etc/caddy/Caddyfile`, add `/stats` to the paths that are proxied to the gateway (the same block that
already handles `/u /v /stat /del /health`). For example, if it uses a matcher:

```
@gateway path /u /v /stat /del /stats /health
```

(`Caddyfile.existing-server` shows a complete example.) Keep access logging off — query strings carry tokens.

```bash
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

## 5. Check

```bash
node check-stats.mjs /opt/media-gateway/.env http://127.0.0.1:8787          # use the gateway's real port if different
curl -s -o /dev/null -w '%{http_code}\n' https://mediahub-lm-1.georgehalltuition.com/stats   # must be 403 (needs a token)
curl -s https://mediahub-lm-1.georgehalltuition.com/health                                     # {"ok":true}
```

`check-stats.mjs` must end with `OK` and show the volume under `/mnt/storage` with a total of about 3 TB.
Then repeat a normal upload/playback/delete test to confirm nothing else changed.

## Rollback

```bash
cp "$GW.bak-<date>" "$GW" && systemctl restart media-gateway
cp /etc/caddy/Caddyfile.bak-<date> /etc/caddy/Caddyfile && systemctl reload caddy
```

## Report back

The output of `check-stats.mjs` (it contains no secrets), and confirmation that `/stats` without a token gives 403.
