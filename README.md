# Let's Meet Lesson Notes (macOS)

A native macOS menu-bar app (Swift/SwiftUI, macOS 14+, Apple Silicon) for George Hall Tuition. It watches the Zoom
recordings folder, transcribes lessons **on the Mac** with WhisperKit, writes structured lesson notes with OpenAI
(Responses API, `store: false`) and uploads the notes **and the complete transcript** to the Let's Meet website API,
where notes wait for approval.

## Installing (no developer tools needed)

1. Download the latest `LetsMeet-Lesson-Notes-…dmg` from the repository's **Releases** page (or the
   *LetsMeet-Lesson-Notes-DMG* artifact of the latest *Build macOS app* run under **Actions**).
2. Open the DMG and drag **Let's Meet Lesson Notes** onto **Applications**.
3. Open it from Applications. Because the build is not signed with an Apple Developer ID or notarised, macOS blocks
   the first launch: click **Done**, open **System Settings → Privacy & Security**, click **Open Anyway** next to
   "Let's Meet Lesson Notes", confirm, then **Open**. This is needed once per installed build.
4. The Setup Assistant opens. The app then lives in the menu bar.

Keychain note: because test builds are ad-hoc signed, after installing a *new* build macOS may ask whether
"Lesson Notes" may use the items saved in your keychain — click **Always Allow**.

## What it does

| Area | Implementation |
| --- | --- |
| Menu bar + main window | `MenuBarExtra` (window style) with live progress; main window with Dashboard, History, Students, Settings; no Dock icon unless the window is open |
| Folder watching | FSEvents (recursive) on the chosen Zoom folder (security-scoped bookmark). Readiness: `.mp4`/`.m4a`, no `.zoom` placeholder, size unchanged across two 20 s checks, playable, > 30 s |
| Notifications | "New lesson recording found" with **Review** action; submitted / needs-attention / status-change notifications |
| Historical import | Import MP4s… / Import Folder… — recursive scan with progress, AVFoundation metadata, grouping into proposed lessons, bulk review table (pupil, date, combine/separate), duplicate check |
| Dates | Zoom folder name (local time, configurable time zone) → cloud file-name UTC stamp → embedded MP4 date → file creation → modification; uncertain dates flagged |
| Students | Rooms from `GET /rooms`; mappings keyed by permanent `room_id`; initials/code, meeting-name, folder, path-prefix and regex rules; "Remember this for next time" |
| Confirmation | Thumbnails, durations, video preview (AVPlayerView), ⌘/⇧-click multi-select + checkboxes, drag to reorder, Single / Combine / Separate, duplicate warning with Reprocess Anyway |
| Transcription | WhisperKit 1.1.1 (Core ML), in-app model list/download/progress/delete/storage, English or auto-detect, VAD chunking, timestamps and recording boundaries; temp 16 kHz WAV deleted after every job |
| OpenAI | Live `GET /v1/models` (filtered, searchable, cached offline, custom ID), Test Model with harmless sample data, reasoning effort, strict JSON schema, streaming, long-transcript chunking, error mapping |
| Prompts | Editable global prompt (save / reset / preview); per-student Global or Custom prompt; prompt snapshot stored per job; non-editable required rules always appended |
| Website API | ping, rooms, submit, single and batch status; bearer auth; validation of every §8.3 rule; idempotent retries with the frozen payload; status polling (10 min pending, daily for 30 days published) |
| Transcript upload | **Always** the complete transcript. UTF-8 byte limits: transcript ≤ 5,000,000, request body ≤ 6,000,000 (see `APILimits`). Oversized lessons are kept locally and marked *Needs attention* — never shortened, never retried |
| Queue | Persistent jobs (`held → queued → extracting → transcribing → summarising → submitting → submitted`), backoff 5 s…30 min for ≤ 24 h, `Retry-After`, offline waiting (NWPathMonitor), one transcription at a time, cancel / resume / Fix & Retry |
| Storage | `~/Library/Containers/com.georgehalltuition.lessonnotes/Data/Library/Application Support/LessonNotes` (JSON, atomic writes); keys in Keychain only; transcript retention setting |

## Project layout

```
Packages/LessonNotesCore   Platform-independent logic + 100 unit tests (API clients, engine, import, prompts…)
App/Sources                macOS app (SwiftUI views, AVFoundation, WhisperKit, Keychain, FSEvents)
project.yml                XcodeGen project definition
.github/workflows          macOS CI: tests → build → launch smoke test → DMG → pre-release
scripts/make-dmg.sh        Drag-to-Applications DMG
```

Build locally (optional): `brew install xcodegen && xcodegen generate && open LessonNotes.xcodeproj`.
Run core tests: `cd Packages/LessonNotesCore && swift test`.

## Changing the website limits

Edit `Packages/LessonNotesCore/Sources/LessonNotesCore/API/APILimits.swift` (`maxTranscriptBytes`, `maxRequestBodyBytes`).
