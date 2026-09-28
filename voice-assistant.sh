#!/bin/bash
# voice-assistant.sh - Voice assistant using whisper.cpp and piper-tts
# Modes:
#   echo  - listen, transcribe, copy to clipboard, and speak back
#   stt   - listen, transcribe, and copy to clipboard
#
# Recording stops when:
#   1. You say the sleepword (default: "stop")
#   2. You press the hotkey a second time
#   3. The 30-second safety cap is reached
#
# Speed optimizations:
#   - Checker uses a tiny/fast model and only the last CHECK_CHUNK_SECONDS
#     of audio, so whisper runs fast and constant-time.
#   - All whisper invocations use -t $WHISPER_THREADS.
#   - Records raw PCM audio continuously; no growing-WAV header issues.
#   - A small Python helper injects a WAV header over the raw tail data.
#   - All whisper stdout is suppressed; only the final raw transcription
#     is printed once to stdout (BLANK_AUDIO is preserved there).
#
# Environment overrides:
#   WHISPER_MODEL     model for final transcription (default: tiny.en)
#   CHECK_MODEL       model for sleepword checker (default: tiny.en)
#   WHISPER_THREADS   CPU threads for whisper (default: nproc)
#   CHECK_CHUNK_SECONDS  audio chunk for checker (default: 2)
#   CHECK_INTERVAL    how often checker runs (default: 1)
set -euo pipefail

# ------------------- Paths -------------------
PIDFILE="/tmp/voice-assistant.pid"
STOPFILE="/tmp/voice-assistant.stop"
DEBUG_LOG="/tmp/voice-assistant.log"
AUDIO_RAW="/tmp/va-audio.raw"
CHECK_AUDIO_WAV="/tmp/va-check.wav"
CHECK_TEXT="/tmp/va-checker.txt"
FULL_AUDIO_WAV="/tmp/va-audio-full.wav"
RAW_TEXT_FILE="/tmp/va-raw.txt"

# ------------------- Configuration -------------------
WHISPER_BIN="${WHISPER_BIN:-$HOME/dev/ai/whisper.cpp/build/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/dev/ai/whisper.cpp/models/ggml-tiny.en.bin}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-en}"
WHISPER_THREADS="${WHISPER_THREADS:-$(nproc)}"

# Fast model for the sleepword checker (tiny is fastest, base is more robust)
CHECK_MODEL="${CHECK_MODEL:-$HOME/dev/ai/whisper.cpp/models/ggml-tiny.en.bin}"

PIPER_BIN="${PIPER_BIN:-$HOME/.local/lib/piper-tts/.venv/bin/piper}"
PIPER_VOICE="${PIPER_VOICE:-$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx}"
PLAY_CMD="pacat --playback --rate=22050 --channels=1 --format=s16le"
MAX_RECORD_SECONDS="${MAX_RECORD_SECONDS:-30}"
SLEEPWORD="${SLEEPWORD:-stop}"
CHECK_CHUNK_SECONDS="${CHECK_CHUNK_SECONDS:-2}"
CHECK_INTERVAL="${CHECK_INTERVAL:-1}"
MODE="${1:-echo}"   # echo | stt

# 2 seconds of 16kHz mono S16 = 64000 bytes
CHECK_BYTES=$((CHECK_CHUNK_SECONDS * 16000 * 2))

# ------------------- X11 Environment -------------------
export DISPLAY="${DISPLAY:-:0}"
if [[ -z "${XAUTHORITY:-}" ]]; then
  if [[ -f "$HOME/.Xauthority" ]]; then
    export XAUTHORITY="$HOME/.Xauthority"
  elif [[ -f "/run/user/$(id - u)/gdm/Xauthority" ]]; then
    export XAUTHORITY="/run/user/$(id - u)/gdm/Xauthority"
  fi
fi

# ------------------- Sticky modifier fix -------------------
if command -v xdotool &>/dev/null; then
  xdotool keyup Super_L Super_R Hyper_L Hyper_R \
    Control_L Control_R Alt_L Alt_R Shift_L Shift_R 2>/dev/null || true
