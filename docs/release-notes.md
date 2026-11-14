## Download

**[__DMG__](https://github.com/ghall702/LetsMeetNoteTaker-Mac/releases/download/BUILD_TAG/__DMG__)** — Apple Silicon Mac, macOS 14 Sonoma or later.

### Install or update
1. Quit Lesson Notes if it is running (menu bar icon → **Quit Lesson Notes**).
2. Open the DMG and drag **Let's Meet Lesson Notes** onto **Applications** (choose **Replace** when updating — your settings, keys, students, prompts and history are kept).
3. First launch only: macOS blocks apps that are not notarised. Open **System Settings → Privacy & Security** and click **Open Anyway**.
4. If macOS asks whether the app may use its saved keychain items, click **Always Allow**.

### What's in 1.1
- New note sections: **learning content**, **worked examples** and **key quotes**, written in Markdown
- Comprehensive new default system prompt (customised prompts are kept)
- Strict empty-field handling — no "None" or "No homework" filler
- Fixed truncated notes: only complete, validated OpenAI responses are accepted
- **Regenerate Notes** from the saved transcript, side-by-side comparison and local version history
- **Replace Existing Notes** on Let's Meet, with safe retries and version-conflict handling

### Build checks
| | |
|---|---|
| Unit tests | __TESTS__ |
| Build | Release, arm64, Xcode on GitHub's macOS runner |
| Launch smoke test | passed |
| Signing | ad-hoc (not Developer ID signed or notarised) |
| SHA-256 | `__SHA__` |

Built from `__COMMIT__` · [build log](__RUN__)
