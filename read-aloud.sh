#!/bin/bash
# read-aloud.sh - Application-aware read aloud
set -euo pipefail

# ------------------- Configuration -------------------
PIPER_BIN="${PIPER_BIN:-$HOME/.local/lib/piper-tts/.venv/bin/piper}"
PIPER_VOICE="${PIPER_VOICE:-$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx}"
PLAY_CMD="pacat --playback --rate=22050 --channels=1 --format=s16le"
DEBUG_LOG="/tmp/read-aloud.log"

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
log "DISPLAY=$DISPLAY"
log "XAUTHORITY=${XAUTHORITY:-<not set>}"

# ------------------- Functions -------------------

get_primary_selection() {
  local text=""
  if command -v xclip &>/dev/null; then
    text="$(xclip -o -selection primary 2>/dev/null || true)"
    log "PRIMARY (auto): len=${#text}"
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t UTF8_STRING 2>/dev/null || true)"
      log "PRIMARY (UTF8_STRING): len=${#text}"
    fi
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t text/plain 2>/dev/null || true)"
      log "PRIMARY (text/plain): len=${#text}"
    fi
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t 'text/plain;charset=utf-8' 2>/dev/null || true)"
      log "PRIMARY (text/plain;charset=utf-8): len=${#text}"
    fi
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t STRING 2>/dev/null || true)"
      log "PRIMARY (STRING): len=${#text}"
    fi
    if [[ -z "$text" ]]; then
      text="$(xclip -o -selection primary -t TEXT 2>/dev/null || true)"
      log "PRIMARY (TEXT): len=${#text}"
    fi
  fi
  echo "$text"
}

get_clipboard() {
  local text=""
  if command -v xclip &>/dev/null; then
    text="$(xclip -o -selection clipboard 2>/dev/null || true)"
  fi
  echo "$text"
}

