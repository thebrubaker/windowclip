#!/bin/bash
# Regression probe for the session's request state and file safety.
#   test/session-probe/run.sh [tree]     (tree defaults to this checkout)
# Builds two probes from the tree's real SessionController (B adds its real
# app Recorder.swift) and runs them in a scratch dir. No app, no capture.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${1:-$(cd "$HERE/../.." && pwd)}"
SRC="$TREE/app/Sources"
WORK="$(mktemp -d /tmp/wc-session-probe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [[ -f "$SRC/Log.swift" ]]; then
  SHIM=("$HERE/shim-new.swift" "$SRC/Log.swift" "$SRC/AppSupport.swift")
else
  SHIM=("$HERE/shim-old.swift")
fi
if grep -q 'partial-' "$TREE/cmd/recorder/main.swift"; then STANDIN=new; else STANDIN=old; fi

swiftc -swift-version 5 -o "$WORK/probe-a" "$HERE/stubs.swift" "$HERE/stub-recorder.swift" "$HERE/a/main.swift" \
  "${SHIM[@]}" "$SRC/SessionController.swift" 2>"$WORK/build-a.log" || { cat "$WORK/build-a.log"; exit 2; }
swiftc -swift-version 5 -o "$WORK/probe-b" "$HERE/stubs.swift" "$HERE/b/main.swift" \
  "${SHIM[@]}" "$SRC/SessionController.swift" "$SRC/Recorder.swift" 2>"$WORK/build-b.log" || { cat "$WORK/build-b.log"; exit 2; }

mkdir -p "$WORK/a" "$WORK/b/root/cmd/recorder"
install -m 755 "$HERE/stand-in-recorder-$STANDIN.sh" "$WORK/b/root/cmd/recorder/recorder"

echo "== tree: $TREE (recorder stand-in: $STANDIN)"
status=0
"$WORK/probe-a" "$WORK/a" || status=1
WINDOWCLIP_ROOT="$WORK/b/root" "$WORK/probe-b" "$WORK/b" || status=1
exit $status
