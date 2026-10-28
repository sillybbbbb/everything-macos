#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/everything.app"
CACHE="${TMPDIR:-/tmp}/everything-swift-cache"
mkdir -p "$BUILD" "$CACHE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/EverythingIcon.icns" "$APP/Contents/Resources/"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD/search-src" "$BUILD/indexer-src"
cp "$ROOT/Sources/Search.swift" "$BUILD/search-src/main.swift"
cp "$ROOT/Sources/Indexer.swift" "$BUILD/indexer-src/main.swift"
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos12.0" -module-cache-path "$CACHE" "$ROOT/Sources/SharedSources.swift" "$BUILD/search-src/main.swift" -o "$BUILD/Search-$ARCH" -framework Cocoa -framework Quartz -framework Carbon
  xcrun swiftc -O -sdk "$SDK" -target "$ARCH-apple-macos12.0" -module-cache-path "$CACHE" "$ROOT/Sources/SharedSources.swift" "$BUILD/indexer-src/main.swift" -o "$BUILD/Indexer-$ARCH"
done
xcrun lipo -create "$BUILD/Search-arm64" "$BUILD/Search-x86_64" -output "$APP/Contents/MacOS/ShareSearch"
xcrun lipo -create "$BUILD/Indexer-arm64" "$BUILD/Indexer-x86_64" -output "$APP/Contents/Resources/Indexer"
codesign --force --deep --sign - "$APP"
echo "已构建：$APP"
