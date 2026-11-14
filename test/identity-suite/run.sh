#!/bin/bash
# The identity checks:  test/identity-suite/run.sh [tree]
#   - which identity and paths each bundle id resolves to (only prod's maps to prod)
#   - a raw binary and bundles with the dev id or an unknown id, run for real:
#     each reports dev paths. The prod id is checked by the mapping only: no
#     copy under Joel's bundle id is ever run.
#   - the control socket refuses to take over one that answers
#   - identity.sh writes each bundle's Info.plist
# Writes only under a fresh /tmp directory; no app, no screen, no socket of his.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="${1:-$(cd "$HERE/../.." && pwd)}"
SRC="$TREE/app/Sources"
WORK="$(mktemp -d /tmp/wc-identity-suite.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
fail=0
pass() { echo "PASS  $1 — $2"; }
flunk() { echo "FAIL  $1 — $2"; fail=1; }

"$TREE/app/identity.sh" swift > "$WORK/IdentityTable.swift" || exit 2
swiftc -swift-version 5 -target arm64-apple-macosx15.0 -o "$WORK/identity" "$HERE/main.swift" \
  "$SRC/Identity.swift" "$WORK/IdentityTable.swift" "$SRC/AppSupport.swift" "$SRC/Log.swift" \
  "$SRC/ControlServer.swift" 2>"$WORK/build.log" || { cat "$WORK/build.log"; exit 2; }

echo "== tree: $TREE"
"$WORK/identity" suite "$WORK/scratch" || fail=1

get() { "$TREE/app/identity.sh" get "$@"; }
SUPPORT="$HOME/Library/Application Support"
DEV_SUPPORT="$SUPPORT/$(get dev name)"
PROD_SUPPORT="$SUPPORT/$(get prod name)"

# Run the same binary bare and from inside bundles, as the app would be.
bundle() {  # bundle <dir> <bundle id>
  mkdir -p "$1/Contents/MacOS"
  cp "$WORK/identity" "$1/Contents/MacOS/identity"
  plutil -create xml1 "$1/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$2" "$1/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string identity "$1/Contents/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "$1/Contents/Info.plist"
}
bundle "$WORK/Dev.app" "$(get dev bundleId)"
bundle "$WORK/Other.app" com.example.other
for run in "raw|none|$WORK/identity" "dev bundle|$(get dev bundleId)|$WORK/Dev.app/Contents/MacOS/identity" \
           "unknown bundle|com.example.other|$WORK/Other.app/Contents/MacOS/identity"; do
  label="${run%%|*}" rest="${run#*|}" id="${rest%%|*}" bin="${rest#*|}"
  out="$("$bin" report)"
  if grep -qx "bundle=$id" <<<"$out"; then pass "$label reads bundle id $id" ""; else flunk "$label reads bundle id $id" "$(head -1 <<<"$out")"; fi
  support="$(sed -n 's/^support=//p' <<<"$out")" socket="$(sed -n 's/^socket=//p' <<<"$out")"
  log="$(sed -n 's/^log=//p' <<<"$out")"
  if grep -qx 'kind=dev' <<<"$out" && [[ $support == "$DEV_SUPPORT" && $socket == "$DEV_SUPPORT/control.sock" \
     && $log == "$HOME/Library/Logs/$(get dev name)/$(get dev slug).log" ]]; then
    pass "$label resolves to dev" "$socket"
  else
    flunk "$label resolves to dev" "$(tr '\n' ' ' <<<"$out")"
  fi
  case "$support/" in "$PROD_SUPPORT/"*) flunk "$label stays out of the prod folder" "$support" ;; esac
done

TEMPLATE="$TREE/app/Resources/Info.plist"
for kind in prod dev; do
  "$TREE/app/identity.sh" plist "$kind" "$TEMPLATE" "$WORK/$kind.plist" abc1234 >/dev/null || { flunk "$kind plist" "identity.sh failed"; continue; }
  want="$(get "$kind" bundleId)|$(get "$kind" name)|$(get "$kind" executable)|$kind|abc1234"
  have="$(for k in CFBundleIdentifier CFBundleName CFBundleExecutable AppIdentityKind AppBuildSHA; do
    plutil -extract "$k" raw -o - "$WORK/$kind.plist"; done | paste -sd'|' -)"
  if [[ $have == "$want" ]]; then pass "$kind Info.plist" "$have"; else flunk "$kind Info.plist" "$have, want $want"; fi
done
template="$(for k in CFBundleIdentifier CFBundleName CFBundleExecutable CFBundleDisplayName; do
  plutil -extract "$k" raw -o - "$TEMPLATE"; done | paste -sd'|' -)"
prod="$(for k in CFBundleIdentifier CFBundleName CFBundleExecutable CFBundleDisplayName; do
  plutil -extract "$k" raw -o - "$WORK/prod.plist"; done | paste -sd'|' -)"
if [[ $prod == "$template" ]]; then pass "prod plist keeps the shipped identity" "$prod"; else flunk "prod plist keeps the shipped identity" "$prod vs $template"; fi

cli() { (cd "$TREE" && bun src/cli.ts "$@"); }
devcli="$(cli --dev paths)" envcli="$(WINDOWCLIP_IDENTITY=dev cli paths)" prodcli="$(cli paths)"
if [[ $(jq -r .socket <<<"$devcli") == "$DEV_SUPPORT/control.sock" && $devcli == "$envcli" \
   && $(jq -r .socket <<<"$prodcli") == "$PROD_SUPPORT/control.sock" ]]; then
  pass "CLI --dev and WINDOWCLIP_IDENTITY=dev talk to dev" "$(jq -r .socket <<<"$devcli")"
else
  flunk "CLI --dev and WINDOWCLIP_IDENTITY=dev talk to dev" "$devcli / $envcli / $prodcli"
fi
WINDOWCLIP_IDENTITY=prdo cli paths >/dev/null 2>&1; code=$?
if [[ $code == 64 ]]; then pass "CLI refuses an unknown identity" "exit $code"; else flunk "CLI refuses an unknown identity" "exit $code"; fi

if [[ -e "$DEV_SUPPORT" ]]; then echo "note  $DEV_SUPPORT exists (made by a dev copy, not by this suite)"; fi
echo "identity suite: $([[ $fail == 0 ]] && echo "all pass" || echo failing)"
exit $fail
