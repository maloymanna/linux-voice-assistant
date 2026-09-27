# read-aloud.sh

A simple [read-aloud.sh](/read-aloud.sh) script for Linux Lite 8 / XFCE. It reads the current text selection from EPUBs (via FBReader) and web pages using the X11 PRIMARY selection.

## Features

- Reads selected text from **FBReader** (EPUBs) and **web browsers** via the X11 PRIMARY clipboard.
- Lightweight: no application detection, no document extraction, no fallbacks.
- Kills any previous `piper` / `pacat` instance before starting a new read.

## Requirements

- `bash`, `xclip`
- `piper-tts` (with a voice model)
- `pacat` (PulseAudio)
- `notify-send` (optional)

## Installation

```bash
chmod +x read-aloud.sh
cp read-aloud.sh ~/.local/bin/
```

Bind a hotkey in XFCE to:

```
bash -ic '/home/myuser/.local/bin/read-aloud.sh'
```

## Usage

1. Select text in FBReader or a web browser.
2. Press the hotkey.
3. The script reads the PRIMARY selection aloud.

## Limitations

- **No application awareness**: it reads whatever is in PRIMARY, regardless of which window is focused.
- **No PDF support**: Evince and other PDF viewers are not handled.
- **No fallback**: if nothing is selected, nothing is read.
- **No safety limits**: relies entirely on the user's selection length.

## Evolution

This version can be extended to support:
- Application-aware detection (`xdotool`, `xprop`)
- PDF support with current-page fallback (Evince)
- Safe text extraction with `timeout` and `head` limits
- Generic fallback for text editors and other applications

