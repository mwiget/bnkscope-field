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

# What the app should already hold when a take starts. No argument means the
# empty app, which is where the import beat begins; "seed" means the three
# clusters that beat imports, so every later beat starts from the same place
# regardless of what ran before it.
#
# The seed is captured from a real import rather than written by hand: the app
# splits a multi-context file into one kubeconfig per context and names them
# itself, and a hand-made set would drift from whatever it does next.
SEED_DIR="$HERE/build/seed"
# The app must actually be gone before the files change under it: it reads the
# directory once, at launch. A take that staged three clusters into a process
# that was already up filmed an empty app and looked like a staging bug.
quit_app() {
    osascript -e 'tell application "bnkscope Field" to quit' >/dev/null 2>&1 || true
    local waited=0
    while pgrep -x "bnkscope Field" >/dev/null && [ $waited -lt 10 ]; do
        sleep 1; waited=$((waited + 1))
    done
    pgrep -x "bnkscope Field" >/dev/null && pkill -x "bnkscope Field" >/dev/null 2>&1 || true
    sleep 1
}

stage() {
    quit_app
    rm -rf "$LIVE"; mkdir -p "$LIVE"
    if [ "${1:-}" = seed ]; then
        cp "$SEED_DIR"/*.kubeconfig "$LIVE/" 2>/dev/null || {
            echo "   no seed yet — run beat2Import first"; return 1
        }
    fi
    echo "   staged $(ls -1 "$LIVE" 2>/dev/null | wc -l | tr -d ' ') kubeconfigs"
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

# Privacy masks, in the 1920x1080 frame every take is normalised to.
#
# The macOS open panel lists the operator's home directory, and on a working
# machine that means customer and project names. Those rows are blurred; the
# generic system folders and the file actually being imported stay readable, so
# the panel still reads as a file browser rather than as a redaction.
#
# The mask is bounded in time because the rectangle is only a file list while
# the panel is up — once it closes the same region is the cluster list, and
# blurring that would be damage rather than privacy.
#
# The window deliberately ENDS LATE, after the panel has gone. The two failure
# modes are not equal: ending late blurs a second of cluster list that the cut
# is then set to skip, while ending early exposes every filename in the panel
# for as long as it takes to close. An earlier window ended at 23.5 and the
# panel was still up at 23.6, with every name legible. So the end is generous
# and build-video.sh starts the following segment after it.
mask_for() {
    case "$1" in
    beat2Import)
        cat <<'MASK'
split=5[b][r1][r2][r3][r4];[r1]crop=417:60:608:309,avgblur=14[m1];[r2]crop=417:151:608:400,avgblur=14[m2];[r3]crop=417:59:608:583,avgblur=14[m3];[r4]crop=417:20:608:728,avgblur=8[m4];[b][m1]overlay=608:309:enable='between(t,12.6,26)'[o1];[o1][m2]overlay=608:400:enable='between(t,12.6,26)'[o2];[o2][m3]overlay=608:583:enable='between(t,12.6,26)'[o3];[o3][m4]overlay=608:728:enable='between(t,12.6,26)'[v]
MASK
        ;;
    esac
}

# One take. The recording is bounded by -V rather than stopped by hand: a
# screencapture killed mid-write leaves a file QuickTime cannot open.
#
# The display is filmed and then cropped to the window, rather than the window
# being filmed directly with -l<windowid>. -l is cleaner — it cannot pick up
# anything in front — but it captures only that one window, and a sheet is a
# child window: the file-open panel simply did not appear in the take. Cropping
# to the measured rectangle keeps the sheet and still excludes the desktop.
#
# Order matters: the app is staged, launched and measured before recording, so
# the crop rectangle is known before a frame is written.
take() {
    local name="$1" test="$2" seconds="$3"; shift 3
    stage "$@"
    set_window
    open -a "bnkscope Field"
    sleep 4
    local geom
    if ! geom="$("$HERE/build/windowid" "bnkscope Field" 2>/dev/null)"; then
        echo "   no window to film"; return 1
    fi
    set -- $geom
    local wid=$1 wx=$2 wy=$3 ww=$4 wh=$5
    echo "── $name (${seconds}s, window $wid at $wx,$wy ${ww}x${wh})"
    rm -f "$OUT/$name.mov" "$OUT/$name.mp4"
    # -k draws the clicks the driver makes, which is the only cue on screen that
    # anything is being operated rather than playing back.
    screencapture -v -k -C -x -D 1 -V "$seconds" "$OUT/$name.mov" &
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
    quit_app
    [ -s "$OUT/$name.mov" ] || { echo "   EMPTY TAKE"; return 1; }

    # Crop to the window, drop the title bar with its recording indicator, and
    # normalise to 1080p so every beat is the same size whatever the display was.
    local px=$((wx * 2)) py=$((wy * 2 + TITLEBAR)) pw=$((ww * 2)) ph=$((wh * 2 - TITLEBAR))
    local chain="crop=$pw:$ph:$px:$py,scale=1920:1080:flags=lanczos,fps=30"
    local mask; mask="$(mask_for "$name")"
    if [ -n "$mask" ]; then
        ffmpeg -nostdin -y -i "$OUT/$name.mov" \
            -filter_complex "[0:v]$chain,$mask" -map "[v]" \
            -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -an \
            "$OUT/$name.mp4" >/dev/null 2>&1
    else
        ffmpeg -nostdin -y -i "$OUT/$name.mov" -vf "$chain" \
            -c:v libx264 -preset slow -crf 18 -pix_fmt yuv420p -an \
            "$OUT/$name.mp4" >/dev/null 2>&1
    fi
    rm -f "$OUT/$name.mov"
    echo "   $(du -h "$OUT/$name.mp4" | cut -f1) $(ffprobe -v error -show_entries stream=width,height,duration -of csv=p=0 "$OUT/$name.mp4" 2>/dev/null)"
}

save_once
[ "${SKIP_BUILD:-0}" = 1 ] || build

# name | test | seconds | staged state. Seconds is the beat's own dwell plus the
# launch and settle at the head, which assembly trims off.
sequence() {
    cat <<'SEQ'
beat1Empty|beat1Empty|22|
beat2Import|beat2Import|50|
beat3Clusters|beat3Clusters|32|seed
beat4Explore|beat4Explore|46|seed
beat5TMMLive|beat5TMMLive|100|seed
beat6TerminalDebug|beat6TerminalDebug|44|seed
beat7TerminalRouting|beat7TerminalRouting|46|seed
beat8Logs|beat8Logs|38|seed
beat9Close|beat9Close|18|seed
SEQ
}

if [ $# -gt 0 ]; then
    # A named beat, re-shot on its own: ./record-macos.sh beat4Explore 46 seed
    take "$1" "$1" "${2:-30}" ${3:+"$3"}
    exit 0
fi

while IFS='|' read -r name test seconds state; do
    [ -z "${name:-}" ] && continue
    take "$name" "$test" "$seconds" ${state:+"$state"} || true
done <<< "$(sequence)"
echo "── all takes in $OUT"
