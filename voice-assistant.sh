#!/bin/bash
set -euo pipefail

# ------------------- Paths -------------------
PIDFILE="/tmp/voice-assistant.pid"
STOPFILE="/tmp/voice-assistant.stop"
CTRLFILE="/tmp/va-ctrl.txt"
PAUSE_LOG="/tmp/va-pause-start.log"
PAUSES_LIST="/tmp/va-pauses.list"
DEBUG_LOG="/tmp/voice-assistant.log"
CONTINUOUS_RAW="/tmp/va-continuous.raw"
CHECK_DATA_RAW="/tmp/va-check-data.raw"
CHECK_AUDIO_WAV="/tmp/va-check.wav"
CHECK_TEXT="/tmp/va-checker.txt"
FULL_RAW="/tmp/va-full.raw"
RAW_TEXT_FILE="/tmp/va-raw.txt"

# ------------------- Configuration -------------------
WHISPER_BIN="${WHISPER_BIN:-$HOME/dev/ai/whisper.cpp/build/bin/whisper-cli}"
WHISPER_MODEL="${WHISPER_MODEL:-$HOME/dev/ai/whisper.cpp/models/ggml-tiny.en.bin}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-en}"
WHISPER_THREADS="${WHISPER_THREADS:-$(nproc)}"
CHECK_MODEL="${CHECK_MODEL:-$HOME/dev/ai/whisper.cpp/models/ggml-tiny.en.bin}"
PIPER_BIN="${PIPER_BIN:-$HOME/.local/lib/piper-tts/.venv/bin/piper}"
PIPER_VOICE="${PIPER_VOICE:-$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx}"
PLAY_CMD="pacat --playback --rate=22050 --channels=1 --format=s16le"

MAX_RECORD_SECONDS="${MAX_RECORD_SECONDS:-30}"
SLEEPWORD="${SLEEPWORD:-stop}"
PAUSEWORD="${PAUSEWORD:-pause}"
RESUMEWORD="${RESUMEWORD:-resume}"
CHECK_CHUNK_SECONDS="${CHECK_CHUNK_SECONDS:-3}"
CHECK_INTERVAL="${CHECK_INTERVAL:-0.5}"
MODE="${1:-echo}"   # echo | stt | long

# Set max recording time based on mode
if [[ "$MODE" == "long" ]]; then
    MAX_RECORD_SECONDS="${MAX_RECORD_SECONDS:-300}"
else
    MAX_RECORD_SECONDS="${MAX_RECORD_SECONDS:-30}"
fi

CHECK_BYTES=$((CHECK_CHUNK_SECONDS * 16000 * 2))

# ------------------- X11 Environment -------------------
export DISPLAY="${DISPLAY:-:0}"
if [[ -z "${XAUTHORITY:-}" ]]; then
    if [[ -f "$HOME/.Xauthority" ]]; then
        export XAUTHORITY="$HOME/.Xauthority"
    elif [[ -f "/run/user/$(id -u)/gdm/Xauthority" ]]; then
        export XAUTHORITY="/run/user/$(id -u)/gdm/Xauthority"
    fi
fi

if command -v xdotool &>/dev/null; then
    xdotool keyup Super_L Super_R Hyper_L Hyper_R \
        Control_L Control_R Alt_L Alt_R Shift_L Shift_R 2>/dev/null || true
fi
sleep 0.2

: > "$DEBUG_LOG"
log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" >> "$DEBUG_LOG"; }
log "MODE=$MODE | SLEEPWORD=$SLEEPWORD | PAUSEWORD=$PAUSEWORD | RESUMEWORD=$RESUMEWORD"

if ! command -v arecord &>/dev/null; then
    notify-send -t 4000 -u critical "Voice Assistant Error" "arecord not found."
    exit 1
fi
if ! command -v "$WHISPER_BIN" &>/dev/null 2>&1; then
    notify-send -t 4000 -u critical "Voice Assistant Error" "Whisper binary not found."
    exit 1
fi

if [[ -f "$PIDFILE" ]]; then
    old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        if grep -q "voice-assistant" "/proc/$old_pid/cmdline" 2>/dev/null; then
            touch "$STOPFILE"
            notify-send -t 1000 -u low "Voice Assistant" "Stopping..."
            exit 0
        else
            rm -f "$PIDFILE"
        fi
    else
        rm -f "$PIDFILE"
    fi
fi

echo $$ > "$PIDFILE"
cleanup() {
    rm -f "$PIDFILE" "$STOPFILE" "$CTRLFILE" "$PAUSE_LOG" "$PAUSES_LIST" \
        "$CONTINUOUS_RAW" "$CHECK_DATA_RAW" "$FULL_RAW" "$FULL_RAW.wav" \
        "$CHECK_AUDIO_WAV" "$CHECK_TEXT" "$RAW_TEXT_FILE"
}
trap cleanup EXIT INT TERM

