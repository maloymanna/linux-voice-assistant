# linux-voice-assistant
Voice assistant and read aloud scripts on Linux 

## [read-aloud.sh](/read-aloud.md):  
A simple read-aloud script for Linux Lite 8 / XFCE. It reads the current text selection from EPUBs (via FBReader) and web pages using the X11 PRIMARY selection.  
  
## [simple-voice-assistant.sh](simple-voice-assistant.md):
A lightweight, local voice assistant for Linux using [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for speech-to-text and [Piper TTS](https://github.com/rhasspy/piper) for text-to-speech. No AI cloud services, no GPU required. Supports only **stop** control word (configurable in the script).  

## [voice-assistant.sh](voice-assistant.md):
Updated version with support for **pause**, **resume** and **stop** control words (configurable in the script).