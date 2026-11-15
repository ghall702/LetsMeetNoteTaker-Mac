# Media gateway install (mediahub-lm-1.georgehalltuition.com)

Nothing here has been deployed or tested on the VPS yet. The gateway itself was tested locally (upload, size limit, Range seeking, expired/forged/wrong-type links, delete).

## What runs
- **SFTPGo**: stores files under `/srv/sftpgo/data`. Its admin UI is bound to localhost only; reach it with `ssh -L 8080:127.0.0.1:8080 you@vps`.
- **gateway.mjs**: a zero-dependency Node 20 server (~40 MB RAM). It accepts only HMAC links signed by the website that expire after 15 min for playback, 2 h for uploads or 60 s for checks/deletes. It writes uploads to a temporary `.part` file and renames it only when complete, serves HTTP Range for seeking, and never logs tokens.
- **Caddy**: HTTPS certificates and reverse proxy.

## Steps
1. DNS: an A record for `mediahub-lm-1.georgehalltuition.com` pointing to the VPS IP. Open ports 80, 443 and 2022 (SFTP, optional).
2. Install Docker: `curl -fsSL https://get.docker.com | sh`
3. `sudo mkdir -p /srv/sftpgo/data/recordings /srv/sftpgo/home && sudo chown -R 1000:1000 /srv/sftpgo`
4. Copy this folder to `/opt/media-gateway`, then `cp .env.example .env` and paste the secret (same value as the website's MEDIA_GATEWAY_SECRET).
5. `cd /opt/media-gateway && docker compose up -d`
6. Check: `curl https://mediahub-lm-1.georgehalltuition.com/health` should return `{"ok":true}`.
7. Optional: in the SFTPGo admin, create a read-only user with home `/srv/sftpgo/data/recordings` so you can browse the files over SFTP.

Files live at `recordings/rooms/<room_id>/<recording_id>/<file_id>.mp4`.

## Rotating the secret
Change it on the website and in `.env` at the same time, then `docker compose up -d`. Links already issued stop working; pupils just press play again.
