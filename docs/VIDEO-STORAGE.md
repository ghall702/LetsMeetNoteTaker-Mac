# How lesson videos are stored and organised

This explains where lesson videos live on the media server (mediahub-lm-1), how the files are named and
organised, how they get there, and how they are protected. It is based on the gateway code
(`server/media-gateway/gateway.mjs`), the recordings API (`LESSON-RECORDINGS-API.md`), the server handoff and
the storage update of 15 November 2026. Items marked *(check on the server)* depend on how the gateway was
installed and should be confirmed there.

## 1. The big picture

```
Mac app ──(API key)──▶ LetsMeet website ──(signed, expiring link)──▶ Mac app
   │                         │  keeps the recording record (database)
   │                         ▼
   └──── video bytes ───▶ media gateway (mediahub-lm-1) ──▶ 3 TB HDD
                             ▲
Pupil / Admin Tools ─────────┘  plays the video through a short-lived signed link
```

- The **website** decides *what* is stored: it owns the recording records (which note, which pupil room,
  status, size, original file name) and creates the storage path for every file.
- The **media gateway** decides nothing on its own: it only reads, writes, checks or deletes the exact file
  named in a link the website has signed.
- **Video bytes never pass through the website.** Uploads and playback go straight between the Mac or the
  viewer's browser and the media server.

## 2. Where the files physically are