print_le32() {
    local val=$1
    printf "\\x$(printf '%02x' $((val & 0xFF)))"
    printf "\\x$(printf '%02x' $(((val >> 8) & 0xFF)))"
    printf "\\x$(printf '%02x' $(((val >> 16) & 0xFF)))"
    printf "\\x$(printf '%02x' $(((val >> 24) & 0xFF)))"
}
print_le16() {
    local val=$1
    printf "\\x$(printf '%02x' $((val & 0xFF)))"
    printf "\\x$(printf '%02x' $(((val >> 8) & 0xFF)))"
}

build_wav_header() {
    local data_size=$1
    local file_size=$((data_size + 36))
    printf 'RIFF'
    print_le32 "$file_size"
    printf 'WAVEfmt '
    print_le32 16
    print_le16 1
    print_le16 1
    print_le32 16000
    print_le32 32000
    print_le16 2
    print_le16 16
    printf 'data'
    print_le32 "$data_size"
}

notify-send -t 2500 -u low "Voice Assistant" \
    "Listening... say '$PAUSEWORD'/'$RESUMEWORD' to control, '$SLEEPWORD' to stop"
    
rm -f "$CONTINUOUS_RAW" "$PAUSES_LIST" "$PAUSE_LOG" "$FULL_RAW" "$FULL_RAW.wav" "$STOPFILE" "$CTRLFILE"

arecord -f S16_LE -c1 -r16000 -t raw "$CONTINUOUS_RAW" 2>/dev/null &
rec_pid=$!
log "Started continuous recording (pid=$rec_pid)"

sleep 0.3
if ! kill -0 "$rec_pid" 2>/dev/null; then
    notify-send -t 4000 -u critical "Voice Assistant Error" "arecord failed to start."
    exit 1
fi

(
    while [[ ! -f "$STOPFILE" ]]; do
        sleep "$CHECK_INTERVAL"
        
        current_size=$(stat -c%s "$CONTINUOUS_RAW" 2>/dev/null || echo 0)
        if [[ "$current_size" -lt "$CHECK_BYTES" ]]; then
            continue
        fi
        
        tail -c "$CHECK_BYTES" "$CONTINUOUS_RAW" > "$CHECK_DATA_RAW"
        actual_size=$(stat -c%s "$CHECK_DATA_RAW")
        { build_wav_header "$actual_size"; cat "$CHECK_DATA_RAW"; } > "$CHECK_AUDIO_WAV"
        
        rm -f "$CHECK_TEXT"
        timeout 10 "$WHISPER_BIN" \
            -m "$CHECK_MODEL" -f "$CHECK_AUDIO_WAV" -l "$WHISPER_LANGUAGE" \
            -t "$WHISPER_THREADS" --no-timestamps -otxt -of "${CHECK_TEXT%.txt}" >/dev/null 2>&1 || true
            
        text="$(cat "$CHECK_TEXT" 2>/dev/null || true)"
        text="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | sed 's/[[:punct:]]//g')"
        
        action=""
        if [[ "$text" == *"${SLEEPWORD,,}"* ]]; then action="stop"
        elif [[ "$text" == *"${PAUSEWORD,,}"* ]]; then action="pause"
        elif [[ "$text" == *"${RESUMEWORD,,}"* ]]; then action="resume"
        fi
        
        if [[ -n "$action" ]]; then
            echo "$action" > "$CTRLFILE"
            if [[ "$action" == "stop" ]]; then
                touch "$STOPFILE"
                break
            fi
        fi
    done
) >/dev/null 2>&1 &
checker_pid=$!

is_paused=0
elapsed_tenths=0
max_tenths=$((MAX_RECORD_SECONDS * 10))

while [[ "$elapsed_tenths" -lt "$max_tenths" ]]; do
    if [[ -f "$STOPFILE" ]]; then
        log "Stop signal received"
        notify-send -t 1500 -u low "Voice Assistant" "Stopping..."
        break
    fi
    
    if [[ -f "$CTRLFILE" ]]; then
        action="$(cat "$CTRLFILE" 2>/dev/null || true)"
        rm -f "$CTRLFILE"
        
        if [[ "$action" == "pause" && "$is_paused" -eq 0 ]]; then
            is_paused=1
            pause_start=$(stat -c%s "$CONTINUOUS_RAW" 2>/dev/null || echo 0)
            echo "$pause_start" > "$PAUSE_LOG"
            notify-send -t 1500 -u low "Voice Assistant" "Pausing..."
            log "Paused at byte $pause_start"
            
        elif [[ "$action" == "resume" && "$is_paused" -eq 1 ]]; then
            is_paused=0
            pause_end=$(stat -c%s "$CONTINUOUS_RAW" 2>/dev/null || echo 0)
            pause_start=$(cat "$PAUSE_LOG" 2>/dev/null || echo 0)
            echo "${pause_start}:${pause_end}" >> "$PAUSES_LIST"
            notify-send -t 1500 -u low "Voice Assistant" "Resuming..."
            log "Resumed at byte $pause_end (paused from $pause_start)"
        fi
    fi
    
    if [[ "$is_paused" -eq 0 ]]; then
        sleep 0.2
        elapsed_tenths=$((elapsed_tenths + 2))
    else
        sleep 0.2
    fi
done

