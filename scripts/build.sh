#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

mkdir -p .build
SDK="$(xcrun --sdk macosx --show-sdk-path)"

swiftc -O -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework AppKit \
  -framework Metal \
  -framework MetalKit \
  -framework Quartz \
  -framework CoreGraphics \
  -framework Network \
  -framework CryptoKit \
  Sources/Flake/*.swift \
  -o .build/Flake

APP="$ROOT/Flake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/Flake "$APP/Contents/MacOS/Flake"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
chmod +x "$APP/Contents/MacOS/Flake"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "OK → $APP"
echo "Запуск: open \"$APP\""
