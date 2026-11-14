#!/bin/bash
# The real recorder on synthetic frames: file contract, signals, handshake, gate.
#   test/recorder-suite/run.sh [tree]     (tree defaults to this checkout)
# Builds the tree's cmd/recorder/*.swift and runs it in a scratch dir, muted.
# No screen capture, no TCC, no app.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${1:-$(cd "$HERE/../.." && pwd)}"
WORK="$(mktemp -d /tmp/wc-recorder-suite.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if ! grep -q RECORDER_SOURCE "$TREE"/cmd/recorder/*.swift; then
  echo "== tree: $TREE has no synthetic frame source; the recorder suite cannot run on it"
  exit 2
fi
ARCH="$(uname -m)"
swiftc -O -target "$ARCH-apple-macosx15.0" "$TREE"/cmd/recorder/*.swift -o "$WORK/recorder" 2>"$WORK/build-recorder.log" \
  || { cat "$WORK/build-recorder.log"; exit 2; }
swiftc -O -target "$ARCH-apple-macosx15.0" "$HERE/main.swift" "$TREE/cmd/recorder/Sizing.swift" -o "$WORK/suite" 2>"$WORK/build-suite.log" \
  || { cat "$WORK/build-suite.log"; exit 2; }
mkdir "$WORK/takes"

echo "== tree: $TREE (recorder built for $ARCH)"
"$WORK/suite" "$WORK/recorder" "$WORK/takes"
