#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
umask 077
: "${VELA_VERSION:?Set VELA_VERSION}"
: "${VELA_BUILD_NUMBER:?Set VELA_BUILD_NUMBER}"
[[ "$(uname -m)" == arm64 ]] || { print -u2 'CI packaging currently supports arm64 only.'; exit 1; }
mode=unsigned
ci_keychain=''
ci_certificate=''
cleanup() {
    if [[ -n "$ci_keychain" ]]; then security delete-keychain "$ci_keychain" >/dev/null 2>&1 || true; fi
    if [[ -n "$ci_certificate" ]]; then rm -f "$ci_certificate"; fi
}
trap cleanup EXIT
if [[ -n "${MACOS_CERTIFICATE_P12_BASE64:-}${MACOS_CERTIFICATE_PASSWORD:-}${MACOS_SIGNING_IDENTITY:-}" ]]; then
    : "${MACOS_CERTIFICATE_P12_BASE64:?All three signing secrets must be configured}"
    : "${MACOS_CERTIFICATE_PASSWORD:?All three signing secrets must be configured}"
    : "${MACOS_SIGNING_IDENTITY:?All three signing secrets must be configured}"
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { print -u2 'Certificate import is restricted to GitHub Actions.'; exit 1; }
    ci_keychain="$RUNNER_TEMP/vela-signing-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.keychain-db"
    ci_certificate="$RUNNER_TEMP/vela-signing-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}.p12"
    export CI_CERTIFICATE_PATH="$ci_certificate"
    python3 - <<'PY'
import base64, os
from pathlib import Path
encoded = ''.join(os.environ['MACOS_CERTIFICATE_P12_BASE64'].split())
Path(os.environ['CI_CERTIFICATE_PATH']).write_bytes(base64.b64decode(encoded, validate=True))
PY
    keychain_password="$(openssl rand -hex 24)"
    security create-keychain -p "$keychain_password" "$ci_keychain"
    security set-keychain-settings -lut 21600 "$ci_keychain"
    security unlock-keychain -p "$keychain_password" "$ci_keychain"
    security import "$ci_certificate" -k "$ci_keychain" -P "$MACOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$ci_keychain" >/dev/null
    export SIGNING_IDENTITY="$MACOS_SIGNING_IDENTITY" SIGNING_KEYCHAIN="$ci_keychain"
    export VELA_OUTPUT_DIR="$PWD/.build/ci-bundle"
    umask 022
    ./scripts/build-app.sh release Vela
    bundle="$VELA_OUTPUT_DIR/Vela.app"
    codesign --verify --deep --strict "$bundle"
    mode=signed
else
    umask 022
    ./scripts/build-app.sh release Vela --offline-check
    bundle="$PWD/.build/offline-bundle/Vela.app"
fi
for app in "$bundle" "$bundle/Contents/Applications/VelaConnect.app"; do
    plutil -lint "$app/Contents/Info.plist"
    [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")" == "$VELA_VERSION" ]]
    [[ "$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist")" == "$VELA_BUILD_NUMBER" ]]
done
rm -rf .build/ci-release
mkdir -p .build/ci-release
archive="Vela-${VELA_VERSION}-macOS-arm64-${mode}.zip"
disk_image="Vela-${VELA_VERSION}-macOS-arm64-${mode}.dmg"
ditto -c -k --sequesterRsrc --keepParent "$bundle" ".build/ci-release/$archive"
./scripts/create-dmg.sh "$bundle" ".build/ci-release/$disk_image"
export CI_ARCHIVE_PATH="$PWD/.build/ci-release/$archive"
python3 - <<'PY'
import os, zipfile
with zipfile.ZipFile(os.environ['CI_ARCHIVE_PATH']) as archive:
    assert archive.testzip() is None
    assert 'Vela.app/Contents/MacOS/Vela' in archive.namelist()
    assert 'Vela.app/Contents/Applications/VelaConnect.app/Contents/MacOS/VelaConnect' in archive.namelist()
PY
(
    cd .build/ci-release
    shasum -a 256 "$archive" "$disk_image" > SHA256SUMS
)
cat > .build/ci-release/release-notes.md <<EOF
Vela ${VELA_VERSION} for Apple Silicon (arm64), macOS 26 or later.

- Includes the Vela Connect controller.
- Open the DMG and drag Vela to Applications, or extract the ZIP.
- Build: ${VELA_BUILD_NUMBER}; commit: $(git rev-parse HEAD).
- Signature: ${mode}. This workflow does not notarize the app.
- Unsigned builds are testing artifacts; stable macOS permissions require a fixed signing certificate.
- Verify the download against SHA256SUMS.
EOF
print -- "Prepared $archive and $disk_image"
