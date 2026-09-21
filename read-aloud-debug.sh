#!/bin/bash
# read-aloud-debug.sh
# Debug version of read-aloud.sh that logs every step to /tmp/read-aloud-debug.log
# Run this from a terminal (not via hotkey) to see live output:
#   bash read-aloud-debug.sh

set -euo pipefail
set -x
exec 2> /tmp/read-aloud-debug.log

# ------------------- Configuration -------------------
PIPER_BIN="${PIPER_BIN:-piper}"
PIPER_VOICE="${PIPER_VOICE:-$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx}"
PLAY_CMD="paplay"

# ------------------- Main -------------------

text=""

if command -v xclip &>/dev/null; then
  text="$(xclip -o -selection primary 2>/dev/null || true)"
  if [[ -z "$text" ]]; then
    text="$(xclip -o -selection clipboard 2>/dev/null || true)"
  fi
fi

text="$(echo "$text" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"

if [[ -z "$text" ]]; then
  notify-send -t 2000 -u normal "Read Aloud" "No text selected or in clipboard."
  exit 0
fi

echo "TEXT=$text"
echo "WHICH_PIPER=$(which "$PIPER_BIN" || echo NOTFOUND)"
echo "VOICE_EXISTS=$(test -f "$PIPER_VOICE" && echo YES || echo NO)"

pkill -f "piper" 2>/dev/null || true
pkill -f "paplay" 2>/dev/null || true
sleep 0.1

printf "%s" "$text" | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw |   "$PLAY_CMD" --raw --rate=22050 --channels=1 --format=s16le
