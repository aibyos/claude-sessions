#!/bin/zsh
# Build a universal (Apple Silicon + Intel) app and zip it for sharing.
# Output: dist/Claude-Sessions.zip
set -euo pipefail
cd "$(dirname "$0")"
UNIVERSAL=1 ./build.sh --no-install
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "build/Claude Sessions.app" dist/Claude-Sessions.zip
echo "Created dist/Claude-Sessions.zip ($(du -h dist/Claude-Sessions.zip | cut -f1))"
lipo -archs "build/Claude Sessions.app/Contents/MacOS/ClaudeSessions"
