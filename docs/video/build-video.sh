#!/usr/bin/env bash
# Assemble the takes and the narration into one cut.
#
# Every visual segment is timed to its narration line, never the other way
# round: the voice is the clock. A take is recorded with slack at both ends —
# the app launching, the screen settling — and this trims the head, then fits
# what is left to the length of the line that plays over it.
#
# Fitting is a cut, not a speed change. Stretching a screen recording to fill
# time makes the cursor drift unnaturally; cutting simply shows less of a mostly
# static screen. Where a take is SHORTER than its line, the last frame is held,
# which reads as the presenter pausing on the result — the pacing rule the iPad
# kit arrived at the hard way.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TAKES="$HERE/takes"
VO="$HERE/build/vo"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OUT="${OUT:-$HERE/build/bnkscope-field-macos.mp4}"
FONT="${FONT:-/System/Library/Fonts/SFNSDisplay.ttf}"
[ -f "$FONT" ] || FONT=/System/Library/Fonts/Helvetica.ttc

# Seconds of silence before the first line, so the title card is on screen for a
# beat before the voice starts, and after each line so topics do not run
# together. The iPad kit shipped to feedback that zero gap was too fast.
LEAD="${LEAD:-1.2}"
GAP="${GAP:-0.9}"

wav_len() { python3 -c "import wave;w=wave.open('$1');print(round(w.getnframes()/w.getframerate(),3))"; }

# kind|source|scene|head — head is seconds trimmed off the front of a take,
# where the app is launching or the screen has not settled yet.
sequence() {
    cat <<'SEQ'
slide|title|scene01|
video|beat1Empty|scene01b|3
video|beat2Import|scene02|6
video|beat3Clusters|scene03|5
video|beat4Explore|scene04|4
video|beat4Explore|scene05|26
video|beat5TMMLive|scene06|5
video|beat5TMMLive|scene07|62
video|beat6TerminalDebug|scene08|5
video|beat7TerminalRouting|scene09|6
video|beat8Logs|scene10|4
video|beat9Close|scene11|3
slide|close|scene11b|
SEQ
}

# A card: the app's own background and type, so it does not look like a
# different product's title sequence. Rendered by tools/card.swift rather than
# ffmpeg — Homebrew builds ffmpeg without libfreetype, so drawtext is absent.
make_card() {
    local text="$1" sub="$2" seconds="$3" out="$4"
    local png="$WORK/card$$.png"
    "$HERE/build/card" "$png" "$text" "$sub"
    ffmpeg -nostdin -y -loop 1 -i "$png" -t "$seconds" -r 30 \
        -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p "$out" >/dev/null 2>&1
    rm -f "$png"
}

# A slide rendered from the F5 corporate template by make-slides.sh. Preferred
# over a card: it carries F5's logo, type and colour bar, so the video opens the
# way an F5 deck does rather than in a typeface of my choosing.
make_slide() {
    local name="$1" seconds="$2" out="$3"
    local png="$HERE/build/slides/$name.png"
    [ -f "$png" ] || { echo "missing slide: $name — run ./make-slides.sh" >&2; return 1; }
    ffmpeg -nostdin -y -loop 1 -i "$png" -t "$seconds" -r 30 \
        -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p "$out" >/dev/null 2>&1
}

# One visual segment, cut to exactly `target` seconds.
make_video() {
    local take="$1" head="$2" target="$3" out="$4"
    local src="$TAKES/$take.mp4"
    [ -f "$src" ] || { echo "missing take: $take" >&2; return 1; }
    local have
    have=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src")
    local usable
    usable=$(python3 -c "print(max(0.5, $have - $head))")
    if python3 -c "exit(0 if $usable >= $target else 1)"; then
        ffmpeg -nostdin -y -ss "$head" -t "$target" -i "$src" \
            -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -an "$out" >/dev/null 2>&1
    else
        # Short: play what there is, then hold the last frame for the remainder.
        local pad
        pad=$(python3 -c "print(round($target - $usable, 3))")
        ffmpeg -nostdin -y -ss "$head" -i "$src" \
            -vf "tpad=stop_mode=clone:stop_duration=$pad" -t "$target" \
            -c:v libx264 -preset medium -crf 19 -pix_fmt yuv420p -an "$out" >/dev/null 2>&1
    fi
}

i=0
: > "$WORK/list.txt"
: > "$WORK/audio.txt"
first=1
while IFS='|' read -r kind source scene head; do
    [ -z "${kind:-}" ] && continue
    i=$((i + 1))
    seg=$(printf "%s/seg%02d.mp4" "$WORK" "$i")
    len=$(wav_len "$VO/$scene.wav")
    lead=0; [ $first = 1 ] && { lead=$LEAD; first=0; }
    target=$(python3 -c "print(round($len + $lead + $GAP, 3))")

    case "$kind" in
        card)  make_card "${source%%~*}" "${source#*~}" "$target" "$seg" ;;
        slide) make_slide "$source" "$target" "$seg" ;;
        video) make_video "$source" "${head:-0}" "$target" "$seg" ;;
    esac
    echo "file '$seg'" >> "$WORK/list.txt"

    # The audio for this segment: lead silence, the line, then gap silence, so
    # picture and voice stay locked without a global offset that could drift.
    #
    # A zero-length silence is left out rather than passed as -t 0: anullsrc is
    # an infinite source, and -t 0 does not bound it — ffmpeg sits there
    # generating silence until it is killed. Every beat after the first has no
    # lead, so this hung the build on segment two.
    apad_lead=""; amap="[1]"
    if python3 -c "exit(0 if $lead > 0 else 1)"; then
        apad_lead="-f lavfi -t $lead -i anullsrc=r=24000:cl=mono"
    fi
    # shellcheck disable=SC2086
    if [ -n "$apad_lead" ]; then
        ffmpeg -nostdin -y $apad_lead -i "$VO/$scene.wav" \
            -f lavfi -t "$GAP" -i anullsrc=r=24000:cl=mono \
            -filter_complex "[0][1][2]concat=n=3:v=0:a=1[a]" -map "[a]" \
            -c:a pcm_s16le "$WORK/a$i.wav" >/dev/null 2>&1
    else
        ffmpeg -nostdin -y -i "$VO/$scene.wav" \
            -f lavfi -t "$GAP" -i anullsrc=r=24000:cl=mono \
            -filter_complex "[0][1]concat=n=2:v=0:a=1[a]" -map "[a]" \
            -c:a pcm_s16le "$WORK/a$i.wav" >/dev/null 2>&1
    fi
    unset amap
    echo "file '$WORK/a$i.wav'" >> "$WORK/audio.txt"
    printf "  %-22s %-8s %6.2fs\n" "$source" "$scene" "$target"
done <<< "$(sequence)"

ffmpeg -nostdin -y -f concat -safe 0 -i "$WORK/list.txt" -c copy "$WORK/video.mp4" >/dev/null 2>&1
ffmpeg -nostdin -y -f concat -safe 0 -i "$WORK/audio.txt" -c copy "$WORK/audio.wav" >/dev/null 2>&1
mkdir -p "$(dirname "$OUT")"
ffmpeg -nostdin -y -i "$WORK/video.mp4" -i "$WORK/audio.wav" \
    -c:v copy -c:a aac -b:a 192k -shortest "$OUT" >/dev/null 2>&1
echo "── $OUT  $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" | cut -d. -f1)s"