if [[ "$elapsed_tenths" -ge "$max_tenths" && "$is_paused" -eq 0 ]]; then
    log "Reached max recording time"
    notify-send -t 1500 -u low "Voice Assistant" "Stopping..."
fi

if [[ "$is_paused" -eq 1 ]]; then
    pause_end=$(stat -c%s "$CONTINUOUS_RAW" 2>/dev/null || echo 0)
    pause_start=$(cat "$PAUSE_LOG" 2>/dev/null || echo 0)
    echo "${pause_start}:${pause_end}" >> "$PAUSES_LIST"
    log "Closed pause boundary at stop: $pause_start to $pause_end"
fi

if [[ -n "${rec_pid:-}" ]]; then
    kill "$rec_pid" 2>/dev/null || true
    wait "$rec_pid" 2>/dev/null || true
fi
kill -- -"$checker_pid" 2>/dev/null || true
wait "$checker_pid" 2>/dev/null || true

> "$FULL_RAW"
current_pos=0
file_size=$(stat -c%s "$CONTINUOUS_RAW" 2>/dev/null || echo 0)

if [[ -f "$PAUSES_LIST" ]]; then
    while IFS=: read -r start end; do
        if [[ -z "$start" || -z "$end" ]]; then continue; fi
        
        if (( start > file_size )); then start=$file_size; fi
        if (( end > file_size )); then end=$file_size; fi
        
        if (( start > current_pos )); then
            length=$((start - current_pos))
            # FIX: Added || true to suppress SIGPIPE when head exits early
            tail -c "+$((current_pos + 1))" "$CONTINUOUS_RAW" | head -c "$length" >> "$FULL_RAW" || true
        fi
        current_pos=$end
    done < "$PAUSES_LIST"
fi

if (( current_pos < file_size )); then
    tail -c "+$((current_pos + 1))" "$CONTINUOUS_RAW" >> "$FULL_RAW" || true
fi

audio_size=$(stat -c%s "$FULL_RAW" 2>/dev/null || echo 0)
if [[ "$audio_size" -lt 32000 ]]; then
    notify-send -t 2000 -u normal "Voice Assistant" "Recording too short."
    exit 0
fi

{ build_wav_header "$audio_size"; cat "$FULL_RAW"; } > "$FULL_RAW.wav"

notify-send -t 1000 -u low "Voice Assistant" "Transcribing..."
rm -f "$RAW_TEXT_FILE"
timeout 60 "$WHISPER_BIN" \
    -m "$WHISPER_MODEL" -f "$FULL_RAW.wav" -l "$WHISPER_LANGUAGE" \
    -t "$WHISPER_THREADS" --no-timestamps -otxt -of "${RAW_TEXT_FILE%.txt}" >/dev/null 2>&1 || true

raw_text="$(cat "$RAW_TEXT_FILE" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//' || true)"

# Globally remove all instances of control words, BLANK_AUDIO, and normalize spaces
# Also clean up pause artifacts: multiple periods, ". ." patterns, etc.
cleaned_text="$(printf '%s' "$raw_text" | \
    sed -E "s/\b(${SLEEPWORD}|${PAUSEWORD}|${RESUMEWORD})\b//gi" | \
    sed 's/\[BLANK_AUDIO\]//gi' | \
    sed -E 's/\.[[:space:]]+\././g' | \
    sed -E 's/\.{2,}/./g' | \
    sed -E 's/[[:space:]]+/ /g' | \
    sed -E 's/([.!?])[[:space:]]+/\1 /g' | \
    sed 's/^ *//; s/ *$//')"
log "Cleaned text: ${cleaned_text:-<empty>}"

# Print cleaned text to stdout (control words removed)
printf '%s\n' "$cleaned_text"

if [[ -z "$cleaned_text" ]]; then
    notify-send -t 2000 -u normal "Voice Assistant" "Could not transcribe audio."
    exit 0
fi

# ------------------- Mode output -------------------
if [[ "$MODE" == "echo" ]]; then
    printf '%s' "$cleaned_text" | xclip -selection clipboard -in 2>/dev/null || true
    notify-send -t 4000 -u low "Voice Assistant (Echo)" "$cleaned_text"
    
    pkill -f "piper" 2>/dev/null || true; pkill -f "pacat" 2>/dev/null || true
    sleep 0.1
    
    ( set +o pipefail
        printf '%s' "$cleaned_text" | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw | $PLAY_CMD
    ) || notify-send -t 3000 -u critical "Voice Assistant Error" "Audio playback failed."
    
elif [[ "$MODE" == "stt" || "$MODE" == "long" ]]; then
    printf '%s' "$cleaned_text" | xclip -selection clipboard -in 2>/dev/null || true
    notify-send -t 4000 -u low "Voice Assistant (${MODE^^})" "$cleaned_text"
    log "${MODE^^} mode: copied transcription to clipboard"
else
    notify-send -t 3000 -u critical "Voice Assistant Error" "Unknown mode: $MODE. Use 'echo', 'stt', or 'long'."
    log "Unknown mode: $MODE"
    exit 1    
fi

log "Finished successfully."