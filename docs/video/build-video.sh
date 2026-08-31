#!/usr/bin/env bash
# Assemble the takes and the narration into one video.
#
# Cut to the voice, not the other way round: every segment is trimmed to the
# length of the scene that plays over it, so the picture never runs out early or
# lingers after the sentence ends.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TAKES="$HERE/takes"
VO="$HERE/kit/build/vo/part1"
OUT="$HERE/build"
mkdir -p "$OUT/seg"

# scene | takes (one or two) — where two, the scene is split across them.
MANIFEST=(
  "scene01|beat1"
  "scene02|beat2a,beat2b"
  "scene03|beat3"
  "scene04|beat4"
  "scene05|beat5,beat5b"
  "scene06|beat6"
  "scene07|beat7"
  "scene08|beat8"
  "scene09|beat9"
)

dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }

# Where the app appears. The head of every take is the springboard while the
# harness launches, and it is bright; the app is near-black. Detecting the drop
# beats hard-coding an offset that is right for one take and wrong for the next.
entry() {
    local first
    first=$(ffmpeg -v info -i "$1" -vf "fps=1,signalstats,metadata=print" -f null - 2>&1 \
        | grep -o "YAVG=[0-9.]*" | cut -d= -f2 \
        | awk '{ if ($1 < 60 && !found) { print NR-1; found=1 } }')
    echo "${first:-6}"
}

for row in "${MANIFEST[@]}"; do
    scene="${row%%|*}"; takes="${row##*|}"
    want=$(dur "$VO/$scene.wav")
    IFS=',' read -ra parts <<< "$takes"
    share=$(python3 -c "print(f'{$want/${#parts[@]}:.2f}')")
    n=0
    for take in "${parts[@]}"; do
        start=$(python3 -c "print($(entry "$TAKES/$take.mp4") + 1.0)")
        available=$(python3 -c "print(max(0.0, $(dur "$TAKES/$take.mp4") - $start))")
        if python3 -c "import sys; sys.exit(0 if $available < $share - 0.3 else 1)"; then
            echo "  !! $take has only ${available}s after its head, $scene wants ${share}s" >&2
        fi
        # -ss AFTER -i: seeking before the input snaps to a keyframe, and -t then
        # measures from wherever it landed rather than from the frame asked for.
        # Segments came out anywhere from half to double their intended length.
        #
        # transpose=2 because simctl records the framebuffer in portrait however
        # the app is oriented; checked against a frame, since the other direction
        # is equally plausible and equally sideways.
        ffmpeg -v error -i "$TAKES/$take.mp4" -ss "$start" -t "$share" \
            -vf "transpose=2,scale=1440:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30" \
            -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -an \
            "$OUT/seg/${scene}_$n.mp4" -y
        got=$(dur "$OUT/seg/${scene}_$n.mp4")
        python3 -c "import sys; sys.exit(0 if abs($got - $share) < 0.35 else 1)" \
            || echo "  !! ${scene}_$n is ${got}s, wanted ${share}s" >&2
        n=$((n+1))
    done
    printf "  %s  %ss over %s\n" "$scene" "$want" "$takes"
done

: > "$OUT/segments.txt"
for row in "${MANIFEST[@]}"; do
    scene="${row%%|*}"
    for f in "$OUT/seg/${scene}"_*.mp4; do echo "file '$f'" >> "$OUT/segments.txt"; done
done
ffmpeg -v error -f concat -safe 0 -i "$OUT/segments.txt" -c copy "$OUT/video.mp4" -y

: > "$OUT/audio.txt"
for row in "${MANIFEST[@]}"; do echo "file '$VO/${row%%|*}.wav'" >> "$OUT/audio.txt"; done
ffmpeg -v error -f concat -safe 0 -i "$OUT/audio.txt" -c:a pcm_s16le "$OUT/audio.wav" -y

ffmpeg -v error -i "$OUT/video.mp4" -i "$OUT/audio.wav" \
    -c:v copy -c:a aac -b:a 192k -shortest "$OUT/bnkscope-field.mp4" -y

# Captions as a sidecar, so YouTube can toggle them rather than burning them in.
python3 - "$VO" "$OUT/bnkscope-field.srt" <<'PY'
import subprocess, sys, pathlib
vo, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
def stamp(t):
    h, rem = divmod(t, 3600); m, s = divmod(rem, 60)
    return f"{int(h):02}:{int(m):02}:{int(s):02},{int((s%1)*1000):03}"
t, lines = 0.0, []
for i, wav in enumerate(sorted(vo.glob("scene*.wav")), 1):
    d = float(subprocess.run(["ffprobe","-v","error","-show_entries","format=duration",
                              "-of","csv=p=0",str(wav)], capture_output=True, text=True).stdout)
    text = (wav.parent.parent.parent.parent / "narration" / "part1" / f"{wav.stem}.txt")
    body = text.read_text().strip() if text.exists() else ""
    lines.append(f"{i}\n{stamp(t)} --> {stamp(t+d)}\n{body}\n")
    t += d
out.write_text("\n".join(lines))
print(f"  captions: {out}")
PY

echo "── $(dur "$OUT/bnkscope-field.mp4")s  $(ls -lh "$OUT/bnkscope-field.mp4" | awk '{print $5}')"
