#!/bin/bash
# Layout audit: opens every page of a debug build at several window sizes, in light
# and dark, records what LayoutAudit finds and screenshots each page.
#   scripts/ui-audit.sh [out-folder]     (default build/ui-audit)
# The window stays behind everything else and never takes focus, so the Mac stays
# usable while it runs. Needs Screen Recording permission for the screenshots.
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-build/ui-audit}
sizes=${SIZES:-"900x620 1180x720 1440x900 1920x1200"}
appearances=${APPEARANCES:-"light dark"}
rm -rf "$out" && mkdir -p "$out"
[[ -x build/window-id ]] || swiftc -O scripts/window-id.swift -o build/window-id
[[ -d build/Wisp.app ]] || scripts/build-app.sh --debug
app="$PWD/build/Wisp.app"
pkill -f "$app/Contents/MacOS/Wisp" || true
for appearance in $appearances; do
  for size in $sizes; do
    run="$out/$appearance-$size"
    mkdir -p "$run"
    open -g -n -a "$app" --env WISP_BACKGROUND=1 --env WISP_OPEN=window --env WISP_SIZE="$size" \
      --env WISP_APPEARANCE="$appearance" --env WISP_AUDIT="$PWD/$run"
    last=""
    for _ in $(seq 1 600); do
      now=$(cat "$run/now" 2>/dev/null || true)
      [[ "$now" == "done" ]] && break
      if [[ -n "$now" && "$now" != "$last" ]]; then
        id=$(build/window-id Wisp || true)
        [[ -n "$id" ]] && screencapture -x -o -l "$id" "$run/$now.png"
        last=$now
      fi
      sleep 0.2
    done
    sleep 1
  done
done
cat "$out"/*/report.tsv > "$out/report.tsv" 2>/dev/null || true
echo "issues: $(wc -l < "$out/report.tsv" | tr -d ' ')  (report: $out/report.tsv)"
cut -f4 "$out/report.tsv" | sort | uniq -c | sort -rn