speak_text() {
  local text="$1"
  local label="${2:-Reading aloud}"

  pkill -f "piper" 2>/dev/null || true
  pkill -f "pacat" 2>/dev/null || true
  pkill -f "paplay" 2>/dev/null || true
  sleep 0.1

  local preview="${text:0:60}"
  [[ ${#text} -gt 60 ]] && preview="${preview}..."

  notify-send -t 2500 -u low "$label" "$preview"

  ( set +o pipefail
    printf '%s' "$text" | "$PIPER_BIN" --model "$PIPER_VOICE" --output-raw | $PLAY_CMD
  ) || {
    notify-send -t 3000 -u critical "Read Aloud Error" "Audio playback failed."
    return 1
  }
}

get_active_window_id() {
  local winid=""
  if command -v xdotool &>/dev/null; then
    winid="$(xdotool getactivewindow 2>/dev/null || true)"
    if [[ -n "$winid" ]]; then
      echo "$winid"
      return 0
    fi
  fi
  if command -v xprop &>/dev/null; then
    winid="$(xprop -root _NET_ACTIVE_WINDOW 2>/dev/null | awk '{print $5}' | sed 's/,//')"
    if [[ "$winid" == "0x0" ]]; then
      winid=""
    fi
    if [[ -n "$winid" ]]; then
      echo "$winid"
      return 0
    fi
  fi
  echo ""
}

get_active_window_class() {
  local winid class
  winid="$(get_active_window_id)"
  log "Active window ID: ${winid:-<none>}"
  if [[ -z "$winid" ]]; then
    echo ""
    return 0
  fi
  if command -v xdotool &>/dev/null; then
    class="$(xdotool getwindowclassname "$winid" 2>/dev/null || true)"
  fi
  if [[ -z "$class" ]] && command -v xprop &>/dev/null; then
    class="$(xprop -id "$winid" WM_CLASS 2>/dev/null | awk -F '"' '{print $4}')"
  fi
  log "Detected window class: ${class:-<none>}"
  echo "$class"
}

get_active_window_pid() {
  local winid pid
  winid="$(get_active_window_id)"
  if [[ -z "$winid" ]]; then
    echo ""
    return 0
  fi
  if command -v xdotool &>/dev/null; then
    pid="$(xdotool getwindowpid "$winid" 2>/dev/null || true)"
  fi
  echo "$pid"
}

get_evince_pdf_path() {
  local pid pdf_path

  pid="$(get_active_window_pid)"
  log "Evince active PID: ${pid:-<none>}"
  if [[ -n "$pid" ]]; then
    pdf_path="$(lsof -Fn -p "$pid" 2>/dev/null | grep -i '^n.*\.pdf$' | sed 's/^n//' | head -n 1)"
    log "Evince PDF from active PID: ${pdf_path:-<none>}"
    [[ -n "$pdf_path" ]] && { echo "$pdf_path"; return 0; }
  fi

  pdf_path="$(for ip in $(pgrep -x evince 2>/dev/null || true); do
    lsof -Fn -p "$ip" 2>/dev/null | grep -i '^n.*\.pdf$' | sed 's/^n//'
  done | head -n 1)"
  log "Evince PDF from all PIDs: ${pdf_path:-<none>}"
  [[ -n "$pdf_path" ]] && { echo "$pdf_path"; return 0; }

  return 1
}

get_evince_current_page() {
  local pdf_path="$1"
  local page=""
  if command -v gio &>/dev/null; then
    # gio stores Evince's internal 0-based page index in metadata::evince::page
    page="$(gio info -a "metadata::evince::page" "$pdf_path" 2>/dev/null \
      | grep -oP 'metadata::evince::page: \K[0-9]+' || true)"
    if [[ -n "$page" ]]; then
      # pdftotext uses 1-based page numbers
      echo "$(( page + 1 ))"
      return 0
    fi
  fi
  return 1
}

get_fbreader_book_path() {
  local pid book_path

  pid="$(get_active_window_pid)"
  if [[ -n "$pid" ]]; then
    book_path="$(lsof -Fn -p "$pid" 2>/dev/null | grep -iE '^n.*\.(epub|fb2|mobi|azw|txt|rtf|html|htm)$' | sed 's/^n//' | head -n 1)"
    [[ -n "$book_path" ]] && { echo "$book_path"; return 0; }
  fi

  local fbdir="$HOME/.FBReader"
  if [[ -d "$fbdir" ]]; then
    for file in "$fbdir/state.xml" "$fbdir/books.xml" "$fbdir/config.xml"; do
      if [[ -f "$file" ]]; then
        book_path="$(grep -oP '(?<=<RecentBook[^>]*>)[^<]+' "$file" 2>/dev/null | head -n 1)"
        if [[ -n "$book_path" && -f "$book_path" ]]; then
          echo "$book_path"
          return 0
        fi
      fi
    done
  fi

  return 1
}

extract_pdf_text() {
  local pdf_path="$1"
  local page="${2:-}"
  if ! command -v pdftotext &>/dev/null; then
    echo ""
    return 0
  fi
  local text=""
  if [[ -n "$page" && "$page" =~ ^[0-9]+$ ]]; then
    log "Running pdftotext on: $pdf_path page $page"
    text="$( set +o pipefail
             timeout 3 pdftotext -f "$page" -l "$page" -layout -nopgbrk "$pdf_path" - 2>/dev/null | head -n 200
           )" || true
    log "pdftotext page $page returned ${#text} chars"
  else
    log "Running pdftotext on: $pdf_path (full document)"
    text="$( set +o pipefail
             timeout 8 pdftotext -layout -nopgbrk "$pdf_path" - 2>/dev/null | head -c 100000
           )" || true
    log "pdftotext returned ${#text} chars"
  fi
  echo "$text"
}

