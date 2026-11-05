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

version=$(sed -n 's/.*version = "\(.*\)".*/\1/p' Sources/WispCore/Support/Wisp.swift)
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)

# SwiftPM records the deployment target as the SDK version, so macOS would treat Wisp as
# an app built for macOS 15 and draw it without Liquid Glass. Record the real SDK.
link=(-Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$(xcrun --show-sdk-version)")
swift build -c "$config" ${archs[@]+"${archs[@]}"} --product WispApp "${link[@]}"
swift build -c "$config" ${archs[@]+"${archs[@]}"} --product wisp "${link[@]}"
bin=$(swift build -c "$config" ${archs[@]+"${archs[@]}"} --show-bin-path "${link[@]}")

app=build/Wisp.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/WispApp" "$app/Contents/MacOS/Wisp"
cp "$bin/wisp" "$app/Contents/Helpers/wisp"
sed -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build_number/" Resources/Info.plist > "$app/Contents/Info.plist"
cp -R Resources/Fonts "$app/Contents/Resources/Fonts"
if [[ -f Resources/Wisp.icns ]]; then
    cp Resources/Wisp.icns "$app/Contents/Resources/Wisp.icns"
fi

codesign --force --options runtime --sign - "$app/Contents/Helpers/wisp"
codesign --force --options runtime --sign - "$app"
echo "$app"
