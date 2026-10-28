#!/bin/bash
# Build MacProton.app from the Swift package.
#
# usage: macos/app/build-app.sh [OUT_DIR] [RUNTIME_DIST]
#
# OUT_DIR defaults to macos/app/.build/app. With RUNTIME_DIST (the dist
# directory from macos/build.sh) the Proton runtime is bundled into
# Contents/Resources/runtime; without it, the app looks for the runtime in
# ~/Library/Application Support/MacProton/runtime or the path set in its
# settings.

set -euo pipefail

src=$(cd "$(dirname "$0")" && pwd)
out=${1:-$src/.build/app}
runtime=${2:-}
app=$out/MacProton.app
version=$(git -C "$src" describe --always --dirty 2>/dev/null || echo dev)
# Release builds are tagged vX.Y.Z
short_version=$(git -C "$src" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)
short_version=${short_version:-0.1.0}

swift build --package-path "$src" -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build --package-path "$src" -c release --show-bin-path)/MacProton" "$app/Contents/MacOS/"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacProton</string>
    <key>CFBundleIdentifier</key><string>org.macproton.MacProton</string>
    <key>CFBundleName</key><string>MacProton</string>
    <key>CFBundleDisplayName</key><string>MacProton</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$short_version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

if [ -n "$runtime" ]; then
    rsync -a --delete "$runtime/" "$app/Contents/Resources/runtime/"
fi

# Ad-hoc signature; distribution builds need a Developer ID and notarization
codesign --force --deep --sign - "$app"
echo "$app"
