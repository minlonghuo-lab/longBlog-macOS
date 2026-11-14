#!/bin/bash
# Native WebKit integration harness; not distributed in the main app or DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="$(xcrun --sdk macosx --show-sdk-path)"
APP="$PWD/build/ReaderSmoke.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp -R build/longBlog.app/Contents/Resources "$APP/Contents/Resources"
cp build/longBlog.app/Contents/Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$SDK" \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/LongBlog/Reader/ReaderView.swift Sources/LongBlog/Reader/ReaderResources.swift tests/ReaderSmoke.swift \
  -framework Foundation -framework SwiftUI -framework AppKit -framework WebKit \
  -o "$APP/Contents/MacOS/longBlog"
codesign --force --sign - --timestamp=none "$APP"
"$APP/Contents/MacOS/longBlog" --screenshot "$PWD/build/smoke-reader.png"
