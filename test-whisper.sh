#!/bin/bash
# test-whisper.sh
# Tests whisper.cpp transcription step by step.
# Run from terminal: bash test-whisper.sh

set -euo pipefail

WHISPER_DIR="${WHISPER_DIR:-$HOME/dev/ai/whisper.cpp}"
WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-cli"
WHISPER_MODEL="${WHISPER_MODEL:-$WHISPER_DIR/models/ggml-small.bin}"

echo "=== 1. Check whisper-cli binary ==="
if [[ ! -x "$WHISPER_BIN" ]]; then
    echo "FAIL: whisper-cli not found or not executable at $WHISPER_BIN"
    echo "Make sure whisper.cpp is built. Run setup-voice-assistant.sh or:"
    echo "  cd ~/dev/ai/whisper.cpp"
    echo "  cmake -B build -DGGML_OPENBLAS=ON"
    echo "  cmake --build build -j"
    exit 1
fi
echo "OK: $WHISPER_BIN"

echo ""
echo "=== 2. Check model file ==="
if [[ ! -f "$WHISPER_MODEL" ]]; then
    echo "FAIL: model not found at $WHISPER_MODEL"
    echo "Download it with:"
    echo "  mkdir -p ~/dev/ai/whisper.cpp/models"
    echo "  curl -L -o ~/dev/ai/whisper.cpp/models/ggml-small.bin \\"
    echo "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
    exit 1
fi
model_size=$(du -h "$WHISPER_MODEL" | cut -f1)
echo "OK: $WHISPER_MODEL ($model_size)"

echo ""
echo "=== 3. Record 3 seconds of test audio ==="
echo "Speak something now (e.g. 'Hello world, this is a test')..."
rec -q -c 1 -r 16000 -b 16 /tmp/test-whisper.wav trim 0 3
echo "OK: saved to /tmp/test-whisper.wav"

echo ""
echo "=== 4. Run transcription ==="
"$WHISPER_BIN" -m "$WHISPER_MODEL" -f /tmp/test-whisper.wav -nt -l en

echo ""
echo "=== Done ==="
