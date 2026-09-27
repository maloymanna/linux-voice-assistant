# read-aloud.sh

A lightweight, application-aware [read-aloud script](/read-aloud.md) for Linux Lite 8 / XFCE. Press a hotkey to have your computer read selected text, or safely fall back to the current document when nothing is selected. Press the same hotkey again while reading to stop immediately.

## Features

- **Toggle with the same hotkey**: press once to start, press again to stop. Works everywhere (PDF, EPUB, web, editors).
- **Application-aware**: detects the active window and adapts its behavior. Never reads stale text from a previously focused window.
- **EPUB / e-books** (FBReader): reads the current selection from the active window, or extracts text from the book file with hard limits.
- **Web pages** (Firefox, Chrome, Chromium, Brave, Vivaldi, Opera): reads the current selection from the active window, or falls back to the full page via `Ctrl+A / Ctrl+C` with a 50 KB cap.
- **PDF** (Evince): reads the current text selection, or safely falls back to the **current visible page only** using GVFS metadata. Never reads the entire PDF.
- **Text editors** (Mousepad, Gedit, Pluma, Leafpad, Geany, Kate, Xed): reads the PRIMARY selection or falls back to the open file.
- **No stale selections across windows**: the script clears the clipboard and sends `Ctrl+C` to the active window before reading, so switching from a browser to an ebook reader always reads from the currently focused application.
- **Safe by design**: all external tools are wrapped with `timeout`, and all text extractions are piped through `head` with strict byte/line limits to prevent memory hogging or freezing on large documents.
- **Sticky-key fix**: releases `Super`, `Ctrl`, `Alt`, and `Shift` on startup so hotkey-triggered `xdotool` commands do not leave modifiers stuck.

## Requirements

- `bash`, `xdotool`, `xclip`, `xprop`, `lsof`
- `piper-tts` (with a voice model)
- `pacat` (PulseAudio)
- `pdftotext` (poppler-utils) for PDF support
- `pandoc` or `ebook-convert` (optional, for EPUB extraction)
- `notify-send` (optional, for desktop notifications)

## Installation

```bash
chmod +x read-aloud.sh
cp read-aloud.sh ~/.local/bin/
```

Bind a hotkey in XFCE (e.g. `Super+R`) to:

```
bash -ic '/home/myuser/.local/bin/read-aloud.sh'
```

## Configuration

Set these environment variables if your paths differ:

```bash
export PIPER_BIN="$HOME/.local/lib/piper-tts/.venv/bin/piper"
export PIPER_VOICE="$HOME/.local/share/piper-voices/en_US-lessac-medium.onnx"
```

## Usage

1. Open a PDF in Evince, a web page in Firefox, or an EPUB in FBReader.
2. Select text (optional).
3. Press the hotkey to start reading.
4. Press the same hotkey again (Toggle) at any time to stop.

When switching between applications, the script always reads from the **currently focused window**, even if a previous selection exists in another application.

## Safety limits

| Source | Limit |
|--------|-------|
| PDF current page | 3-second timeout, max 200 lines |
| EPUB full text | 8-second timeout, max 50 KB |
| Web page full text | max 50 KB |
| Editor / generic file | max 50 KB |
| Audio pipeline | `piper` output is streamed, never fully buffered |

## Logging

Debug output is written to `/tmp/read-aloud.log`.

```bash
cat /tmp/read-aloud.log
```

## Behavior by application

| Application | Selection present | No selection |
|-------------|---------------------|--------------|
| Evince (PDF) | Reads selection via clipboard | Reads **current page only** via GVFS metadata |
| FBReader (EPUB) | Reads selection via active-window `Ctrl+C` | Extracts book text (capped at 50 KB) |
| Browser | Reads selection via active-window `Ctrl+C` | Selects all page text (capped at 50 KB) |
| Text editor | Reads PRIMARY selection | Reads open file (capped at 50 KB) |

## How it avoids stale selections

The X11 PRIMARY selection is global. If you select text in Firefox, switch to FBReader, and press the hotkey, the old script would read the Firefox text because PRIMARY still contained it.

The current script fixes this by:
1. Detecting the active window class first.
2. Clearing the clipboard to empty.
3. Sending `Ctrl+C` to the active window.
4. Reading the clipboard. If text appears, it definitely came from the focused application.

This makes window-switching behavior consistent across all supported applications.

## Toggle / Stop mechanism

The script writes its PID to `/tmp/read-aloud.pid` on startup. If the hotkey is pressed again while a previous instance is still running, the new instance:

1. Detects the PID file.
2. Kills the old process and all audio children (`piper`, `pacat`, `paplay`).
3. Removes the PID file.
4. Shows a *"Stopped"* notification and exits.

If the audio pipeline dies from being killed, the old instance checks whether the PID file still belongs to it. If not, it knows it was stopped intentionally and suppresses the error notification.

## License

MIT / Public Domain — use and modify freely.
