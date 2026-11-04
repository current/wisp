#!/bin/bash
# Points the Homebrew cask at a release: writes its version and the zip's SHA-256.
# usage: scripts/update-cask.sh 0.3.0   (after build/release/Wisp-0.3.0.zip is uploaded)
# The tap checkout defaults to ../homebrew-tap; set TAP to use another path.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/update-cask.sh VERSION}"
zip="build/release/Wisp-$version.zip"
tap="${TAP:-../homebrew-tap}"
cask="$tap/Casks/wisp.rb"
[[ -f "$zip" ]] || { echo "no $zip" >&2; exit 1; }
[[ -f "$cask" ]] || { echo "no $cask" >&2; exit 1; }
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
remote=$(curl -fsSL "https://github.com/current/wisp/releases/download/v$version/Wisp-$version.zip" | shasum -a 256 | cut -d' ' -f1)
[[ "$sha" == "$remote" ]] || { echo "the uploaded zip differs from $zip" >&2; exit 1; }
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
brew style "$cask"
git -C "$tap" diff --stat
echo "Commit and push $tap, then: brew update && brew upgrade --cask wisp"
