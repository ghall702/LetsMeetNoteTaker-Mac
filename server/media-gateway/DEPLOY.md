# Deploying the media gateway on mediahub-lm-1

Status (15 Nov 2026): **the original gateway is deployed** (by Grok, systemd, recordings on the HDD) and
uploads/playback/deletion work end to end. The **statistics** need this folder's updated `gateway.mjs` and a
Caddy route for `/stats` — see “Updating an existing deployment” below. A fresh install follows steps 0–6.

These steps add the gateway next to the existing services. They do not
reinstall or reconfigure SFTPGo, and the only change to Caddy is routing six gateway paths to the gateway.
Run them over SSH as root, after reviewing each step.

Current server (from HANDOFF.md and the storage update): Ubuntu 20.04, native SFTPGo (systemd) and
Caddy (systemd); 3 TB HDD `/dev/vdb1` mounted at `/mnt/storage` (ext4); SFTPGo data in
`/mnt/storage/sftpgo/data` with `/srv/sftpgo/data` a symlink to it; secret in `/opt/media-gateway/.env`.

## 0. Check first (read-only)

```bash
findmnt /mnt/storage                      # must show /dev/vdb1 ext4
readlink -f /srv/sftpgo/data              # must print /mnt/storage/sftpgo/data
df -h /mnt/storage /                      # HDD ~3 TB; system disk ~30 GB
systemctl show -p User -p Group sftpgo    # the user the gateway should run as (expected: sftpgo)
systemctl status sftpgo caddy --no-pager
cat /etc/caddy/Caddyfile                  # compare with Caddyfile.existing-server
ss -ltnp | grep -E ':8787|:8080'          # 8787 must be free
node --version 2>/dev/null || echo "no node"
ls -l /opt/media-gateway/                 # only .env expected
grep -c '^MEDIA_GATEWAY_SECRET=' /opt/media-gateway/.env   # 1 (don't print the value)
```

If `sftpgo` runs as a different user, use that user in `media-gateway.service` and in step 3.
If the Caddyfile has anything beyond the single reverse proxy to 127.0.0.1:8080, merge by hand.

## 1. Node.js 20+ (Ubuntu 20.04 ships an old version)

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
node --version    # v20.x or later
```

## 2. Gateway files

Copy `gateway.mjs` and `media-gateway.service` from this folder to the server (e.g. `scp`), then:

```bash
install -m 0644 gateway.mjs /opt/media-gateway/gateway.mjs
chmod 600 /opt/media-gateway/.env && chown root:root /opt/media-gateway/.env
```

## 3. Recordings folder on the HDD

```bash
mkdir -p /mnt/storage/sftpgo/data/recordings
chown sftpgo:sftpgo /mnt/storage/sftpgo/data/recordings
chmod 750 /mnt/storage/sftpgo/data/recordings
```

Files will live at `/srv/sftpgo/data/recordings/rooms/<room_id>/<recording_id>/<file_id>.mp4`
(physically on `/mnt/storage`). Statistics counters: `.../recordings/.gateway-stats/stats.json`.

## 4. Service

```bash
install -m 0644 media-gateway.service /etc/systemd/system/media-gateway.service
systemctl daemon-reload
systemctl enable --now media-gateway
systemctl status media-gateway --no-pager
curl -s http://127.0.0.1:8787/health      # {"ok":true}
```

## 5. Caddy (backup first)

```bash
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak-$(date +%F)
cp Caddyfile.existing-server /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
curl -s https://mediahub-lm-1.georgehalltuition.com/health          # {"ok":true}
curl -s -o /dev/null -w '%{http_code}\n' https://mediahub-lm-1.georgehalltuition.com/stats   # 403 (needs a token)
curl -s -o /dev/null -w '%{http_code}\n' https://mediahub-lm-1.georgehalltuition.com/web/admin  # SFTPGo still answers
```

## 6. End-to-end test (before any backfill)

1. The website must use the same `MEDIA_GATEWAY_SECRET` and `https://mediahub-lm-1.georgehalltuition.com`.
2. In the Mac app, on one lesson in History press **Upload Video** (a short lesson is best).
3. Check: the app shows it as Uploaded; the file exists under `/mnt/storage/sftpgo/data/recordings/rooms/…`;
   it plays in Admin Tools; seeking works.
4. Delete it from the app (Videos → … → Delete from LetsMeet) and confirm the file is removed.
5. Once the website's `/media/stats` endpoint exists, the app's Videos dashboard shows live storage and traffic.

Only then start the historical backfill from the app.

## Updating an existing deployment (adds /stats)

Today `https://mediahub-lm-1.georgehalltuition.com/stats` returns a plain `{"message":"Not Found"}`, so either
the deployed `gateway.mjs` is the original version or Caddy doesn't send `/stats` to it (or both).

```bash
systemctl cat media-gateway                     # note ExecStart path, User, DATA_DIR, ReadWritePaths
cp /opt/media-gateway/gateway.mjs /opt/media-gateway/gateway.mjs.bak-$(date +%F)
diff /opt/media-gateway/gateway.mjs.bak-$(date +%F) gateway.mjs | head    # only the statistics additions
install -m 0644 gateway.mjs /opt/media-gateway/gateway.mjs
# Counters are written to $DATA_DIR/.gateway-stats (on the HDD); that path must be inside ReadWritePaths.
grep -n 'reverse_proxy' /etc/caddy/Caddyfile    # make sure /stats is routed to the gateway like /u and /v
caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
systemctl restart media-gateway && sleep 2 && systemctl status media-gateway --no-pager
curl -s -o /dev/null -w '%{http_code}\n' https://mediahub-lm-1.georgehalltuition.com/stats   # 403 = live, needs a token
```

Then LetsMeet needs `GET /api/public/lesson-notes/media/stats` (STATS.md §2). Traffic history starts from this
restart; earlier traffic isn't known.

## Rollback

```bash
systemctl disable --now media-gateway
cp /etc/caddy/Caddyfile.bak-<date> /etc/caddy/Caddyfile && systemctl reload caddy
```

Recordings already uploaded stay in `/mnt/storage/sftpgo/data/recordings`.

## Notes

- `docker-compose.yml` is for a fresh server; don't run it here.
- The Caddy route keeps SFTPGo's web admin public at this domain as it is today; consider restricting
  `/web/admin` by IP or turning on 2FA (HANDOFF.md also recommends 2FA).
- Ubuntu 20.04 is past standard support (HANDOFF.md): plan Ubuntu Pro or an upgrade.
