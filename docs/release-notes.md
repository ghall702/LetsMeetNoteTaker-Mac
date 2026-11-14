## Download

**[__DMG__](https://github.com/ghall702/LetsMeetNoteTaker-Mac/releases/download/BUILD_TAG/__DMG__)** — Apple Silicon Mac, macOS 14 Sonoma or later.

### Install or update
1. Quit Lesson Notes if it is running (menu bar icon → **Quit Lesson Notes**).
2. Open the DMG and drag **Let's Meet Lesson Notes** onto **Applications** (choose **Replace** when updating — your settings, keys, students, prompts and history are kept).
3. First launch only: macOS blocks apps that are not notarised. Open **System Settings → Privacy & Security** and click **Open Anyway**.
4. If macOS asks whether the app may use its saved keychain items, click **Always Allow**.

### What's in 1.4
- **Lesson length on Let's Meet:** every new note now includes `lesson_length` (total recording time in whole seconds, capped at 12 hours; left out when unknown). Visible only to you in Admin Tools.
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