| | |
|---|---|
| Drive | 3 TB HDD, `/dev/vdb1`, ext4 |
| Mounted at | `/mnt/storage` |
| SFTPGo data folder | `/mnt/storage/sftpgo/data` (also reachable as `/srv/sftpgo/data`, which points to it) |
| Recordings folder | `/srv/sftpgo/data/recordings` → physically `/mnt/storage/sftpgo/data/recordings` *(check on the server: the gateway's `DATA_DIR`)* |

The 30 GB system disk holds the operating system and programs only; no videos are written there. SFTPGo and
the gateway are set to wait for the HDD to be mounted before they start, so they can't accidentally write
onto the system disk if the drive is missing.

## 3. Folder layout

```
recordings/                                    ← the gateway's DATA_DIR
├── rooms/
│   └── <room_id>/                             ← one folder per LetsMeet pupil room
│       └── <recording_id>/                    ← one folder per recording
│           └── <file_id>.mp4                  ← the video file itself
└── .gateway-stats/
    └── stats.json                             ← traffic counters for the dashboard
```

Example:

```
recordings/rooms/3ae368a1b979e5f6e0aba39d3103b7e1/8f0c2b6e-1c4a-4f7e-9a51-2d3b7e0c9a11/41d9c0f2-77b3-4c6e-8e2a-5b9f1a0d3c47.mp4
```

| Part | What it is |
|---|---|
| `room_id` | The pupil's LetsMeet room: 32 lowercase hex characters, the same id the notes API uses. All of a pupil's videos sit together. |
| `recording_id` | The website's id for the recording (a UUID). One recording = one video attached to one lesson note. |
| `file_id` | A UUID for this particular file. It changes when a video is replaced, so a new file never overwrites the old one in place. |

The full path from `rooms/` onwards is the recording's **`storage_ref`** in the website's database. The gateway
only accepts paths of exactly this shape (`rooms/<32 hex>/<uuid>/<uuid>.mp4`) and refuses anything that would
point outside the recordings folder.

### What the names don't contain

File and folder names are ids only — no pupil names, dates or original file names. The original file name
(for example `2026-11-15 LetsMeet - DT combined.mp4`), title, size, duration and status are kept in the
website's database, not in the file system. To find which lesson a file belongs to, look up its
`recording_id` on the website.

### One lesson note, one video

- **Single recording:** the Mac uploads the original Zoom MP4 as it is.
- **Combined lesson** (several Zoom recordings combined into one set of notes): the Mac first joins them, in
  their saved order, into one continuous MP4. Only that joined file is uploaded, so it is **one** recording and
  **one** `.mp4` on the server.
- **Separate parts:** each part has its own note, and each note gets its own recording and file.

## 4. How a file arrives (upload)

1. The Mac asks the website to register the upload (`POST /recordings/upload`) with a stable upload id.
   The website creates the recording record (status `uploading`), chooses the `storage_ref`, and returns a link
   to the media server that is valid for 2 hours and only allows this one file, up to the declared size.
2. The Mac sends the video to that link. The gateway writes it to a **temporary file** next to the final one,
   named `<file_id>.mp4.part-<random>`.
3. Only when the whole file has arrived is it renamed to `<file_id>.mp4`. Renaming is instant and atomic, so a
   half-finished upload is never visible and never replaces a working file. If the connection drops, the
   temporary file is deleted.
4. The Mac tells the website the upload is complete. The website asks the gateway whether the file exists and
   has the expected size; only then is the recording marked `ready`.

Pupils only ever see recordings that are `ready`, and only on notes that have been published.

Retrying is safe: registering again with the same upload id returns the same recording (with a fresh link), so a
retry never creates a second copy.

## 5. Replacing and deleting

**Replace:** the website gives the recording a new `file_id`. The new file is uploaded and checked first; only
when it is confirmed does it go live and the old file get deleted. If anything fails along the way, the old
video keeps playing.

**Delete:** the website hides the recording immediately and asks the gateway to delete the file.
- If that works, the record and the file are both gone (`deleted`).
- If the media server doesn't answer, the recording is hidden from pupils and blocked from playback
  (`delete_pending`), and the delete is retried later (from the Mac app or Admin Tools).

Deleting a video on the server never touches the original recordings on the Mac.

## 6. Who can get at the files

| Operation | How it is authorised | Link lifetime |
|---|---|---|
| Upload | Signed upload link from the website | 2 hours |
| Play / download | Signed playback link from the website (pupils via their Microsoft sign-in; staff via Admin Tools or the Mac app) | 15 minutes |
| Check a file, delete a file | Signed link, used by the website itself | 60 seconds |
| Statistics | Signed link, used by the website itself | 60 seconds |

- Links are signed with `MEDIA_GATEWAY_SECRET`, which only the website and the gateway know. The Mac app
  never has it.
- A link names one exact file and one action; it can't be reused for another file or action.
- There is no way to list or browse recordings over the web.
- The gateway doesn't log links (they contain the token), and Caddy's access logging is off for the same reason.
- SFTPGo's `mediahub-app` user has its own separate folder; it is not used for lesson videos. Don't add,
  rename or delete files in the recordings folder by hand — the website wouldn't know about the change.

## 7. Statistics file

`recordings/.gateway-stats/stats.json` holds the gateway's counters for the Mac app's Videos dashboard:
bytes uploaded and played per day (in UK time), the whole server's network traffic per day, and when counting
started. It is saved every 30 seconds and on shutdown, and keeps about 13 months of days. It contains no
video data, links or secrets. Deleting it only resets the traffic history.

The recording count and total size are not stored: the gateway counts the `.mp4` files when it starts,
updates the count on every upload, replacement and deletion, and recounts every 6 hours.

## 8. Useful checks on the server

Run as root over SSH. These only read.

```bash
# Is the HDD mounted, and how full is it?
findmnt /mnt/storage
df -h /mnt/storage

# Number and total size of lesson videos
find /srv/sftpgo/data/recordings/rooms -name '*.mp4' -type f | wc -l
du -sh /srv/sftpgo/data/recordings/rooms

# Space used per pupil room
du -sh /srv/sftpgo/data/recordings/rooms/* | sort -h

# Unfinished uploads (normally none; a crash mid-upload can leave one behind)
find /srv/sftpgo/data/recordings/rooms -name '*.part-*' -mmin +240 -ls

# The file for a recording id from the website
find /srv/sftpgo/data/recordings/rooms -path '*/<recording_id>/*'
```

A `.part-…` file older than a few hours belongs to an upload that can no longer finish and can be removed.

## 9. On the Mac

- Original Zoom recordings stay where they are and are only ever read.
- Joined videos for combined lessons are created in the app's data folder
  (`~/Library/Containers/com.georgehalltuition.lessonnotes/Data/Library/Application Support/LessonNotes/Videos`),
  or in a folder chosen in Settings → Videos, named `merged-<lesson job id>.mp4`. By default each one is deleted
  once the website confirms the upload. Settings → Videos also shows how much space they use and can remove
  any that are no longer needed.
- The app keeps each upload's state (upload id, recording id, stage) with the lesson, so a restart carries on
  where it stopped without uploading twice.

## 10. Backups

The gateway doesn't back up videos. Each recording exists once on the HDD (the original stays on the Mac).
If the server copies need protecting, add a backup of `/mnt/storage/sftpgo/data/recordings` — for example a
nightly copy to another server or object storage — and include `.gateway-stats` if the traffic history matters.