fi
sleep 0.2

# ------------------- Logging -------------------
: > "$DEBUG_LOG"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$DEBUG_LOG"; }
log "MODE=$MODE"
log "DISPLAY=$DISPLAY"
log "SLEEPWORD=$SLEEPWORD"
log "MAX_RECORD_SECONDS=$MAX_RECORD_SECONDS"
log "CHECK_CHUNK_SECONDS=$CHECK_CHUNK_SECONDS"
log "CHECK_INTERVAL=$CHECK_INTERVAL"
log "WHISPER_BIN=$WHISPER_BIN"
log "WHISPER_MODEL=$WHISPER_MODEL"
log "CHECK_MODEL=$CHECK_MODEL"
log "WHISPER_THREADS=$WHISPER_THREADS"

# ------------------- Dependency checks -------------------
if ! command -v arecord &>/dev/null; then
  notify-send -t 4000 -u critical \
    "Voice Assistant Error" \
    "arecord not found. Install with: sudo apt install alsa-utils"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  notify-send -t 4000 -u critical \
    "Voice Assistant Error" \
    "python3 is required for WAV header generation."
  exit 1
fi

if ! command -v "$WHISPER_BIN" &>/dev/null 2>&1; then
  notify-send -t 4000 -u critical \
    "Voice Assistant Error" \
    "Whisper binary not found: $WHISPER_BIN"
  exit 1
fi

if [[ ! -f "$WHISPER_MODEL" ]]; then
  notify-send -t 4000 -u critical \
    "Voice Assistant Error" \
    "Whisper model not found: $WHISPER_MODEL"
  exit 1
fi

if [[ ! -f "$CHECK_MODEL" ]]; then
  notify-send -t 4000 -u critical \
    "Voice Assistant Error" \
    "Checker model not found: $CHECK_MODEL"
  exit 1
fi

# ------------------- Toggle: second hotkey press = stop -------------------
if [[ -f "$PIDFILE" ]]; then
  old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    if [[ -r "/proc/$old_pid/cmdline" ]] && grep -q "voice-assistant" "/proc/$old_pid/cmdline" 2>/dev/null; then
      touch "$STOPFILE"
      notify-send -t 1000 -u low "Voice Assistant" "Stopping recording..."
      exit 0
    else
      log "Stale PID $old_pid found (not voice-assistant). Removing."
      rm -f "$PIDFILE"
    fi
  else
    log "Stale PID $old_pid not running. Removing."
    rm -f "$PIDFILE"
  fi
fi

# Mark ourselves as the active instance
echo $$ > "$PIDFILE"
cleanup() {
  rm -f "$PIDFILE" "$STOPFILE" "$AUDIO_RAW" "$CHECK_AUDIO_WAV" \
        "$CHECK_TEXT" "$FULL_AUDIO_WAV" "$RAW_TEXT_FILE"
}
trap cleanup EXIT INT TERM

# ------------------- Start recording -------------------
notify-send -t 1500 -u low "Voice Assistant" \
  "Listening... say '$SLEEPWORD' when done (max ${MAX_RECORD_SECONDS}s)"

rm -f "$AUDIO_RAW" "$STOPFILE"

# arecord writes raw samples; avoids WAV header issues while the file grows.
arecord -f S16_LE -c1 -r16000 -t raw "$AUDIO_RAW" 2>/dev/null &
rec_pid=$!
log "Started recording (pid=$rec_pid, max=${MAX_RECORD_SECONDS}s)"

# Make sure arecord actually started
sleep 0.3
if ! kill -0 "$rec_pid" 2>/dev/null; then
  notify-send -t 4000 -u critical "Voice Assistant Error" \
    "arecord failed to start. Check your microphone."
  log "arecord exited immediately. Microphone may be busy or missing."
  exit 1
fi

