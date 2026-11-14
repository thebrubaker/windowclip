#!/bin/bash
# The test suite, one command:  test/run.sh [--clickzoom]   (also `bun run test`)
#   session   the shipping SessionController and app Recorder against stubs
#   recorder  the real recorder binary on synthetic frames
#   clickzoom the Remotion render check; renders video, so only with --clickzoom,
#             and on stella or legion-tower rather than the m3
# Nothing here records a screen, launches the app or touches its socket.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
clickzoom=0
for arg in "$@"; do
  case "$arg" in
    --clickzoom) clickzoom=1 ;;
    *) echo "usage: test/run.sh [--clickzoom]" >&2; exit 64 ;;
  esac
done

results=()
run() {
  local name="$1"; shift
  local start=$SECONDS
  echo "### $name"
  if "$@"; then results+=("pass  $name ($((SECONDS - start)) s)")
  else results+=("FAIL  $name ($((SECONDS - start)) s)"); fi
  echo
}

run session "$HERE/session-probe/run.sh"
run recorder "$HERE/recorder-suite/run.sh"
if [[ $clickzoom == 1 ]]; then
  run clickzoom bash -c "cd '$REPO' && bun run test/run-tests.ts"
fi

echo "### summary"
printf '  %s\n' "${results[@]}"
[[ $clickzoom == 1 ]] || echo "  skip  clickzoom (pass --clickzoom; heavy, run it on stella)"
for r in "${results[@]}"; do [[ $r == FAIL* ]] && exit 1; done
exit 0
