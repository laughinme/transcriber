#!/bin/zsh
# Release build packed into dist/Расшифровка.app (ad-hoc signed, runs locally without Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Расшифровка"
APP="dist/$APP_NAME.app"
VERSION="${VERSION:-1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

swift build -c release --product Transcriber
BIN="$(swift build -c release --show-bin-path)/Transcriber"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Transcriber"

# Icon: drawn by script, cached in Resources/AppIcon.icns.
if [[ ! -f Resources/AppIcon.icns || scripts/make-icon.swift -nt Resources/AppIcon.icns ]]; then
  tmp="$(mktemp -d)"
  swift scripts/make-icon.swift "$tmp/icon.png" >/dev/null
  mkdir "$tmp/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$tmp"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($VERSION, build $BUILD)"
