#!/bin/zsh
set -euo pipefail
if [[ $# -ne 2 ]]; then
    print -u2 -- 'Usage: create-dmg.sh /path/to/Vela.app /path/to/output.dmg'
    exit 1
fi
bundle="${1:A}"
output="${2:a}"
[[ "${bundle:t}" == Vela.app && -x "$bundle/Contents/MacOS/Vela" &&
   -x "$bundle/Contents/Applications/VelaConnect.app/Contents/MacOS/VelaConnect" ]] || {
    print -u2 -- 'Expected a Vela.app bundle with the embedded Vela Connect controller.'
    exit 1
}
[[ "$output" == *.dmg && ! -e "$output" && ! -L "$output" ]] || {
    print -u2 -- 'The output must be a new .dmg file.'
    exit 1
}
version="$(plutil -extract CFBundleShortVersionString raw -o - "$bundle/Contents/Info.plist")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    print -u2 -- 'The bundle must have a numeric release version.'
    exit 1
}
staging="$(mktemp -d "${TMPDIR:-/tmp}/vela-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$bundle" "$staging/Vela.app"
ln -s /Applications "$staging/Applications"
mkdir -p "${output:h}"
hdiutil create -volname "Vela $version" -srcfolder "$staging" -fs HFS+ -format UDZO "$output"
hdiutil verify "$output"
print -- "Prepared $output"
