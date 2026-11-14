#!/bin/bash
# Reads app/identity.json, the one place the product's names live.
#   identity.sh get <prod|dev> <field>          print one field
#   identity.sh swift                           the Swift table the app compiles in
#   identity.sh plist <prod|dev> <template> <out> [sha]
#                                               write a bundle's Info.plist
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JSON="$HERE/identity.json"
FIELDS=(bundleId name executable slug statusTitle)

get() {
  case "$1" in prod|dev) ;; *) echo "identity.sh: no identity \"$1\" (prod or dev)" >&2; exit 64 ;; esac
  plutil -extract "$1.$2" raw -o - "$JSON"
}

swift_string() { local s="${1//\\/\\\\}"; printf '"%s"' "${s//\"/\\\"}"; }

case "${1:-}" in
  get)
    [[ $# == 3 ]] || { echo "usage: identity.sh get <prod|dev> <field>" >&2; exit 64; }
    get "$2" "$3"
    ;;
  swift)
    echo "// Generated from app/identity.json by app/identity.sh."
    echo "extension AppIdentity {"
    for kind in prod dev; do
      printf '    static let %s = AppIdentity(kind: .%s' "$kind" "$kind"
      for f in "${FIELDS[@]}"; do printf ', %s: %s' "$f" "$(swift_string "$(get "$kind" "$f")")"; done
      echo ")"
    done
    echo "}"
    ;;
  plist)
    [[ $# == 4 || $# == 5 ]] || { echo "usage: identity.sh plist <prod|dev> <template> <out> [sha]" >&2; exit 64; }
    kind="$2" out="$4"
    name="$(get "$kind" name)"
    cp "$3" "$out"
    plutil -replace CFBundleIdentifier -string "$(get "$kind" bundleId)" "$out"
    plutil -replace CFBundleName -string "$name" "$out"
    plutil -replace CFBundleDisplayName -string "$name" "$out"
    plutil -replace CFBundleExecutable -string "$(get "$kind" executable)" "$out"
    plutil -replace NSMicrophoneUsageDescription -string \
      "$name records your microphone as the voiceover track of a screen recording." "$out"
    plutil -replace AppIdentityKind -string "$kind" "$out"
    plutil -replace AppBuildSHA -string "${5:-unknown}" "$out"
    plutil -lint -s "$out"
    ;;
  *)
    echo "usage: identity.sh get|swift|plist …" >&2; exit 64
    ;;
esac
