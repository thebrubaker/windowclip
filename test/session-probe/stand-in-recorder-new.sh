#!/bin/bash
# Mirrors the new recorder's file contract: a partial beside the output,
# renamed on SIGTERM, deleted on SIGUSR2. Lifecycle lines as in handshake mode.
out="$3"
partial="$(dirname "$out")/.$(basename "${out%.*}").partial-$$.mp4"
trap 'mv "$partial" "$out"; exit 0' TERM
trap 'rm -f "$partial"; exit 2' USR2
trap 'echo windowclip:capturing; echo "take $$" > "$partial"' USR1
echo windowclip:armed
while true; do sleep 0.05; done