extract_epub_text() {
  local epub_path="$1"
  local text=""

  if command -v pandoc &>/dev/null; then
    text="$( set +o pipefail
             timeout 8 pandoc -f epub -t plain "$epub_path" 2>/dev/null | head -c 50000
           )" || true
    log "pandoc returned ${#text} chars"
    [[ -n "$text" ]] && { echo "$text"; return 0; }
  fi

  if command -v ebook-convert &>/dev/null; then
    text="$( set +o pipefail
             timeout 8 ebook-convert "$epub_path" /dev/stdout --to-txt 2>/dev/null | head -c 50000
           )" || true
    log "ebook-convert returned ${#text} chars"
    [[ -n "$text" ]] && { echo "$text"; return 0; }
  fi

  text="$(unzip -p "$epub_path" "*.html" 2>/dev/null; unzip -p "$epub_path" "*.xhtml" 2>/dev/null)" || true
  if [[ -n "$text" ]]; then
    text="$( set +o pipefail
             printf '%s' "$text" | sed 's/<[^>]*>//g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g; s/&nbsp;/ /g' | tr -s ' \n' ' ' | head -c 50000
           )" || true
    [[ -n "$text" ]] && { echo "$text"; return 0; }
  fi

  return 1
}

# ------------------- Main -------------------

if ! command -v xclip &>/dev/null; then
  notify-send -t 4000 -u critical "Read Aloud Error" "xclip not found. Install with: sudo apt install xclip"
  exit 1
fi

text=""
source_name="none"

app_class="$(get_active_window_class | tr '[:upper:]' '[:lower:]')"
[[ -z "$app_class" ]] && app_class="unknown"
log "Normalized app class: $app_class"

if [[ "$app_class" == "unknown" ]]; then
  if pgrep -x evince &>/dev/null; then
    app_class="evince"
    log "Fallback guess: evince is running"
  elif pgrep -x fbreader &>/dev/null || pgrep -x FBReader &>/dev/null; then
    app_class="fbreader"
    log "Fallback guess: fbreader is running"
  fi
fi

