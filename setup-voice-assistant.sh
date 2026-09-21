#!/bin/bash
# Local Voice Assistant Setup for Linux Lite 8 / XFCE
# Run this script to install dependencies and build whisper.cpp

set -e

echo "=== Local Voice Assistant Setup ==="
echo "This will install whisper.cpp and helper tools for voice typing and read-aloud."
echo ""

# Update system
echo "[1/6] Updating package lists..."
sudo apt-get update

# Install dependencies
echo "[2/6] Installing dependencies..."
sudo apt-get install -y \
  git cmake build-essential pkg-config \
  libopenblas-dev \
  alsa-utils sox \
  xdotool xclip libnotify-bin \
  wl-clipboard wtype \
  ffmpeg curl

echo "[3/6] Cloning whisper.cpp..."
mkdir -p "$HOME/dev/ai"
if [ ! -d "$HOME/dev/ai/whisper.cpp" ]; then
  git clone https://github.com/ggml-org/whisper.cpp.git "$HOME/dev/ai/whisper.cpp"
else
  echo "whisper.cpp already exists at ~/dev/ai/whisper.cpp, skipping clone."
fi

cd "$HOME/dev/ai/whisper.cpp"

echo "[4/6] Building whisper.cpp with OpenBLAS (CPU optimized)..."
# Only remove build dir if it exists (defensive, for re-runs)
if [ -d "build" ]; then
  echo "  -> Removing existing build directory for a clean compile..."
  rm -rf build
fi
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_OPENBLAS=ON
cmake --build build -j"$(nproc)"

echo "[5/6] Downloading recommended multilingual model (small)..."
bash ./models/download-ggml-model.sh small

echo "[6/6] Creating local bin directory..."
mkdir -p "$HOME/.local/bin"

echo ""
echo "=== Build complete ==="
echo "whisper.cpp binary: $HOME/dev/ai/whisper.cpp/build/bin/whisper-cli"
echo "Model: $HOME/dev/ai/whisper.cpp/models/ggml-small.bin"
echo ""
echo "Next steps:"
echo "1. Copy the helper scripts to ~/.local/bin/"
echo "2. Make them executable: chmod +x ~/.local/bin/*.sh"
echo "3. Add XFCE keyboard shortcuts in Settings > Keyboard > Application Shortcuts"
echo "4. For AI mode, start llama-server first (see voice-assistant.sh comments)"
