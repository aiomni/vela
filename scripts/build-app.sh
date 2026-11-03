#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
product="${2:-Vela}"
offline_check="${3:-}"
release_version="${VELA_VERSION:-}"
release_build="${VELA_BUILD_NUMBER:-}"
if [[ -n "$release_version" && ! "$release_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 -- 'VELA_VERSION must contain three numeric components.'; exit 1
fi
if [[ -n "$release_build" && ! "$release_build" =~ '^[0-9]+$' ]]; then
    print -u2 -- 'VELA_BUILD_NUMBER must be numeric.'; exit 1
fi
apply_bundle_version() {
    [[ -z "$release_version" ]] || plutil -replace CFBundleShortVersionString -string "$release_version" "$1"
    [[ -z "$release_build" ]] || plutil -replace CFBundleVersion -string "$release_build" "$1"
    return 0
}
signing_keychain_options=()
if [[ -n "${SIGNING_KEYCHAIN:-}" ]]; then signing_keychain_options=(--keychain "$SIGNING_KEYCHAIN"); fi
if [[ -n "$offline_check" && "$offline_check" != "--offline-check" ]]; then
    print -u2 -- 'The third argument must be --offline-check'
    exit 1
fi
case "$product" in
    Vela) info_plist="Resources/VelaInfo.plist" ;;
    LockLab) info_plist="Resources/Info.plist" ;;
    *) print -u2 -- 'Supported products: Vela, LockLab'; exit 1 ;;
esac
signing_identity="${SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && -f .signing-identity.local ]]; then
    signing_identity="$(< .signing-identity.local)"
fi
remote_signing_options=(--options runtime --timestamp)
timestamp_option=--timestamp
if [[ -z "$offline_check" ]]; then
    if [[ -z "$signing_identity" || "$signing_identity" == "-" ]]; then
        print -u2 -- 'Set SIGNING_IDENTITY or put a stable signing certificate SHA-1 / name in .signing-identity.local.'
        print -u2 -- 'Packaging requires a stable signing identity and never falls back to ad-hoc signing.'
        exit 1
    fi
    # An actual signing check also supports existing local self-signed identities,
    # which security find-identity -v can omit. Never alter keychain trust here.
    signing_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/vela-signing.XXXXXX")"
    trap 'rm -rf "$signing_probe_dir"' EXIT
    cp /usr/bin/true "$signing_probe_dir/probe"
    codesign --force --options 0 --timestamp=none "${signing_keychain_options[@]}" --sign "$signing_identity" "$signing_probe_dir/probe"
    codesign --verify --strict "$signing_probe_dir/probe"
    signing_team="$(codesign -dv "$signing_probe_dir/probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [[ -z "$signing_team" || "$signing_team" == "not set" ]]; then
        # A local certificate has no Apple Team ID. Library validation would
        # reject WebRTC even when both binaries use the same local certificate.
        remote_signing_options=(--options 0 --timestamp=none)
        timestamp_option=--timestamp=none
    fi
fi
swift build -c "$configuration" --product "$product"
if [[ "$product" == "Vela" ]]; then
    swift build -c "$configuration" --product VelaConnect
fi
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
if [[ -n "$offline_check" ]]; then
    app_dir="$PWD/.build/offline-bundle/$product.app"
else
    app_dir="${VELA_OUTPUT_DIR:-$PWD/dist}/$product.app"
fi
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/$product" "$app_dir/Contents/MacOS/$product"
cp "$info_plist" "$app_dir/Contents/Info.plist"
apply_bundle_version "$app_dir/Contents/Info.plist"
cp -R "$binary_dir/Vela_VelaLocalization.bundle" "$app_dir/Contents/Resources/"
if [[ "$product" == "Vela" ]]; then
    cp -R "$binary_dir/Vela_Vela.bundle" "$app_dir/Contents/Resources/"
    cp Resources/ThirdPartyNotices.txt "$app_dir/Contents/Resources/"
    cp -R Resources/RemoteLicenses "$app_dir/Contents/Resources/"
    "$binary_dir/Vela" --generate-iconset "$PWD/.build/Vela.iconset"
    iconutil --convert icns "$PWD/.build/Vela.iconset" --output "$app_dir/Contents/Resources/Vela.icns"
    rtc_framework="$PWD/.build/artifacts/webrtc/WebRTC/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework"
    [[ -d "$rtc_framework" ]] || { print -u2 -- 'The pinned WebRTC framework is missing. Run swift package resolve first.'; exit 1; }
    for remote_product in Vela VelaConnect; do
        if [[ "$remote_product" == "Vela" ]]; then
            remote_app="$app_dir"
        else
            remote_app="$app_dir/Contents/Applications/$remote_product.app"
        fi
        mkdir -p "$remote_app/Contents/MacOS" "$remote_app/Contents/Resources" "$remote_app/Contents/Frameworks"
        cp "$binary_dir/$remote_product" "$remote_app/Contents/MacOS/$remote_product"
        cp "Resources/${remote_product}Info.plist" "$remote_app/Contents/Info.plist"
        apply_bundle_version "$remote_app/Contents/Info.plist"
        cp -R "$binary_dir/Vela_VelaLocalization.bundle" "$remote_app/Contents/Resources/"
        cp -R "Resources/$remote_product/en.lproj" "Resources/$remote_product/zh-Hans.lproj" "$remote_app/Contents/Resources/"
        cp -R "$rtc_framework" "$remote_app/Contents/Frameworks/"
        cp Resources/ThirdPartyNotices.txt "$remote_app/Contents/Resources/"
        cp -R Resources/RemoteLicenses "$remote_app/Contents/Resources/"
        if [[ "$remote_product" == "Vela" ]]; then
            cp -R "$binary_dir/Vela_RemoteServer.bundle" "$remote_app/Contents/Resources/"
        fi
        install_name_tool -add_rpath '@executable_path/../Frameworks' "$remote_app/Contents/MacOS/$remote_product"
        if [[ -z "$offline_check" ]]; then
            codesign --force "${remote_signing_options[@]}" "${signing_keychain_options[@]}" --sign "$signing_identity" "$remote_app/Contents/Frameworks/WebRTC.framework"
            if [[ "$remote_product" != "Vela" ]]; then
                codesign --force "${remote_signing_options[@]}" "${signing_keychain_options[@]}" --sign "$signing_identity" "$remote_app"
            fi
        fi
        plutil -lint "$remote_app/Contents/Info.plist"
    done
fi
if [[ -z "$offline_check" ]]; then
    # Keep codesign's certificate-bound requirement; never use identifier-only DRs.
    if [[ "$product" == "Vela" ]]; then
        codesign --force "${remote_signing_options[@]}" "${signing_keychain_options[@]}" --sign "$signing_identity" "$app_dir"
    else
        codesign --force --options runtime "$timestamp_option" "${signing_keychain_options[@]}" --sign "$signing_identity" "$app_dir"
    fi
    codesign --verify --deep --strict "$app_dir"
fi
plutil -lint "$app_dir/Contents/Info.plist"
if [[ "$product" == "Vela" ]]; then
    [[ "$(plutil -extract CFBundleIdentifier raw -o - "$app_dir/Contents/Info.plist")" == "app.aiomni.awakepet" ]]
fi
if [[ -n "$offline_check" ]]; then
    print -- 'Offline bundle structure check complete. This bundle is unsigned.'
fi
print -r -- "$app_dir"
