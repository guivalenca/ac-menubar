#!/bin/zsh
# Renders the README screenshots into docs/screenshots from sample data (no device or network needed).
#   tools/screenshots.sh
set -euo pipefail

ROOT=${0:A:h:h}
SCRATCH="$HOME/Library/Caches/ac-menubar-build"
OUT="$ROOT/docs/screenshots"

cd "$ROOT"
swift build -c release --scratch-path "$SCRATCH" --product ac-menubar >/dev/null
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/ac-menubar"

mkdir -p "$OUT"
"$BIN" --snapshot "$OUT/ligado.png" --framed --scenario on
"$BIN" --snapshot "$OUT/ligado-escuro.png" --framed --dark --scenario on
"$BIN" --snapshot "$OUT/desligado.png" --framed --scenario off
"$BIN" --snapshot "$OUT/desligado-escuro.png" --framed --dark --scenario off
print "Screenshots em ${OUT/#$HOME/~}"
