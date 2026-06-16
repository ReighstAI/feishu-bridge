#!/bin/bash
# whisper-transcribe — turn a voice message into text for the bridge.
#
# The bridge calls this with one arg (the audio file path) and reads stdout as
# the transcript. Anything other than a clean transcript on stdout — a non-zero
# exit or a "[transcription failed: …]" line — tells the bridge "no text", and
# it falls back to handing the raw audio path to the model. So failures here are
# safe: they degrade, they don't break.
#
# Resolves everything relative to the current user — no hardcoded paths:
#   • whisper-cli is found on PATH (installed by the `whisper-cpp` Homebrew formula)
#   • the model lives at $HOME/.local/share/whisper-cpp/ggml-base.bin
#     (override with $WHISPER_MODEL)
set -uo pipefail

INPUT="${1:-}"
MODEL="${WHISPER_MODEL:-$HOME/.local/share/whisper-cpp/ggml-base.bin}"

if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
  echo "[transcription failed: no input audio]"; exit 1
fi
if ! command -v whisper-cli >/dev/null 2>&1; then
  echo "[transcription failed: whisper-cli not found on PATH]"; exit 1
fi
if [ ! -f "$MODEL" ]; then
  echo "[transcription failed: model missing at $MODEL]"; exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[transcription failed: ffmpeg not found on PATH]"; exit 1
fi

# whisper-cli wants 16 kHz mono WAV; voice messages arrive as opus/other.
TMPWAV="$(mktemp /tmp/whisper-XXXXXX.wav)"
trap 'rm -f "$TMPWAV"' EXIT

if ! ffmpeg -i "$INPUT" -ar 16000 -ac 1 "$TMPWAV" -y -loglevel error 2>/dev/null; then
  echo "[transcription failed: ffmpeg conversion error]"; exit 1
fi

whisper-cli -m "$MODEL" -f "$TMPWAV" --no-timestamps -l auto 2>/dev/null
