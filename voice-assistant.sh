#!/bin/bash
# voice-assistant.sh - Voice assistant using whisper.cpp and piper-tts
# Modes:
#   echo  - listen, transcribe, copy to clipboard, and speak back
#   stt   - listen, transcribe, and copy to clipboard
# Future extension placeholder: ai mode with llama.cpp
#
# Recording stops when:
#   1. You say the sleepword (default: "stop")
#   2. You press the hotkey a second time
#   3. The 30-second safety cap is reached
set -euo pipefail

# ------------------- Toggle / Stop -------------------
PIDFILE="/tmp/voice-assistant.pid"
STOPFILE="/tmp/voice-assistant.stop"
AUDIO_FILE="/tmp/voice-assistant.wav"
CHECK_AUDIO="/tmp/voice-assistant-check.wav"
CHECK_LOCK="/tmp/voice-assistant-check.lock"
DEBUG_LOG="/tmp/voice-assistant.log"

# ------------------- Configuration -------------------
WHISPER_BIN="${WHISPER_BIN:-whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/whisper.cpp/models/ggml-base.en.bin}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-en}"
PIPER_BIN="${PIPER_BIN:-$HOME/.local/lib/piper-tts/.venv/bin/piper}"
PIPER_VOICE="${PIPER_VOICE:-$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx}"
PLAY_CMD="pacat --playback --rate=22050 --channels=1 --format=s16le"
MAX_RECORD_SECONDS="${MAX_RECORD_SECONDS:-30}"
SLEEPWORD="${SLEEPWORD:-stop}"
CHECK_INTERVAL="${CHECK_INTERVAL:-3}"
MODE="${1:-echo}"   # echo | stt

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
log "WHISPER_BIN=$WHISPER_BIN"
log "WHISPER_MODEL=$WHISPER_MODEL"

# ------------------- Dependency checks -------------------
if ! command -v arecord &>/dev/null; then
  notify-send -t 4000 -u critical \
    "Voice Assistant Error" \
    "arecord not found. Install with: sudo apt install alsa-utils"
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

# ------------------- Toggle: second hotkey press = stop -------------------
# Robust stale-PID check: verify the PID is actually a voice-assistant process
if [[ -f "$PIDFILE" ]]; then
  old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    # Check the process command line actually contains "voice-assistant"
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
  rm -f "$PIDFILE" "$STOPFILE" "$AUDIO_FILE" "$CHECK_AUDIO" "$CHECK_LOCK" /tmp/va-check.txt
}
trap cleanup EXIT INT TERM

# ------------------- Start recording -------------------
notify-send -t 1500 -u low "Voice Assistant" "Listening... say '$SLEEPWORD' when done (max ${MAX_RECORD_SECONDS}s)"

rm -f "$AUDIO_FILE" "$STOPFILE"

# arecord writes a proper WAV file; we kill it when stop is signaled
arecord -f S16_LE -c1 -r16000 -t wav "$AUDIO_FILE" 2>/dev/null &
rec_pid=$!
log "Started recording (pid=$rec_pid, max=${MAX_RECORD_SECONDS}s)"

# ------------------- Background sleepword checker -------------------
# Every CHECK_INTERVAL seconds, transcribe the accumulated audio so far
# and check if the sleepword appears. If yes, create the stop file.
(
  last_checked_size=0
  while [[ ! -f "$STOPFILE" ]]; do
    sleep "$CHECK_INTERVAL"

    # Skip if a check is already in progress
    [[ -f "$CHECK_LOCK" ]] && continue

    # Need the audio file to exist and have grown since last check
    if [[ ! -f "$AUDIO_FILE" ]]; then
      continue
    fi
    current_size="$(stat -c%s "$AUDIO_FILE" 2>/dev/null || echo 0)"
    # ~1 second of 16kHz mono S16 = 32000 bytes; also skip if no new audio
    if [[ "$current_size" -lt 32000 ]] || [[ "$current_size" -le "$last_checked_size" ]]; then
      continue
    fi
    last_checked_size="$current_size"

    touch "$CHECK_LOCK"
    cp "$AUDIO_FILE" "$CHECK_AUDIO" 2>/dev/null || true

    # Run whisper on the copy with a short timeout
    timeout "$CHECK_INTERVAL" "$WHISPER_BIN" \
      -m "$WHISPER_MODEL" \
      -f "$CHECK_AUDIO" \
      -l "$WHISPER_LANGUAGE" \
      --no-timestamps \
      -otxt \
      -of /tmp/va-check 2>/dev/null || true

    text="$(cat /tmp/va-check.txt 2>/dev/null || true)"
    text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed 's/[[:punct:]]//g')"
    log "Checker heard: ${text:-<empty>}"

    if [[ "$text" == *"${SLEEPWORD,,}"* ]]; then
      log "Sleepword '$SLEEPWORD' detected by checker"
      touch "$STOPFILE"
    fi

    rm -f "$CHECK_LOCK"
  done
) &
checker_pid=$!
log "Started sleepword checker (pid=$checker_pid, interval=${CHECK_INTERVAL}s)"

# ------------------- Wait for stop signal or timeout -------------------
elapsed=0
while [[ "$elapsed" -lt "$MAX_RECORD_SECONDS" ]]; do
  if [[ -f "$STOPFILE" ]]; then
    log "Stop signal received"
    break
  fi
  sleep 1
  ((elapsed++)) || true
  log "Recording... ${elapsed}s"
