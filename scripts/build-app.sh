#!/bin/bash
# Builds Wisp.app into build/. Pass --debug for a quick single-arch debug build.
set -euo pipefail
cd "$(dirname "$0")/.."

config=release
archs=(--arch arm64 --arch x86_64)
if [[ "${1:-}" == "--debug" ]]; then
    config=debug
    archs=()
fi

version=$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/WispCore/Version.swift)
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)

swift build -c "$config" ${archs[@]+"${archs[@]}"} --product WispApp
swift build -c "$config" ${archs[@]+"${archs[@]}"} --product wisp
bin=$(swift build -c "$config" ${archs[@]+"${archs[@]}"} --show-bin-path)

app=build/Wisp.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/WispApp" "$app/Contents/MacOS/Wisp"
cp "$bin/wisp" "$app/Contents/Helpers/wisp"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" Resources/Info.plist > "$app/Contents/Info.plist"
if [[ -f Resources/Wisp.icns ]]; then
    cp Resources/Wisp.icns "$app/Contents/Resources/Wisp.icns"
fi

codesign --force --options runtime --sign - "$app/Contents/Helpers/wisp"
codesign --force --options runtime --sign - "$app"
echo "$app"
