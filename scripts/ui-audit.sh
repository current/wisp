#!/bin/bash
# Layout audit: opens every page of a debug build at several window sizes, in light
# and dark, records what LayoutAudit finds and screenshots each page, then draws every
# menu bar dropdown. The pictures are what docs/ui-rubric.md scores.
#   APP=path/to/Wisp.app scripts/ui-audit.sh [out-folder]     (default build/ui-audit)
# The window is kept off the screen and never takes focus, so the Mac stays usable
# while it runs. Wisp draws each page into a PNG itself (Liquid Glass surfaces
# are drawn by the window server and do not show up in those pictures).
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-build/ui-audit}
[[ "$out" == /* ]] || out="$PWD/$out"
sizes=${SIZES:-"900x620 1180x720 1440x900 1920x1200"}
appearances=${APPEARANCES:-"light dark"}
rm -rf "$out" && mkdir -p "$out"
# APP picks the build to audit. Each run quits itself; nothing is killed by name, so a
# copy of Wisp you are using from the same path keeps running.
app=${APP:-$PWD/build/Wisp.app}
[[ -d "$app" ]] || scripts/build-app.sh --debug
for appearance in $appearances; do
  for size in $sizes; do
    run="$out/$appearance-$size"
    mkdir -p "$run"
    open -g -n -a "$app" --env WISP_NO_SAVE=1 --env WISP_BACKGROUND=1 --env WISP_NO_MOTION=1 --env WISP_OPEN=window --env WISP_SIZE="$size" \
      --env WISP_APPEARANCE="$appearance" --env WISP_AUDIT="$run"
    for _ in $(seq 1 600); do
      [[ "$(cat "$run/now" 2>/dev/null)" == "done" ]] && break
      sleep 0.5
    done
    sleep 1
  done
done
# Every menu bar dropdown and the dashboard, drawn the same way (DROPDOWNS=0 skips them).
if [[ "${DROPDOWNS:-1}" != 0 ]]; then
  for appearance in $appearances; do
    mkdir -p "$out/dropdowns-$appearance"
    for focus in dashboard cpu memory network gpu temperature battery disk usage; do
      open -g -n -W -a "$app" --env WISP_NO_SAVE=1 --env WISP_BACKGROUND=1 --env WISP_NO_MOTION=1 --env WISP_APPEARANCE="$appearance" \
        --env WISP_POPOVER_SNAPSHOT="$out/dropdowns-$appearance/$focus.png" --env WISP_SNAPSHOT_DELAY=8 \
        --env WISP_POPOVER_FOCUS="$focus"
    done
  done
fi
cat "$out"/*/report.tsv > "$out/report.tsv" 2>/dev/null || true
echo "issues: $(wc -l < "$out/report.tsv" | tr -d ' ')  (report: $out/report.tsv)"
cut -f4 "$out/report.tsv" | sort | uniq -c | sort -rn
