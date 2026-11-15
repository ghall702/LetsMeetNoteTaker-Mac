## Download

**[__DMG__](https://github.com/ghall702/LetsMeetNoteTaker-Mac/releases/download/BUILD_TAG/__DMG__)** — Apple Silicon Mac, macOS 14 Sonoma or later.

### Install or update
1. Quit Lesson Notes if it is running (menu bar icon → **Quit Lesson Notes**).
2. Open the DMG and drag **LetsMeet Lesson Notes** onto **Applications**. Your settings, keys, students, prompts, queue and history are kept.
   **Updating from 1.5 or earlier only:** the app has been renamed, so the old copy is not replaced automatically — after copying the new one, drag the old **Let's Meet Lesson Notes** from Applications to the Bin. Only ever run one copy.
3. First launch only: macOS blocks apps that are not notarised. Open **System Settings → Privacy & Security** and click **Open Anyway**.
4. If macOS asks whether the app may use its saved keychain items, click **Always Allow**.

### What's in 1.9
- **Lesson videos on LetsMeet:** after a lesson's notes are uploaded, its recording is uploaded and attached to the same note (Settings → Videos; on by default for new lessons). Uploads go straight to your media server through LetsMeet's signed, expiring links and stream from disk.
- **Combined lessons become one video:** recordings that were combined into one set of notes are joined into one continuous MP4 in their saved order (lossless when the parts match, re-encoded only when they don't), checked, then uploaded. Separate lessons upload each part to its own note.
- **Historical backfill** (Videos page): finds lessons uploaded before this version, checks their original recordings, can look up which notes already have a video, and uploads the rest when you press **Start Backfill**. Pause, resume and retry at any time; progress survives quitting. Existing notes are never resubmitted or changed.
- **Video management:** watch or download (staff link), check availability, replace or delete a video on LetsMeet. Original recordings are never changed or deleted.
- Progress with percentage, size and speed, a separate queue (1–3 at once), automatic retries following the API guidance, and cleanup of joined files.

### Also in 1.8
- **Change the files on an uploaded note** — no new note needed:
  - **Update Files on LetsMeet** swaps the note's downloadable files only. The notes and their approval are unchanged, so a published note shows the new files straight away.
  - **Regenerate Notes** with changed files: accepting the new notes also replaces the files in the same update, and the note returns to Waiting for approval.
- **Share with pupil** switch on every file, next to **Include in AI context** — e.g. give OpenAI your model answers without sharing them.
- Files can be added, removed or swapped whenever the lesson isn't mid-upload. Changes to an uploaded note stay on this Mac until you send them. History shows the files currently on LetsMeet.
- The Regenerate Notes sheet lists the lesson's files so you can change what OpenAI sees for that regeneration.
- **PDF names:** new PDFs are named “macOS Preview <name>.pdf” (Settings → General → Lesson files to turn off).

### Also in 1.6
- **Lesson files:** attach up to 5 files to a lesson (PDF, Word, PowerPoint, Excel, text, CSV or images; up to 20 MB each) in the Confirm sheet or in History until the notes are written. They are uploaded with the note and pupils can download them once you approve it.
- **Files as AI context:** for each file choose **Slides**, **Student work**, **My work (exemplar)** or **Other material**, and switch **Include in AI context** on or off. Included files go to OpenAI with the transcript, labelled with what they are. PDFs are sent as PDFs (OpenAI sees the text and the pages, including diagrams and handwriting), images as images, and Word/PowerPoint/Excel/text as their text. Excluded files are uploaded for the pupil only.
- Files are copied into the app when added, so uploads and retries always send exactly the same files. Audio and video are never accepted.
- Renamed to **LetsMeet Lesson Notes**.

### Also in 1.5
- **Pause OpenAI Activity** (Dashboard button, menu bar and Lessons menu): recordings keep being transcribed on this Mac, but no notes are written with OpenAI until you resume — so a long backlog can transcribe without using today's allowance. Lessons dated today still get notes unless you turn that off, and **Write Notes Now** lets any single lesson through. Notes that are already written still upload.
- **Smoother app:** data is saved in the background instead of making the window wait (the cause of the spinning beachball, especially with a large history), and transcripts in History load in the background.

### Also in 1.4
- **Lesson length on LetsMeet:** every new note now includes `lesson_length` (total recording time in whole seconds, capped at 12 hours; left out when unknown). Visible only to you in Admin Tools.
- **Existing notes backfilled automatically:** for notes already sent by earlier versions, the app quietly sets just the lesson length on the website, one at a time in the background. The notes themselves are **not** resent — their content, version and approval status stay exactly as they are. Notes deleted on the website are marked as such; rate limits are respected.
- History shows each lesson's length and whether it is on the website.

### Also in 1.3
- **OpenAI usage counter:** Dashboard panel, menu bar line and a new **API Usage** page — tokens used today (UTC), the 250,000 complimentary allowance, estimated remaining, time to the 00:00 UTC reset, lessons today, and estimated spending today and this month, with green/amber/red indicators.
- **Per-lesson usage:** input, cached input, output and total tokens exactly as reported by OpenAI, plus a clearly labelled cost estimate.
- **Free allowance protection (optional):** before each request the app counts input tokens with OpenAI, adds the maximum output and a safety margin, and holds the lesson until after 00:00 UTC if it might not fit. A local safeguard, not an OpenAI billing cap.
- Configurable model pricing and complimentary-model list. Usage records stay on this Mac and contain no keys, transcripts or pupil details.

### What's in 1.2
- **Your work is protected on update:** before upgrading, the lesson history, settings, students and every saved transcript (including those of failed lessons) are backed up and verified. The upgrade is checked afterwards and never replaces data it cannot read.
- **Fix & Retry resumes from the last completed step:** lessons that failed at OpenAI reuse the saved transcript — no audio extraction or Whisper. Lessons with notes go straight to upload with the same submission ID (no duplicates).
- **OpenAI credits:** “no credits / insufficient quota” is recognised, shown clearly with a link to OpenAI billing, never retried automatically, and the transcript is kept. **Retry All** resumes every affected lesson once credit is added.
- **Simultaneous transcriptions:** choose 1–8 in Settings → Transcription (default 1), with memory warnings and automatic throttling under memory pressure.

### Also in 1.1
- Learning content, worked examples and key quotes; Markdown; strict empty fields; complete-response checking; Regenerate/Compare/Replace notes.

### Build checks
| | |
|---|---|
| Unit tests | __TESTS__ |
| Build | Release, arm64, Xcode on GitHub's macOS runner |
| Launch smoke test | passed |
| Signing | ad-hoc (not Developer ID signed or notarised) |
| SHA-256 | `__SHA__` |

Built from `__COMMIT__` · [build log](__RUN__)