done

if [[ "$elapsed" -ge "$MAX_RECORD_SECONDS" ]]; then
  log "Reached max recording time (${MAX_RECORD_SECONDS}s)"
fi

# Ensure recorder and checker are terminated
kill $rec_pid 2>/dev/null || true
wait $rec_pid 2>/dev/null || true
kill $checker_pid 2>/dev/null || true
wait $checker_pid 2>/dev/null || true
rm -f "$CHECK_LOCK"

# ------------------- Validate recording -------------------
if [[ ! -f "$AUDIO_FILE" ]] || [[ ! -s "$AUDIO_FILE" ]]; then
  notify-send -t 2000 -u normal "Voice Assistant" "No audio recorded."
  log "No audio file or file is empty. Exiting."
  exit 0
fi

audio_size="$(stat -c%s "$AUDIO_FILE" 2>/dev/null || echo 0)"
log "Audio file size: $audio_size bytes"

# Less than ~1 KB is effectively silence
if [[ "$audio_size" -lt 1024 ]]; then
  notify-send -t 2000 -u normal "Voice Assistant" "Recording too short."
  log "Audio too short (< 1 KB). Exiting."
  exit 0
fi

# ------------------- Transcribe -------------------
notify-send -t 1000 -u low "Voice Assistant" "Transcribing..."
log "Running whisper on $AUDIO_FILE"

rm -f /tmp/va-check.txt
"$WHISPER_BIN" \
  -m "$WHISPER_MODEL" \
  -f "$AUDIO_FILE" \
  -l "$WHISPER_LANGUAGE" \
  --no-timestamps \
  -otxt \
  -of /tmp/va-check 2>/dev/null || true

text="$(cat /tmp/va-check.txt 2>/dev/null || true)"
# Remove whisper.cpp's [BLANK_AUDIO] marker and normalize whitespace
text="$(printf '%s' "$text" | sed 's/\[BLANK_AUDIO\]//gi; s/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
log "Transcribed text: ${text:-<empty>}"

if [[ -z "$text" ]]; then
  notify-send -t 2000 -u normal "Voice Assistant" "Could not transcribe audio."
  exit 0
fi

# ------------------- Strip sleepword from end of text -------------------
# Only remove the sleepword if it appears at the end (with optional punctuation/space)
stripped_text="$(printf '%s' "$text" | sed -E "s/[[:space:][:punct:]]*\\b${SLEEPWORD}\\b[[:space:][:punct:]]*\$/ /i" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
if [[ "$stripped_text" != "$text" ]]; then
  log "Stripped sleepword. Before: '${text}' After: '${stripped_text}'"
  text="$stripped_text"
fi

# ------------------- Mode output -------------------
if [[ "$MODE" == "echo" ]]; then
  # Copy to clipboard for convenience
  printf '%s' "$text" | xclip -selection clipboard -in 2>/dev/null || true
  notify-send -t 4000 -u low "Voice Assistant (Echo)" "$text"
  log "Echo mode: copied to clipboard and speaking back"

  # Speak it back via piper
  pkill -f "piper" 2>/dev/null || true
  pkill -f "pacat" 2>/dev/null || true
  sleep 0.1

  ( set +o pipefail
    printf '%s' "$text" | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw | $PLAY_CMD
  ) || {
    # Suppress error if we were killed by a stop request
    if [[ -f "$PIDFILE" ]] && [[ "$(cat "$PIDFILE" 2>/dev/null)" == "$$" ]]; then
      notify-send -t 3000 -u critical "Voice Assistant Error" "Audio playback failed."
    fi
  }

elif [[ "$MODE" == "stt" ]]; then
  printf '%s' "$text" | xclip -selection clipboard -in 2>/dev/null || true
  notify-send -t 4000 -u low "Voice Assistant (STT)" "$text"
  log "STT mode: copied transcription to clipboard"

# ------------------------------------------------------------------
# FUTURE: AI mode with llama.cpp
# ------------------------------------------------------------------
# elif [[ "$MODE" == "ai" ]]; then
#   LLAMA_BIN="${LLAMA_BIN:-llama-cli}"
#   LLAMA_MODEL="${LLAMA_MODEL:-$HOME/llama.cpp/models/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf}"
#   prompt="User: ${text}\nAssistant:"
#   response="$(printf '%s' "$prompt" | "$LLAMA_BIN" -m "$LLAMA_MODEL" --prompt - -n 256 2>/dev/null || true)"
#   response="${response##*Assistant:}"
#   response="$(printf '%s' "$response" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"
#   printf '%s' "$response" | xclip -selection clipboard -in 2>/dev/null || true
#   notify-send -t 4000 -u low "Voice Assistant (AI)" "$response"
#   pkill -f "piper" 2>/dev/null || true
#   pkill -f "pacat" 2>/dev/null || true
#   sleep 0.1
#   ( set +o pipefail
#     printf '%s' "$response" | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw | $PLAY_CMD
#   ) || true

else
  notify-send -t 3000 -u critical \
    "Voice Assistant Error" \
    "Unknown mode: $MODE.\nUse 'echo' or 'stt'."
  log "Unknown mode: $MODE"
  exit 1
fi

log "Finished successfully."
