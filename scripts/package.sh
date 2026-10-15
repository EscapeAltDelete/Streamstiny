#!/bin/bash
set -euo pipefail
app="build/device/Build/Products/Release-iphoneos/Streamstiny.app"
test -d "$app"
test -f "$app/Streamstiny"
if [ -d "$app/Frameworks" ]; then
  while IFS= read -r -d '' component; do
    codesign --force --sign - "$component"
  done < <(find "$app/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0)
fi
codesign --force --sign - --entitlements scripts/Streamstiny.entitlements "$app"
codesign --verify --deep --strict "$app"
stage=$(mktemp -d "${TMPDIR:-/tmp}/streamstiny-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Payload"
cp -R "$app" "$stage/Payload/"
output="$PWD/build/Streamstiny.tipa"
rm -f "$output"
(cd "$stage" && zip -q -r -1 "$output" Payload)
python3 scripts/validate_ipa.py build/Streamstiny.tipa
