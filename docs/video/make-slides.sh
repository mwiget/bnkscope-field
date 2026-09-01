#!/usr/bin/env bash
# Render the video's slides from the F5 corporate template, on lake1.
#
# The work happens there because the toolchain does not exist on the Mac:
# LibreOffice and poppler are what turn a .pptx into pixels, and neither is
# worth installing locally for two slides.
#
# The template is NOT vendored in this repo. It is an internal F5 asset, and
# this repo is public. It is read from --template, which defaults to a sibling
# checkout, and everything it produces lands in build/, which is git-ignored.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOST="${HOST:-lake1}"
TEMPLATE="${TEMPLATE:-$HERE/../../../why-ctl-tools/templates/F5-Corporate-Deck-Core-FY26-Q4.pptx}"
OUT="$HERE/build/slides"

[ -f "$TEMPLATE" ] || { echo "no template at $TEMPLATE" >&2; exit 1; }

remote=/tmp/bnkscope-field-slides
ssh "$HOST" "mkdir -p $remote/out"
rsync -q "$TEMPLATE" "$HOST:$remote/template.pptx"
rsync -q "$HERE/tools/make-slides.py" "$HOST:$remote/"
ssh "$HOST" "cd $remote && uv run --quiet --with python-pptx python make-slides.py \
    --template $remote/template.pptx --out $remote/out"
# Slides that already exist, lifted from the decks this lab's own video was
# built from. Reusing them rather than redrawing is the point: they are the
# same claims, already reviewed, already published in that cut — and the two
# chosen here are exactly the context this demo assumes. "lab" says what the
# three clusters are; "tmmpod" names the containers the Terminal beats enter.
#
#      name    deck                        slide
DECK_SLIDES="
lab      docs/tmm-consumable-exec.pptx     10
tmmpod   docs/tmm-consumable-exec.pptx     17
"
ssh "$HOST" "bash -s" <<REMOTE
set -euo pipefail
cd ~/git/tmm-lb-nico
work=\$(mktemp -d)
printf '%s' '$DECK_SLIDES' | while read -r name deck page; do
    [ -z "\${name:-}" ] && continue
    tag=\$(basename "\$deck" .pptx)
    if [ ! -f "\$work/\$tag.pdf" ]; then
        soffice --headless --convert-to pdf --outdir "\$work" "\$deck" >/dev/null 2>&1
    fi
    pdftoppm -r 144 -png -f "\$page" -l "\$page" "\$work/\$tag.pdf" "\$work/\$name"
    mv "\$work/\$name"-*.png "$remote/out/\$name.png"
done
rm -rf "\$work"
REMOTE

mkdir -p "$OUT"
rsync -q "$HOST:$remote/out/*.png" "$OUT/"
# The template does not stay on a machine that did not have it.
ssh "$HOST" "rm -rf $remote"
echo "── slides in $OUT"
ls "$OUT"
