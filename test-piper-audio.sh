#!/bin/bash
# test-piper-audio.sh
# Tests Piper TTS and PulseAudio playback step by step.
# Run from terminal: bash test-piper-audio.sh

set -euo pipefail

PIPER_BIN="${PIPER_BIN:-piper}"
PIPER_VOICE="${PIPER_VOICE:-$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx}"

echo "=== 1. Check piper binary ==="
if ! command -v "$PIPER_BIN" &>/dev/null; then
    echo "FAIL: piper not found in PATH."
    echo "Try: export PATH=\"$HOME/.local/lib/piper-tts/.venv/bin:\$PATH\""
    exit 1
fi
echo "OK: $(which "$PIPER_BIN")"

echo ""
echo "=== 2. Check voice model file ==="
if [[ ! -f "$PIPER_VOICE" ]]; then
    echo "FAIL: voice model not found at $PIPER_VOICE"
    exit 1
fi
echo "OK: $PIPER_VOICE"

echo ""
echo "=== 3. Test paplay with a system WAV file ==="
if [[ -f /usr/share/sounds/freedesktop/stereo/message.oga ]]; then
    # Convert and play a system sound to verify PulseAudio works
    pacat --file-format=ogg /usr/share/sounds/freedesktop/stereo/message.oga 2>/dev/null ||     echo "(optional system sound test skipped)"
else
    echo "(no system sound to test, skipping)"
fi

echo ""
echo "=== 4. Test Piper -> paplay pipeline ==="
echo "You should hear: 'This is a test of the piper speech system.'"
echo ""

# Use a short sentence to keep it quick
echo "This is a test of the piper speech system." | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw |     paplay --raw --rate=22050 --channels=1 --format=s16le

echo ""
echo "=== If you heard audio, Piper + PulseAudio are working correctly ==="
