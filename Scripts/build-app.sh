#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
swift build --disable-sandbox -c release
APP="build/课表.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build --disable-sandbox -c release --show-bin-path)/TimetableApp" "$APP/Contents/MacOS/TimetableApp"
ICONSET="build/Timetable.iconset"
mkdir -p "$ICONSET"
swift Scripts/generate-icon.swift "$ICONSET"
cp "${ICONSET%.iconset}.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TimetableApp</string>
<key>CFBundleIdentifier</key><string>local.timetable.native</string>
<key>CFBundleName</key><string>课表</string>
<key>CFBundleDisplayName</key><string>课表</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
printf '应用已生成：%s/%s\n' "$PWD" "$APP"
