#!/bin/bash
# Packages the built app into a drag-to-Applications DMG.
# Usage: scripts/make-dmg.sh "<path to .app>" "<output .dmg>"
set -euo pipefail
APP="$1"
OUT="$2"
NAME="Let's Meet Lesson Notes"
STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Let's Meet Lesson Notes — installation

1. Drag "Let's Meet Lesson Notes" onto the Applications folder.
2. Open Applications and double-click "Let's Meet Lesson Notes".

This test build is not signed with an Apple Developer ID or notarised, so macOS
will say it "cannot be opened" or "could not be verified" the first time.
To allow it (once):
  • Click "Done" / "OK" on the warning.
  • Open System Settings → Privacy & Security.
  • Scroll down to the message about "Let's Meet Lesson Notes" and click "Open Anyway".
  • Confirm with your password or Touch ID, then click "Open".

The app then appears in the menu bar (a note icon at the top right of the screen).
TXT
rm -f "$OUT"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT"
hdiutil verify "$OUT"
