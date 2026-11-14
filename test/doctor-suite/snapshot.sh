#!/bin/bash
# snapshot.sh <dir>... : one line per file (path, size, mtime) plus a hash of
# each *.log's last 4 KB. Reads only. Two snapshots that differ mean something
# was written.
set -uo pipefail
for dir in "$@"; do
  [[ -e $dir ]] || { echo "absent $dir"; continue; }
  find "$dir" -print0 | sort -z | while IFS= read -r -d '' f; do
    printf '%s %s\n' "$f" "$(stat -f '%z %m' "$f")"
    if [[ $f == *.log && -f $f ]]; then printf 'tail %s %s\n' "$f" "$(tail -c 4096 "$f" | shasum -a 256 | cut -c1-16)"; fi
  done
done
