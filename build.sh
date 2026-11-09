#!/bin/zsh
# Build "Claude Sessions.app" with the Swift command line tools (no Xcode),
# generate its icon, install it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

NAME="Claude Sessions"
EXE=ClaudeSessions
APP="build/$NAME.app"
# The version lives in VERSION; APP_VERSION overrides it (used to test updates).
VERSION="${APP_VERSION:-$(cat VERSION)}"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Work around a Command Line Tools bug: usr/include/swift has both
# module.modulemap and bridging.modulemap defining `SwiftBridging`, which breaks
# `import SwiftUI`. A VFS overlay hides the duplicate for this build only.
SWIFT_INC="$(xcode-select -p)/usr/include/swift"
EXTRA=()
if [[ -f "$SWIFT_INC/module.modulemap" && -f "$SWIFT_INC/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/overlay.yaml <<YAML
{ "version": 0, "roots": [ { "type": "file",
  "name": "$SWIFT_INC/module.modulemap",
  "external-contents": "$PWD/build/empty.modulemap" } ] }
YAML
  EXTRA=(-vfsoverlay "$PWD/build/overlay.yaml")
fi

# UNIVERSAL=1 builds for Apple Silicon and Intel (for sharing); otherwise
# just this Mac's architecture, which is twice as fast.
ARCHS=($(uname -m))
[[ "${UNIVERSAL:-0}" == 1 ]] && ARCHS=(arm64 x86_64)
SLICES=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -parse-as-library -target $arch-apple-macos15.0 "${EXTRA[@]}" \
    Sources/*.swift -o "build/$EXE-$arch"
  SLICES+=("build/$EXE-$arch")
done
lipo -create $SLICES -output "$APP/Contents/MacOS/$EXE"

# App icon: the binary draws a 1024px PNG; sips + iconutil make the .icns.
ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"
"$APP/Contents/MacOS/$EXE" --write-icon build/icon_1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.aibyos.claude-sessions</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Orkhan Amrullayev · aibyos.com · MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x "$EXE" || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$NAME.app"
  cp -R "$APP" ~/Applications/
  open ~/Applications/"$NAME.app"
  echo "Installed and launched ~/Applications/$NAME.app"
fi
