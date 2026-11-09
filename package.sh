#!/bin/zsh
# Build a universal (Apple Silicon + Intel) app, zip it and sign the zip for
# the in-app updater.
# Output: dist/Claude-Sessions.zip and dist/Claude-Sessions.zip.sig
#
# The signing key is a private file that must never be committed. Default
# location: ~/.config/aibyos/claude-sessions-update.key (override with
# UPDATE_KEY=...). Installed copies only accept updates signed with it.
set -euo pipefail
cd "$(dirname "$0")"

KEY="${UPDATE_KEY:-$HOME/.config/aibyos/claude-sessions-update.key}"
if [[ ! -f "$KEY" ]]; then
  echo "Signing key not found at $KEY." >&2
  echo "Without it, installed copies can't verify this release and won't update." >&2
  exit 1
fi

UNIVERSAL=1 ./build.sh --no-install
APP="build/Claude Sessions.app"
VERSION="${APP_VERSION:-$(cat VERSION)}"

rm -rf dist
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Claude-Sessions.zip
"$APP/Contents/MacOS/ClaudeSessions" --sign-update dist/Claude-Sessions.zip "$KEY" > dist/Claude-Sessions.zip.sig

echo "Created dist/Claude-Sessions.zip ($(du -h dist/Claude-Sessions.zip | cut -f1)), version $VERSION, $(lipo -archs "$APP/Contents/MacOS/ClaudeSessions")"
echo "Signed: dist/Claude-Sessions.zip.sig"
echo
echo "Publish with:"
echo "  gh release create v$VERSION dist/Claude-Sessions.zip dist/Claude-Sessions.zip.sig \\"
echo "    --repo aibyos/claude-sessions --title \"Claude Sessions $VERSION\" --notes \"What changed...\""
echo "Add [important] to the notes to show a pop-up instead of only a badge."
