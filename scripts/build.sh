#!/bin/bash
# Build from a clean object directory; no Xcode project generator or dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/longBlog.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_MACOS=14.0
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
BRIDGE="$ROOT/Sources/LongBlog/Core/LongBlog-Bridging-Header.h"
# Delete only this script's disposable build products, never user documents.
rm -rf "$BUILD/obj" "$APP" "$BUILD/dmg-root"
mkdir -p "$BUILD/obj" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(rg --files Sources/LongBlog -g '*.swift' | sort)
OBJC=()
while IFS= read -r f; do OBJC+=("$f"); done < <(rg --files Sources/LongBlog -g '*.m' | sort)
if [[ ${#SOURCES[@]} -eq 0 || ${#OBJC[@]} -eq 0 ]]; then echo 'Missing application sources' >&2; exit 1; fi
for ARCH in arm64 x86_64; do
  mkdir -p "$BUILD/obj/$ARCH"
  OBJECTS=()
  for SOURCE in "${OBJC[@]}"; do
    OBJECT="$BUILD/obj/$ARCH/$(basename "$SOURCE").o"
    xcrun clang -arch "$ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_MACOS" \
      -fobjc-arc -fmodules -Wall -Wextra -Werror=return-type -Werror=implicit-function-declaration \
      -I "$ROOT/Sources/LongBlog/Core" -c "$SOURCE" -o "$OBJECT"
    test -s "$OBJECT"
    OBJECTS+=("$OBJECT")
  done
  xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN_MACOS" \
    -import-objc-header "$BRIDGE" -I "$ROOT/Sources/LongBlog/Core" \
    "${SOURCES[@]}" "${OBJECTS[@]}" \
    -framework SwiftUI -framework AppKit -framework Foundation -framework Security \
    -framework WebKit -framework UniformTypeIdentifiers -framework UserNotifications \
    -o "$BUILD/obj/$ARCH/longBlog"
done
xcrun lipo -create "$BUILD/obj/arm64/longBlog" "$BUILD/obj/x86_64/longBlog" -output "$APP/Contents/MacOS/longBlog"
xcrun lipo -verify_arch arm64 x86_64 "$APP/Contents/MacOS/longBlog"
cp -R Resources/. "$APP/Contents/Resources/"
python3 scripts/make_plist.py "$APP/Contents/Info.plist" "$VERSION" "$BUILD_NUMBER"
if [[ -f Resources/AppIcon1024.png ]]; then
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" Resources/AppIcon1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" Resources/AppIcon1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
python3 scripts/check_bundle.py "$APP"
if [[ -f tests/CoreFixtures.m ]]; then
  NATIVE_ARCH="$(uname -m)"
  FIXTURE_OBJECTS=()
  for OBJECT in "$BUILD/obj/$NATIVE_ARCH/"*.o; do FIXTURE_OBJECTS+=("$OBJECT"); done
  xcrun clang -arch "$NATIVE_ARCH" -isysroot "$SDK" -mmacosx-version-min="$MIN_MACOS" \
    -fobjc-arc -fmodules -I Sources/LongBlog/Core tests/CoreFixtures.m "${FIXTURE_OBJECTS[@]}" \
    -framework AppKit -framework Foundation -framework Security -framework UserNotifications -framework UniformTypeIdentifiers \
    -o "$BUILD/CoreFixtures"
  "$BUILD/CoreFixtures"
fi
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$SDK" Sources/LongBlog/AI/AIWritingService.swift \
  tests/AIEndpointFixtures.swift -o "$BUILD/AIEndpointFixtures"
"$BUILD/AIEndpointFixtures"
mkdir -p "$BUILD/dmg-root"
cp -R "$APP" "$BUILD/dmg-root/longBlog.app"
ln -s /Applications "$BUILD/dmg-root/Applications"
cp docs/INSTALL.md "$BUILD/dmg-root/READ-ME-FIRST.txt"
DMG="$BUILD/longBlog-$VERSION-universal.dmg"
hdiutil create -volname 'longBlog' -srcfolder "$BUILD/dmg-root" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
(cd "$BUILD" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
echo "Built: $DMG"
