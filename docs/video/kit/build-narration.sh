#!/usr/bin/env bash
# Generate the narration in Marcel's voice.
#
# The synthesiser, the cue map and the reference recording all live in the
# tmm-lb-nico kit; only the scene texts are ours. Rather than copy a voice
# recording into a second repository, this borrows the tooling in place and
# links the voice directory.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC_KIT="${SRC_KIT:-$HOME/git/tmm-lb-nico/docs/video/kit}"
VENV="${VENV:-$HOME/.venvs/f5tts}"

[ -d "$SRC_KIT" ] || { echo "no kit at $SRC_KIT — set SRC_KIT"; exit 1; }
cp -f "$SRC_KIT/gen-narration.py" "$HERE/gen-narration.py"
[ -e "$HERE/voice" ] || ln -s "$SRC_KIT/voice" "$HERE/voice"

"$VENV/bin/python" "$HERE/gen-narration.py" --part 1 "$@"