# ------------------- Background sleepword checker -------------------
# Only transcribe the most recent CHECK_CHUNK_SECONDS of audio.
# The entire subshell is redirected to /dev/null so no checker output
# can leak to the terminal.
(
  while [[ ! -f "$STOPFILE" ]]; do
    sleep "$CHECK_INTERVAL"

    current_size="$(stat -c%s "$AUDIO_RAW" 2>/dev/null || echo 0)"
    # Need at least CHECK_CHUNK_SECONDS of audio before checking
    if [[ "$current_size" -lt "$CHECK_BYTES" ]]; then
      continue
    fi

    # Build a valid WAV from the tail of the raw file.
    python3 -c "
import struct
raw_path = '$AUDIO_RAW'
wav_path = '$CHECK_AUDIO_WAV'
chunk_size = $CHECK_BYTES
file_size = $current_size

with open(raw_path, 'rb') as f:
    start = max(0, file_size - chunk_size)
    f.seek(start)
    data = f.read(chunk_size)

size = len(data)
with open(wav_path, 'wb') as out:
    out.write(b'RIFF')
    out.write(struct.pack('<I', size + 36))
    out.write(b'WAVEfmt ')
    out.write(struct.pack('<I', 16))
    out.write(struct.pack('<H', 1))
    out.write(struct.pack('<H', 1))
    out.write(struct.pack('<I', 16000))
    out.write(struct.pack('<I', 32000))
    out.write(struct.pack('<H', 2))
    out.write(struct.pack('<H', 16))
    out.write(b'data')
    out.write(struct.pack('<I', size))
    out.write(data)
" 2>/dev/null || continue

    rm -f "$CHECK_TEXT"
    timeout 10 "$WHISPER_BIN" \
      -m "$CHECK_MODEL" \
      -f "$CHECK_AUDIO_WAV" \
      -l "$WHISPER_LANGUAGE" \
      -t "$WHISPER_THREADS" \
      --no-timestamps \
      -otxt \
      -of "${CHECK_TEXT%.txt}" >/dev/null 2>/dev/null || true

    text="$(cat "$CHECK_TEXT" 2>/dev/null || true)"
    text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed 's/[[:punct:]]//g')"
    log "Checker heard: ${text:-<empty>}"

    if [[ "$text" == *"${SLEEPWORD,,}"* ]]; then
      log "Sleepword '$SLEEPWORD' detected by checker"
      touch "$STOPFILE"
      kill "$rec_pid" 2>/dev/null || true
      break
    fi
  done
) >/dev/null 2>&1 &
checker_pid=$!
log "Started sleepword checker (pid=$checker_pid, interval=${CHECK_INTERVAL}s, chunk=${CHECK_CHUNK_SECONDS}s)"

# ------------------- Wait for stop signal or timeout -------------------
elapsed_tenths=0
max_tenths=$((MAX_RECORD_SECONDS * 10))
while [[ "$elapsed_tenths" -lt "$max_tenths" ]]; do
  if [[ -f "$STOPFILE" ]]; then
    log "Stop signal received"
    break
  fi
  sleep 0.2
  elapsed_tenths=$((elapsed_tenths + 2))
  if (( elapsed_tenths % 10 == 0 )); then
    log "Recording... $((elapsed_tenths / 10))s"
  fi
done

if [[ "$elapsed_tenths" -ge "$max_tenths" ]]; then
  log "Reached max recording time (${MAX_RECORD_SECONDS}s)"
fi

# Ensure recorder and checker are terminated.
kill "$rec_pid" 2>/dev/null || true
wait "$rec_pid" 2>/dev/null || true

# Kill the whole checker process group (includes timeout/whisper children).
kill -- -"$checker_pid" 2>/dev/null || true
wait "$checker_pid" 2>/dev/null || true

# ------------------- Validate recording -------------------
audio_size="$(stat -c%s "$AUDIO_RAW" 2>/dev/null || echo 0)"
log "Raw audio size: $audio_size bytes"

# Less than ~1 second (32000 bytes) is effectively silence
if [[ "$audio_size" -lt 32000 ]]; then
  notify-send -t 2000 -u normal "Voice Assistant" "Recording too short."
  log "Audio too short (< 1s). Exiting."
  exit 0
