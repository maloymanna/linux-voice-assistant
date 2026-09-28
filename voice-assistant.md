# Voice Assistant

A lightweight, local voice assistant for Linux using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for speech-to-text and [Piper TTS](https://github.com/rhasspy/piper) for text-to-speech. No cloud services, no GPU required.

## Features

- **Two modes:**
  - `echo` - transcribe, copy to clipboard, and speak back what you said
  - `stt`  - transcribe and copy to clipboard only
- **Sleepword detection:** say "stop" (configurable) to end recording immediately
- **Hotkey toggle:** press the shortcut a second time to stop recording
- **30-second safety cap:** recording automatically stops after 30 seconds
- **Fast on CPU:** uses a tiny model for real-time stop-word detection while keeping a larger model for final transcription accuracy
- **Clipboard integration:** transcribed text is automatically copied to the X11 clipboard

## Requirements

- Linux with ALSA (`arecord`)
- whisper.cpp built with OpenBLAS (CPU-optimized)
- Piper TTS installed
- Python 3 (for WAV header generation)
- `xclip`, `xdotool`, `libnotify-bin` (for clipboard, key release, and desktop notifications)

## Installation

### 1. Build whisper.cpp

```bash
cd ~/dev/ai/whisper.cpp

# Install dependencies
sudo apt-get update
sudo apt-get install -y git cmake build-essential pkg-config \
  libopenblas-dev libsdl2-dev alsa-utils \
  xdotool xclip libnotify-bin python3

# Build with OpenBLAS and SDL2 (SDL2 needed for whisper-stream)
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_OPENBLAS=ON \
  -DWHISPER_SDL2=ON

cmake --build build -j"$(nproc)"
```

### 2. Download models

```bash
# Download tiny model (fast, for stop-word detection)
bash ./models/download-ggml-model.sh tiny.en

# Optionally download small or base for better final transcription accuracy
bash ./models/download-ggml-model.sh small
bash ./models/download-ggml-model.sh base.en
```

### 3. Install Piper TTS

Follow the [Piper installation guide](https://github.com/rhasspy/piper) for your distribution. Ensure the binary is at `~/.local/lib/piper-tts/.venv/bin/piper` or set `PIPER_BIN`.

### 4. Install the script

```bash
chmod +x voice-assistant.sh
# Optionally copy to your local bin
mkdir -p ~/.local/bin
cp voice-assistant.sh ~/.local/bin/
```

## Usage

### Basic usage

```bash
# Echo mode (default): transcribe, copy to clipboard, and speak back
./voice-assistant.sh echo

# STT mode: transcribe and copy to clipboard only
./voice-assistant.sh stt
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_BIN` | `~/dev/ai/whisper.cpp/build/bin/whisper-cli` | Path to whisper binary |
| `WHISPER_MODEL` | `~/dev/ai/whisper.cpp/models/ggml-tiny.en.bin` | Model for final transcription |
| `CHECK_MODEL` | `~/dev/ai/whisper.cpp/models/ggml-tiny.en.bin` | Model for stop-word detection |
| `WHISPER_THREADS` | `$(nproc)` | CPU threads for whisper |
| `PIPER_BIN` | `~/.local/lib/piper-tts/.venv/bin/piper` | Path to piper TTS binary |
| `PIPER_VOICE` | `~/.local/share/piper-voices/en_US-lessac-medium.onnx` | Piper voice model |
| `SLEEPWORD` | `stop` | Word to say to end recording |
| `MAX_RECORD_SECONDS` | `30` | Maximum recording duration |
| `CHECK_CHUNK_SECONDS` | `2` | Audio chunk size for stop-word checker |
| `CHECK_INTERVAL` | `1` | How often the checker runs (seconds) |

### Examples

```bash
# Use small model for better accuracy on final transcription
WHISPER_MODEL=~/dev/ai/whisper.cpp/models/ggml-small.bin ./voice-assistant.sh echo

# Use base model for checker if tiny misses your "stop"
CHECK_MODEL=~/dev/ai/whisper.cpp/models/ggml-base.en.bin ./voice-assistant.sh echo

# Faster stop-word detection with 1-second chunks
CHECK_CHUNK_SECONDS=1 CHECK_INTERVAL=1 ./voice-assistant.sh echo

# Custom sleepword
SLEEPWORD="done" ./voice-assistant.sh echo
```

## Keyboard Shortcut Setup (XFCE)

1. Open **Settings > Keyboard > Application Shortcuts**
2. Click **Add** and select `voice-assistant.sh`
3. Assign a global hotkey (e.g., `Super + Shift + V`)
4. Press the same hotkey again while recording to force-stop

## How It Works

1. **Recording:** `arecord` captures raw PCM audio at 16kHz mono
2. **Sleepword checker:** every `CHECK_INTERVAL` seconds, the last `CHECK_CHUNK_SECONDS` of audio is extracted, wrapped in a WAV header (via Python), and transcribed with a fast tiny model
3. **Stop detection:** when the sleepword is detected, recording stops immediately
4. **Final transcription:** the full recording is converted to WAV and transcribed with the configured model (tiny by default, or small/base for accuracy)
5. **Output:** raw text (with BLANK_AUDIO preserved) is printed to stdout once; cleaned text goes to clipboard and TTS

## Troubleshooting

### Script hangs with no notification

Check if `arecord` can access your microphone:
```bash
arecord -l   # list recording devices
arecord -f S16_LE -c1 -r16000 -d 3 /tmp/test.wav
```

If another process is using the microphone, stop it or use a PulseAudio/ALSA plugin that supports sharing.

### "Recording too short" error

You spoke for less than 1 second, or the microphone is not capturing audio. Check your input levels in your sound settings.

### Stop word not detected

- Try using the `base.en` model for the checker: `CHECK_MODEL=.../ggml-base.en.bin`
- Reduce the chunk size: `CHECK_CHUNK_SECONDS=1`
- Speak clearly and pause slightly before and after "stop"

### Duplicate output in terminal

This was fixed in the latest version. If you still see it, check `/tmp/voice-assistant.log` for multiple checker detections.


## License

MIT (same as whisper.cpp)
