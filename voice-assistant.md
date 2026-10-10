# Voice Assistant

A lightweight, local voice assistant for Linux using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for speech-to-text and [Piper TTS](https://github.com/rhasspy/piper) for text-to-speech. No cloud services, no GPU required. Support for **pause**, **resume** and **stop** control words (configurable in the script).

## Features

- **Two modes**:
  - `echo` - transcribe, copy to clipboard, and speak back what you said.
  - `stt` - transcribe and copy to clipboard only.
- **Voice Control Words**: Say "pause", "resume", or "stop" (all configurable) to control the recording state hands-free.
- **Smart Timer**: Time spent in paused mode is **excluded** from the 30-second maximum recording limit.
- **Privacy by Design**: Audio spoken while paused is recorded to a temporary buffer and permanently discarded (byte-skipped) upon resuming. It is never transcribed.
- **Global Text Cleaning**: Control words are automatically stripped from the final transcription via regex, ensuring they never reach your clipboard or the TTS engine.
- **Hotkey Toggle**: Press the shortcut a second time to force-stop recording immediately.
- **30-Second Safety Cap**: Recording automatically stops after 30 seconds of *active* speaking time.
- **Fast on CPU**: Uses a pure Bash WAV header generator (sub-5ms) and an overlapping 3-second detection window checked every 0.5s for maximum reliability without heavy CPU usage.
- **Clipboard Integration**: Transcribed text is automatically copied to the X11 clipboard.
- **Desktop Notifications**: Visual toast notifications for "Pausing...", "Resuming...", "Stopping...", and transcription results.

## Requirements

- Linux with ALSA (`arecord`)
- `whisper.cpp` built with OpenBLAS (CPU-optimized)
- Piper TTS installed
- Standard GNU coreutils (`tail`, `head`, `cat`, `stat`)
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

# Build with OpenBLAS and SDL2
cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_OPENBLAS=ON \
  -DWHISPER_SDL2=ON
cmake --build build -j"$(nproc)"
```

### 2. Download models

```bash
# Download tiny model (fast, for real-time control-word detection)
bash ./models/download-ggml-model.sh tiny.en

# Highly recommended: Download base.en for much better control-word reliability
bash ./models/download-ggml-model.sh base.en

# Optionally download small or base for better final transcription accuracy
bash ./models/download-ggml-model.sh small
bash ./models/download-ggml-model.sh base.en
```

### 3. Install Piper TTS

Follow the [Piper installation guide](https://github.com/rhasspy/piper) for your distribution. Ensure the binary is at `~/.local/lib/piper-tts/.venv/bin/piper` or set the PIPER_BIN environment variable.

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
| `PAUSEWORD` | `pause` | Word to say to pause recording |
| `RESUMEWORD` | `resume` | Word to say to resume recording |
| `MAX_RECORD_SECONDS` | `30` | Maximum recording duration |
| `CHECK_CHUNK_SECONDS` | `3` | Audio chunk size for stop-word checker (3s provides high overlap) |
| `CHECK_INTERVAL` | `0.5` | How often the checker runs (seconds) |

### Examples

```bash
# Use base.en model for the checker if tiny.en misses your "pause" or "resume" words
CHECK_MODEL=~/dev/ai/whisper.cpp/models/ggml-base.en.bin ./voice-assistant.sh echo

# Use small model for better accuracy on final transcription
WHISPER_MODEL=~/dev/ai/whisper.cpp/models/ggml-small.bin ./voice-assistant.sh echo

# Custom control words
SLEEPWORD="done" PAUSEWORD="hold" RESUMEWORD="pickup" ./voice-assistant.sh echo
```

## Keyboard Shortcut Setup (XFCE)

1. Open **Settings > Keyboard > Application Shortcuts**
2. Click **Add** and select `voice-assistant.sh`
3. Assign a global hotkey (e.g., `Super + Shift + V`)
4. Press the same hotkey again while recording to force-stop

## How It Works

1. **Continuous Recording**: `arecord` captures a single, continuous raw PCM audio stream at 16kHz mono. The microphone is never dropped, preventing hardware lock issues.
2. **Overlapping Checker**: Every `CHECK_INTERVAL` (0.5s), the last `CHECK_CHUNK_SECONDS` (3s) of audio is extracted. A pure Bash function injects a valid WAV header in <2ms, and the fast checker model transcribes it.
3. **Byte-Skipping Pauses**: When "pause" is detected, the script logs the current byte offset. When "resume" is detected, it logs the end offset. The audio between these offsets is treated as "dummy" data.
4. **Final Assembly**: Upon stopping, pure Bash `tail` and `head` commands read the continuous file and stitch together *only* the active speech segments, permanently discarding the paused "dummy" audio in milliseconds.
5. **Final Transcription**: The assembled clean audio is given a pure Bash WAV header and transcribed with the configured accuracy model.
6. **Advanced Text Cleaning & Output**: The raw text undergoes multiple cleaning passes:
   - Control words ("stop", "pause", "resume") are globally removed via regex
   - `[BLANK_AUDIO]` tags are stripped
   - Pause artifacts (multiple periods like `..` or `. .`) are cleaned up
   - Multiple spaces are collapsed to single spaces
   - Proper sentence spacing is enforced (single space after punctuation)
   - The cleaned text is printed to stdout, copied to the clipboard, and optionally spoken via Piper TTS.

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

### Control words ("pause"/"resume") not detected reliably

1. **Upgrade the checker model:** The `tiny.en` model is very fast but can struggle with short, isolated command words. Switch to `base.en`:
`CHECK_MODEL=~/dev/ai/whisper.cpp/models/ggml-base.en.bin ./voice-assistant.sh echo`
2. **Speak clearly:** Pause slightly before and after saying the control word.
3. The script now uses a 3-second overlapping window checked every 0.5s, which makes it virtually impossible for a word to be cut in half. If it still misses, the `base.en` model is the definitive fix.


## License

MIT (same as whisper.cpp)
