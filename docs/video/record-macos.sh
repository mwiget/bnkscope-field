#!/usr/bin/env bash
# Record one take per beat, driving the real Mac app with XCUITest.
#
# The iPad pipeline (record.sh, on the simulator) cannot be reused directly:
# simctl owns the simulator's framebuffer and its app container, and the Mac has
# neither. What replaces them:
#
#   picture   `screencapture -v`, which records the display non-interactively and
#             with -k draws the clicks — without that an automated demo is a
#             cursor teleporting between controls with nothing to show why.
#   staging   the Mac app is not sandboxed: its kubeconfigs live in the real
#             ~/Library/Application Support/kubeconfigs. A take that stages state
#             is editing the operator's own cluster list, so the directory is
#             saved once up front and restored on any exit, including a kill.
#
# The test host must be signed. An unsigned arm64 binary does not launch at all
# ("the application is damaged"), and an ad-hoc signed one launches but is
# refused the local network, which would film three unreachable clusters.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$HERE/../../App" && pwd)"
OUT="${OUT:-$HERE/takes}"
DD="${DD:-$HERE/build/dd}"
IDENTITY="${IDENTITY:-Developer ID Application: Marcel Wiget (HGECWA98QL)}"
BUNDLE=com.mwiget.bnkscope.field
LIVE="$HOME/Library/Application Support/kubeconfigs"
SAVED="$HERE/build/kubeconfigs-live"
# Where the takes' own kubeconfigs come from. Defaults to the file the demo
# imports, so a fresh clone needs no arguments.
SEED="${SEED:-$HOME/config-multi.txt}"

mkdir -p "$OUT" "$HERE/build"

# ── the operator's own state ───────────────────────────────────────────────
# Saved before the first take and put back whatever happens: a demo that eats
# the cluster list it was demonstrating is not a demo.
restore() {
    if [ -d "$SAVED" ]; then
        rm -rf "$LIVE"
        mv "$SAVED" "$LIVE"
        echo "── restored your kubeconfigs"
    fi
}
trap restore EXIT INT TERM

save_once() {
    [ -d "$SAVED" ] && return 0
    if [ -d "$LIVE" ]; then cp -a "$LIVE" "$SAVED"; else mkdir -p "$SAVED"; fi
    echo "── saved your kubeconfigs ($(ls -1 "$SAVED" 2>/dev/null | wc -l | tr -d ' ') files)"
}

# What the app should already hold when a take starts. No arguments means the
# empty app, which is where the import beat begins.
stage() {
    osascript -e 'tell application "bnkscope Field" to quit' >/dev/null 2>&1 || true
    sleep 1
    rm -rf "$LIVE"; mkdir -p "$LIVE"
    for f in "$@"; do cp "$SAVED/$f" "$LIVE/" 2>/dev/null || true; done
}

build() {
    echo "── building and signing the test host"
    xcodebuild build-for-testing -project "$PROJ/BNKScopeField.xcodeproj" \
        -scheme BNKScopeField -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath "$DD" \
        CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual \
        OTHER_CODE_SIGN_FLAGS="--timestamp=none" >/dev/null
    local app="$DD/Build/Products/Debug/bnkscope Field.app"
    codesign --verify --strict "$app"
    echo "   $(codesign -dvv "$app" 2>&1 | grep '^Authority' | head -1)"
}

# The app's window geometry, so every take is the same size and scales to 1080p
# without letterboxing. Size is honoured exactly; position is not — macOS
# cascades the window wherever it likes — which is why takes are filmed by
# window id rather than by a screen rectangle.
# 765 points of content plus the 52-point title bar, so that cropping the title
# bar away leaves exactly 1360x765 — 2720x1530 on this display, which is 16:9 and
# scales to 1080p without letterboxing. The title bar has to go: macOS draws its
# screen-recording indicator over it, in every frame of every take, and no
# setting turns that off.
# 765 points is as tall as this display will allow the window to be, so the
# width is chosen to suit it rather than the other way round: 1530 captured
# pixels minus the 104-pixel title bar leaves 1426, and 1426 x 16/9 is 2536 —
# 1268 points. The result crops to exactly 16:9 and scales to 1080p with no
# letterboxing.
WIN_W="${WIN_W:-1268}"
WIN_H="${WIN_H:-765}"
TITLEBAR="${TITLEBAR:-104}"

frame_key() {
    defaults read "$BUNDLE" 2>/dev/null |
        grep -o '"NSWindow Frame SwiftUI[^"]*"' | head -1 | tr -d '"'
}

# Written while the app is down: it rewrites its own frame on quit, so a value
# set under a running app is discarded.
set_window() {
    local key; key="$(frame_key)"
    [ -z "$key" ] && return 0
    defaults write "$BUNDLE" "$key" "40 60 $WIN_W $WIN_H 0 0 1470 923 "
}

# One take. The recording is bounded by -V rather than stopped by hand: a
# screencapture killed mid-write leaves a file QuickTime cannot open.
#
# Order matters. The app is staged, launched and measured first, because
# -l<windowid> needs a window that already exists; only then does the driver
# attach to it and start clicking.
take() {
    local name="$1" test="$2" seconds="$3"; shift 3
    stage "$@"
    set_window
    open -a "bnkscope Field"
    sleep 4
    local wid
    if ! wid="$("$HERE/build/windowid" "bnkscope Field" 2>/dev/null)"; then
        echo "   no window to film"; return 1
    fi
    echo "── $name (${seconds}s, window $wid)"
    rm -f "$OUT/$name.mov"
    # -o drops the window shadow, which is transparent padding the crop would
    # otherwise have to remove; -k draws the clicks the driver makes.
    screencapture -v -k -C -x -o -V "$seconds" -l"$wid" "$OUT/$name.mov" &
    local rec=$!
    sleep 1
    # test-without-building: a full `test` spends most of a minute re-checking
    # the build first, and every second of it would be desktop in the take.
    xcodebuild test-without-building -project "$PROJ/BNKScopeField.xcodeproj" \
        -scheme BNKScopeField -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DD" \
        -only-testing:"BNKScopeFieldUITests/DemoDrive/$test" >/dev/null 2>&1 &
    local job=$!
    local waited=0
    while kill -0 $job 2>/dev/null && [ $waited -lt $((seconds + 60)) ]; do
        sleep 3; waited=$((waited + 3))
    done
    kill -0 $job 2>/dev/null && { kill -TERM $job 2>/dev/null || true; }
    wait $rec 2>/dev/null || true
    osascript -e 'tell application "bnkscope Field" to quit' >/dev/null 2>&1 || true
    if [ -s "$OUT/$name.mov" ]; then
        echo "   $(du -h "$OUT/$name.mov" | cut -f1) $(ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$OUT/$name.mov" 2>/dev/null)"
    else
        echo "   EMPTY TAKE"
    fi
}

save_once
[ "${SKIP_BUILD:-0}" = 1 ] || build

if [ $# -gt 0 ]; then
    # A named beat, re-shot on its own: ./record-macos.sh beat4Logs 30
    take "$1" "$1" "${2:-30}"
    exit 0
fi

echo "record-macos.sh: pass a beat name and duration, e.g."
echo "  ./record-macos.sh beat9Close 20"