case "$app_class" in
  # ------------------------------------------------------------------
  # EVINCE
  # ------------------------------------------------------------------
  evince|org.gnome.evince)
    notify-send -t 1000 -u low "Read Aloud" "PDF detected..."

    clipboard_before="$(get_clipboard)"
    xdotool key --clearmodifiers ctrl+c
    sleep 0.5
    clipboard_after="$(get_clipboard)"
    log "Evince clipboard before: len=${#clipboard_before}"
    log "Evince clipboard after:  len=${#clipboard_after}"

    if [[ -n "$clipboard_after" && "$clipboard_after" != "$clipboard_before" ]]; then
      text="$clipboard_after"
      source_name="pdf-selection"
      notify-send -t 1500 -u low "Read Aloud" "Reading selected PDF text."
    else
      # No selection detected. Try current-page fallback.
      pdf_path="$(get_evince_pdf_path || true)"
      log "PDF path: ${pdf_path:-<none>}"

      if [[ -n "$pdf_path" && -f "$pdf_path" ]]; then
        current_page="$(get_evince_current_page "$pdf_path" || true)"
        log "Evince current page (1-based for pdftotext): ${current_page:-<none>}"

        if [[ -n "$current_page" && "$current_page" =~ ^[0-9]+$ ]]; then
          notify-send -t 1500 -u low "Read Aloud" "No selection. Reading current page (page $current_page)..."
          text="$(extract_pdf_text "$pdf_path" "$current_page")"
          if [[ -n "$text" ]]; then
            source_name="pdf-page"
          else
            log "Current page extraction returned empty."
          fi
        else
          log "Could not determine current page from gio metadata."
        fi
      fi

      # If still no text, fail gracefully (Option 1)
      if [[ -z "$text" ]]; then
        notify-send -t 4000 -u normal \
          "Read Aloud" \
          "No text selected in PDF.\nPlease select text or copy it manually,\nthen press the hotkey again."
        log "No selection and no safe fallback. Exiting gracefully."
        exit 0
      fi
    fi
    ;;

  # ------------------------------------------------------------------
  # FBREADER
  # ------------------------------------------------------------------
  fbreader|fbreader2|org.fbreader.*)
    text="$(get_primary_selection)"
    if [[ -n "$text" ]]; then
      source_name="primary"
      log "Using PRIMARY selection, length=${#text}"
    fi

    if [[ -z "$text" ]]; then
      notify-send -t 1500 -u low "Read Aloud" "Extracting text from e-book..."
      book_path="$(get_fbreader_book_path || true)"
      log "Book path: ${book_path:-<none>}"
      if [[ -n "$book_path" && -f "$book_path" ]]; then
        if [[ "$book_path" == *.epub ]]; then
          text="$(extract_epub_text "$book_path" || true)"
        elif [[ "$book_path" == *.fb2 ]]; then
          text="$( set +o pipefail
                   cat "$book_path" | sed 's/<[^>]*>//g' | tr -s ' \n' ' ' | head -c 50000
                 )" || true
        elif [[ "$book_path" == *.txt ]]; then
          text="$(head -c 50000 "$book_path")"
        fi
        if [[ -n "$text" ]]; then
          source_name="epub-full"
        fi
      fi
    fi
    ;;

  # ------------------------------------------------------------------
  # BROWSERS
  # ------------------------------------------------------------------
  firefox|navigator|chrome|chromium|chromium-browser|brave|vivaldi|opera)
    text="$(get_primary_selection)"
    if [[ -n "$text" ]]; then
      source_name="primary"
      log "Using PRIMARY selection, length=${#text}"
    fi

    if [[ -z "$text" ]] && [[ ! -t 0 ]]; then
      notify-send -t 2000 -u low "Read Aloud" "Selecting all page text..."
      sleep 0.2
      xdotool key --clearmodifiers ctrl+a
      sleep 0.2
      xdotool key --clearmodifiers ctrl+c
      sleep 0.5
      text="$(get_clipboard)"
      if [[ -n "$text" ]]; then
        source_name="browser-all"
        notify-send -t 2000 -u low "Read Aloud" "Reading full page.\nYour clipboard was overwritten."
      fi
    fi
    ;;

  # ------------------------------------------------------------------
  # TEXT EDITORS
  # ------------------------------------------------------------------
  mousepad|gedit|pluma|leafpad|geany|kate|xed)
    text="$(get_primary_selection)"
    if [[ -n "$text" ]]; then
      source_name="primary"
      log "Using PRIMARY selection, length=${#text}"
    fi

    if [[ -z "$text" ]]; then
      pid="$(get_active_window_pid || true)"
      if [[ -n "$pid" ]]; then
        editor_file="$(lsof -Fn -p "$pid" 2>/dev/null | grep -E '^n.*/.*\.(txt|md|csv|log|sh|py|json|xml|html|c|cpp|h|js)$' | sed 's/^n//' | head -n 1)"
        if [[ -n "$editor_file" && -f "$editor_file" ]]; then
          text="$(head -c 50000 "$editor_file")"
          source_name="editor-file"
        fi
      fi
    fi
    ;;

  # ------------------------------------------------------------------
  # EVERYTHING ELSE
  # ------------------------------------------------------------------
  *)
    text="$(get_primary_selection)"
    if [[ -n "$text" ]]; then
      source_name="primary"
      log "Using PRIMARY selection, length=${#text}"
    fi

    if [[ -z "$text" ]] && command -v xdotool &>/dev/null && [[ ! -t 0 ]]; then
      sleep 0.2
      xdotool key --clearmodifiers ctrl+c
      sleep 0.5
      text="$(get_clipboard)"
      if [[ -n "$text" ]]; then
        source_name="clipboard-auto"
      fi
    fi
    ;;
esac

# Normalize whitespace
text="$(printf '%s\n' "$text" | sed 's/[[:space:]]\+/ /g; s/^ *//; s/ *$//')"

if [[ -z "$text" ]]; then
  notify-send -t 4000 -u normal \
    "Read Aloud" \
    "No text found.\nSelect text, or open a PDF/e-book and press the hotkey."
  log "No text found. Exiting."
  exit 0
fi

log "Final source: $source_name, length=${#text}"

case "$source_name" in
  pdf-selection|pdf-page)
    ;;
  epub-full)
    notify-send -t 1500 -u low "Read Aloud" "Reading full e-book text."
    ;;
  clipboard-auto)
    notify-send -t 1500 -u low "Read Aloud" "Used Ctrl+C fallback.\nYour clipboard was overwritten."
    ;;
esac

speak_text "$text" "Reading aloud"
