#!/bin/bash
# The doctor:  test/doctor-suite/run.sh [tree]
#   the app's --doctor on fixtures: a dead pid and a wrong process are flagged
#   stale, a live one is read; the bundled recorder's arch and minos; nothing
#   in the fixture changes. The CLI's doctor: runs --doctor only for a bundle
#   whose Info.plist has AppDoctor, and otherwise executes nothing.
# Writes only under a fresh /tmp directory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${1:-$(cd "$HERE/../.." && pwd)}"
WORK="$(mktemp -d /tmp/wc-doctor-suite.XXXXXX)"
fake=""
# shellcheck disable=SC2329  # called by the trap
cleanup() { [[ -n $fake ]] && kill "$fake" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
fail=0
pass() { echo "PASS  $1 — $2"; }
flunk() { echo "FAIL  $1 — $2"; fail=1; }
verdict() { local label="$1" detail="$2"; shift 2; if "$@"; then pass "$label" "$detail"; else flunk "$label" "$detail"; fi; }

APPDIR="$WORK/bin"; mkdir -p "$APPDIR/Contents/MacOS"
"$TREE/app/identity.sh" swift > "$WORK/IdentityTable.swift" || exit 2
swiftc -Onone -target arm64-apple-macosx15.0 "$TREE"/app/Sources/*.swift "$WORK/IdentityTable.swift" \
  -o "$APPDIR/app" 2>"$WORK/build.log" || { grep 'error:' "$WORK/build.log"; exit 2; }
cp "$TREE/cmd/recorder/recorder" "$APPDIR/Contents/MacOS/recorder"
echo "== tree: $TREE"

F="$WORK/fixture"
mkdir -p "$F/Logs" "$F/Backgrounds/Onlook"
echo png > "$F/Backgrounds/Onlook/1B.png"
printf '{"selected":"Onlook/1B.png"}' > "$F/background.json"
printf '[{"path":"/tmp/none.mp4","savedAt":1}]' > "$F/recents.json"
printf '%s\n' "2026-11-13T10:00:00.000-08:00 [session] take 4: recording → saved" \
  "2026-11-13T10:00:04.000-08:00 [session] take 4: saved → idle" > "$F/Logs/windowclip-dev.log"
state() { printf '{"pid":%s,"written":"x","build":"fixture","session":{"phase":"recording","take":9,"next":{"output":"/o.mp4","outputFrom":"default"}}}' "$1" > "$F/state.json"; }
doctor() { "$APPDIR/app" --doctor --doctor-root "$F"; }

before="$("$HERE/snapshot.sh" "$F")"
state 999999
r="$(doctor)"
verdict "dead pid flagged stale" "$(jq -c .state <<<"$r")" \
  test "$(jq -r '.state.stale, .mode, .predicted, .phase' <<<"$r" | paste -sd, -)" == "true,files,true,idle"
verdict "files prediction: Desktop default, saved background" "$(jq -c .next <<<"$r")" \
  test "$(jq -r '.next.outputFrom, .next.background, .next.backgroundFrom' <<<"$r" | paste -sd, -)" == "default,Onlook/1B.png,saved"
state $$
r="$(doctor)"
verdict "a live pid of another program flagged stale" "$(jq -r .state.reason <<<"$r")" \
  grep -q "not $("$TREE/app/identity.sh" get dev executable)" <<<"$(jq -r .state.reason <<<"$r")"

# A stand-in process carrying the dev executable's name. (A copy of /bin/sleep
# is killed on launch: a platform binary's signature doesn't survive the copy.)
printf '#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n' > "$WORK/standin.c"
clang -o "$WORK/$("$TREE/app/identity.sh" get dev executable)" "$WORK/standin.c" || exit 2
"$WORK/$("$TREE/app/identity.sh" get dev executable)" 30 & fake=$!
sleep 0.3
state "$fake"
r="$(doctor)"
verdict "a live state.json is read" "$(jq -c '{mode,phase,take,build}' <<<"$r")" \
  test "$(jq -r '.state.stale, .mode, .predicted, .phase, .take, .build' <<<"$r" | paste -sd, -)" == "false,live,false,recording,9,fixture"
kill "$fake"; wait "$fake" 2>/dev/null; fake=""

want="$(lipo -archs "$APPDIR/Contents/MacOS/recorder") $(otool -l "$APPDIR/Contents/MacOS/recorder" | awk '/minos/{print $2}')"
have="$(jq -r '.recorder.slices[] | "\(.arch) \(.minos)"' <<<"$r")"
verdict "recorder arch and minos read from the file" "$have" test "$have" == "$want"
verdict "recorder sha256" "" test "$(jq -r .recorder.sha256 <<<"$r")" == "$(shasum -a 256 "$APPDIR/Contents/MacOS/recorder" | cut -d' ' -f1)"

rm "$F/state.json"; before="$("$HERE/snapshot.sh" "$F")"
doctor >/dev/null
after="$("$HERE/snapshot.sh" "$F")"
verdict "--doctor writes nothing in the fixture" "$(wc -l <<<"$after" | tr -d ' ') entries" test "$before" == "$after"
printf 'appended\n' >> "$F/Logs/windowclip-dev.log"
control="$("$HERE/snapshot.sh" "$F")"
verdict "control: the snapshot catches one appended line" "" test "$after" != "$control"
verdict "--doctor exits before the app starts" "" test ! -e "$F/state.json"

# The CLI: a bundle with AppDoctor runs its --doctor; one without is never executed.
cli() { (cd "$TREE" && bun src/cli.ts --dev doctor "$@"); }
mk() {  # mk <bundle> <has doctor>
  mkdir -p "$1/Contents/MacOS"
  "$TREE/app/identity.sh" plist dev "$TREE/app/Resources/Info.plist" "$1/Contents/Info.plist" fixture >/dev/null
  [[ $2 == yes ]] || plutil -remove AppDoctor "$1/Contents/Info.plist"
  printf '#!/bin/bash\ntouch %q\necho "{}"\n' "$WORK/ran-$(basename "$1")" > "$1/Contents/MacOS/$("$TREE/app/identity.sh" get dev executable)"
  chmod +x "$1/Contents/MacOS/"*
}
mk "$WORK/New.app" yes; mk "$WORK/Old.app" no
r="$(cli --root "$F" --app "$WORK/New.app")"
verdict "CLI runs --doctor when the plist has AppDoctor" "$r" test -e "$WORK/ran-New.app"
r="$(cli --root "$F" --app "$WORK/Old.app")"
verdict "CLI never executes a build without AppDoctor" "$(jq -r .why <<<"$r")" \
  test ! -e "$WORK/ran-Old.app" -a "$(jq -r '.mode, .phase, .next.backgroundFrom' <<<"$r" | paste -sd, -)" == "files,idle,saved"
rm -f "$WORK/ran-New.app"
r="$(cli --files --root "$F" --app "$WORK/New.app")"
verdict "CLI --files reads files only" "$(jq -r .why <<<"$r")" test ! -e "$WORK/ran-New.app" -a "$(jq -r .why <<<"$r")" == "--files"

echo "doctor suite: $([[ $fail == 0 ]] && echo "all pass" || echo failing)"
exit $fail
