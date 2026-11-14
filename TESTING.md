# Testing record

## Automated (run on every push by `.github/workflows/build-macos.yml`, also run on Linux during development)

`Packages/LessonNotesCore` — 100 XCTest cases, all mocked (no network, no real keys):

| Area | Tests |
| --- | --- |
| Zoom folder parsing | standard names, full names and initials (`Daniel`, `LetsMeet - DT`), meeting-ID suffix, invalid dates, DST gap, cloud `GMT…` file names, file classification |
| Readiness | stable size over 2×20 s, `.zoom` placeholder, still writing, too short, not playable |
| Date inference | folder beats modified/copied file dates, metadata, placeholder metadata ignored, creation/modification fallbacks flagged, disagreement flagged, configurable time zone (BST/GMT/New York) |
| Grouping / large scans | Zoom-folder grouping, natural ordering, audio-only exclusion, loose-file clustering, 200-folder scan with converting folder skipped |
| Students | room-name match, initials code, regex / path rules, disabled & deleted rooms, renamed rooms by `room_id`, remember rule, persistence & old-format decoding |
| Prompts | global inheritance incl. future edits, custom override, empty custom fallback, required rules always appended, persistence, snapshot kept for retries |
| Website API | ping/rooms, bearer header, 201 then 200 replay with identical bytes, documented fields only (no audio/video), 409/413/422/401/403/429 (`Retry-After`)/5xx, 404 → deleted, batch status chunks of 100 |
| Upload limits | 5,000,000 / 6,000,000 byte constants, UTF-8 byte counting (é = 2, 😀 = 4), exactly-at-limit accepted, +1 byte rejected, body over 6 MB with transcript under 5 MB, missing/empty transcript invalid |
| Pipeline | single / combined (3 parts, one submission, boundaries & order) / separate (3 submissions, distinct ids, own transcripts); full transcript uploaded unaltered; upload failure retried without re-transcription or re-summarising and with the same id and payload; offline waiting; queue recovery after quit (interrupted transcription restarts, saved upload resumes); temp audio deleted on failure; oversized transcript → Needs attention, nothing uploaded, never retried, never purged; 413 not retried; OpenAI 401/429/refusal; held jobs; cancel/resume; reprocess = new ids |
| OpenAI | request shape (`store:false`, strict schema, reasoning only when chosen), output parsing, SSE streaming, refusal/incomplete, error mapping (invalid key, model not found, reasoning unsupported, structured output unsupported, quota, rate limit), model discovery filtering (embeddings/audio/image/realtime/moderation/legacy excluded, unknown future models kept), search, availability (never auto-replaced), cached list, Test Model success/incompatibility, chunking + consolidation |
| Other | SHA-256 vectors + streamed file hash, submission-id format, retry schedule & 24 h cap, failure classification, duplicate lookup, retention, local delete, status-sync schedule (10 min / daily ×30 days / final states) and unpublish→pending, lesson factory validation, settings defaults |

The CI job then builds the app (Release, arm64), verifies the code signature and entitlements, launches the app
for 25 seconds as a smoke test, and packages the DMG.

## Needs testing with real recordings and keys (cannot be automated in CI)

1. Setup Assistant with a real `ghln_` key: Test Connection (`/ping`) and room list.
2. OpenAI key: Refresh Models shows your account's models; Test Model succeeds for your chosen model and the chosen reasoning effort.
3. Download a Whisper model (recommended one first); check storage figure and Delete.
4. Choose `~/Documents/Zoom`; finish a short Zoom test meeting with local recording; confirm the notification appears only after Zoom finishes converting, and Review opens the confirmation sheet with the right pupil.
5. Process one real lesson end to end; check the note appears as *Waiting for approval* in Admin Tools with the full transcript, then approve it and use **Check Website Statuses** in the app.
6. Combined and separate modes with a lesson that has 2–3 recordings.
7. Import Folder… on a copy of historical recordings; check dates, grouping and pupil suggestions.
8. Turn Wi-Fi off during "Submitting", turn it back on, and check exactly one note is created.
9. Quit the app during transcription and relaunch; the job restarts transcription and temp audio is gone.
10. Delete a note on the website and check the app shows *Deleted* after a status check.
11. Optional: confirm with a proxy (e.g. Proxyman) that no request contains audio or video.
