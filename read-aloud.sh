#!/bin/bash
# read-aloud.sh
# Reads selected text aloud using Piper TTS.
#
# XFCE hotkeys do NOT source ~/.bashrc. If piper is in a venv, set the
# hotkey command to: bash -lc "~/.local/bin/read-aloud.sh"
#
# How it works:
#   1. Tries to read the current mouse selection (PRIMARY) using multiple
#      X11 target formats (UTF8_STRING, text/plain, STRING, TEXT).
#   2. If PRIMARY is empty and we are NOT running from a terminal,
#      it sends Ctrl+C via xdotool to copy the selection, then reads
#      the CLIPBOARD. This handles PDF viewers and apps that do not
#      reliably set the PRIMARY selection.
#   3. If nothing is selected, it notifies you.
#
# Known limitations:
#   - Some web apps (Amazon Kindle Cloud Reader, some canvas-based readers)
#     override standard text selection and do not expose text to X11.
#     In those cases, select + Ctrl+C manually, then run the script.
#   - When run from a terminal, the xdotool Ctrl+C fallback is skipped
#     because the terminal would receive the keystroke and interrupt.
#     Use the XFCE hotkey for full functionality.
#
# Bind in XFCE: Settings > Keyboard > Application Shortcuts
# Recommended hotkey: Ctrl+Alt+R

set -euo pipefail

# ------------------- Configuration -------------------
# If piper is not in your PATH when XFCE runs the hotkey, hardcode it:
# PIPER_BIN="/home/yourname/.local/lib/piper-tts/.venv/bin/piper"
PIPER_BIN="${PIPER_BIN:-piper}"

PIPER_VOICE="${PIPER_VOICE:-$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx}"

# PulseAudio raw PCM playback command
PLAY_CMD="paplay --raw --rate=22050 --channels=1 --format=s16le"

# ------------------- Functions -------------------

get_primary_selection() {
  local text=""
  if command -v xclip &>/dev/null; then
    # Try multiple X11 target formats. Different apps expose selection
    # under different target names.
    text="$(xclip -o -selection primary -t UTF8_STRING 2>/dev/null || true)"
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t text/plain 2>/dev/null || true)"
    fi
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t STRING 2>/dev/null || true)"
    fi
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t TEXT 2>/dev/null || true)"
    fi
  fi
  echo "$text"
}

get_clipboard() {
  local text=""
  if command -v xclip &>/dev/null; then
    text="$(xclip -o -selection clipboard -t UTF8_STRING 2>/dev/null || xclip -o -selection clipboard 2>/dev/null || true)"
  fi
  echo "$text"
}

speak_text() {
  local text="$1"

  # Stop any currently playing speech
  pkill -f "piper" 2>/dev/null || true
  pkill -f "paplay" 2>/dev/null || true
  sleep 0.1

  local preview="${text:0:60}"
  [[ ${#text} -gt 60 ]] && preview="${preview}..."
  notify-send -t 2500 -u low "Reading aloud" "$preview"

  # Synchronous pipeline: more reliable inside hotkey scripts
  printf "%s" "$text" | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw | eval "$PLAY_CMD"
}

# ------------------- Main -------------------

text=""
source_name="none"

# 1. Try PRIMARY selection (mouse highlight)
text="$(get_primary_selection)"
if [[ -n "$text" ]]; then
  source_name="primary"
fi

# 2. If PRIMARY was empty, try auto-copy via xdotool + CLIPBOARD fallback.
#    We skip this when running from a terminal (stdin is a tty) because
#    xdotool would send Ctrl+C to the terminal itself, interrupting us.
if [[ -z "$text" ]] && command -v xdotool &>/dev/null && [[ ! -t 0 ]]; then
  # Brief pause to ensure the hotkey modifiers (Ctrl, Alt) are fully released
  # before xdotool injects its own keystrokes.
  sleep 0.2
  xdotool key --clearmodifiers ctrl+c
  sleep 0.4

  text="$(get_clipboard)"
  if [[ -n "$text" ]]; then
    source_name="clipboard-auto"
  fi
fi

# Normalize whitespace
text="$(echo "$text" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"

if [[ -z "$text" ]]; then
  notify-send -t 4000 -u normal \
    "Read Aloud" \
    "No text found.\nSelect text and press the hotkey, or copy with Ctrl+C first."
  exit 0
fi

# Let the user know which source was used
if [[ "$source_name" == "clipboard-auto" ]]; then
  notify-send -t 1500 -u low \
    "Read Aloud" \
    "Used Ctrl+C fallback.\nYour clipboard was overwritten."
fi

speak_text "$text"
