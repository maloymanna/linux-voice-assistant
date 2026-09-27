# read-aloud.sh

A lightweight, application-aware [read-aloud script](/read-aloud.md) for Linux Lite 8 / XFCE. Press a hotkey to have your computer read selected text, or safely fall back to the current document when nothing is selected.

## Features

- **Application-aware**: detects the active window and adapts its behavior.
- **EPUB / e-books** (FBReader): reads the current selection via PRIMARY, or extracts text from the book file with hard limits.
- **Web pages** (Firefox, Chrome, Chromium, Brave, Vivaldi, Opera): reads the current selection, or falls back to the full page via `Ctrl+A / Ctrl+C` with a length cap.
- **PDF** (Evince): reads the current text selection, or safely falls back to the **current visible page only** using GVFS metadata. Never reads the entire PDF.
- **Text editors** (Mousepad, Gedit, Pluma, Leafpad, Geany, Kate, Xed): reads the PRIMARY selection or falls back to the open file.
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
3. Press the hotkey.
4. The script detects the application and reads the selection, or falls back safely to the current page/document.

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
| Evince (PDF) | Reads selection | Reads **current page only** |
| FBReader (EPUB) | Reads PRIMARY | Extracts book text (capped) |
| Browser | Reads PRIMARY | Selects all page text (capped) |
| Text editor | Reads PRIMARY | Reads open file (capped) |

## License

MIT / Public Domain — use and modify freely.
