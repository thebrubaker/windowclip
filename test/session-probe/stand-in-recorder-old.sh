#!/bin/bash
# Mirrors the 3fe3170 recorder: removes the output at start, writes it in place.
out="$3"
rm -f "$out"
trap 'echo "take $$" > "$out"; exit 0' TERM
trap 'echo windowclip:capturing' USR1
echo windowclip:armed
while true; do sleep 0.05; done