fi

# ------------------- Build full WAV and transcribe -------------------
python3 -c "
import struct
raw_path = '$AUDIO_RAW'
wav_path = '$FULL_AUDIO_WAV'

with open(raw_path, 'rb') as f:
    data = f.read()

size = len(data)
with open(wav_path, 'wb') as out:
    out.write(b'RIFF')
    out.write(struct.pack('<I', size + 36))
    out.write(b'WAVEfmt ')
    out.write(struct.pack('<I', 16))
    out.write(struct.pack('<H', 1))
    out.write(struct.pack('<H', 1))
    out.write(struct.pack('<I', 16000))
    out.write(struct.pack('<I', 32000))
    out.write(struct.pack('<H', 2))
    out.write(struct.pack('<H', 16))
    out.write(b'data')
    out.write(struct.pack('<I', size))
    out.write(data)
" 2>/dev/null || {
  notify-send -t 2000 -u normal "Voice Assistant" "Audio conversion failed."
  exit 0
}

notify-send -t 1000 -u low "Voice Assistant" "Transcribing..."
log "Running whisper on full recording"

rm -f "$RAW_TEXT_FILE"
timeout 60 "$WHISPER_BIN" \
  -m "$WHISPER_MODEL" \
  -f "$FULL_AUDIO_WAV" \
  -l "$WHISPER_LANGUAGE" \
  -t "$WHISPER_THREADS" \
  --no-timestamps \
  -otxt \
  -of "${RAW_TEXT_FILE%.txt}" >/dev/null 2>/dev/null || true

# Read raw text and collapse any multi-line whisper output to a single line.
raw_text="$(cat "$RAW_TEXT_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//' || true)"

# Print raw text once to stdout (BLANK_AUDIO is preserved here as requested)
printf '%s\n' "$raw_text"

# Clean text for clipboard / TTS (remove BLANK_AUDIO and normalize)
text="$(printf '%s' "$raw_text" | sed 's/\[BLANK_AUDIO\]//gi; s/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
log "Transcribed text: ${text:-<empty>}"

if [[ -z "$text" ]]; then
  notify-send -t 2000 -u normal "Voice Assistant" "Could not transcribe audio."
  exit 0
fi

# ------------------- Strip sleepword from end of text -------------------
stripped_text="$(printf '%s' "$text" | sed -E "s/[[:space:][:punct:]]*\\b${SLEEPWORD}\\b[[:space:][:punct:]]*$/ /i" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
if [[ "$stripped_text" != "$text" ]]; then
  log "Stripped sleepword. Before: '${text}' After: '${stripped_text}'"
  text="$stripped_text"
fi

# ------------------- Mode output -------------------
if [[ "$MODE" == "echo" ]]; then
  printf '%s' "$text" | xclip -selection clipboard -in 2>/dev/null || true
  notify-send -t 4000 -u low "Voice Assistant (Echo)" "$text"
  log "Echo mode: copied to clipboard and speaking back"

  pkill -f "piper" 2>/dev/null || true
  pkill -f "pacat" 2>/dev/null || true
  sleep 0.1

  ( set +o pipefail
    printf '%s' "$text" | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw | $PLAY_CMD
  ) || {
    if [[ -f "$PIDFILE" ]] && [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]]; then
      notify-send -t 3000 -u critical "Voice Assistant Error" "Audio playback failed."
    fi
  }

elif [[ "$MODE" == "stt" ]]; then
  printf '%s' "$text" | xclip -selection clipboard -in 2>/dev/null || true
  notify-send -t 4000 -u low "Voice Assistant (STT)" "$text"
  log "STT mode: copied transcription to clipboard"

else
  notify-send -t 3000 -u critical \
    "Voice Assistant Error" \
    "Unknown mode: $MODE.\nUse 'echo' or 'stt'."
  log "Unknown mode: $MODE"
  exit 1
fi

log "Finished successfully."
