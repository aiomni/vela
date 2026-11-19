# CoreHID lab on a Vela virtual display — November 9, 2026

`VelaTouchLab` now accepts `--vela-virtual-display`. It selects an existing
active, unmirrored Vela display by the descriptor's vendor, model, and serial
fields. If several displays match, supply `--display-id ID`. The receiver
records the actual window display and checks that the whole window fits on it.
The live sequence rechecks the display before sending contacts.

On macOS 27.0.1 (26A434), the creation probe selected the active Vela virtual
display and called `HIDVirtualDevice(properties:)`. It returned `nil` with exit
2. `SecTask` reported that the executing process lacked the entitlement. The
creation probe submitted zero input reports. Native direct touch, one-finger
scrolling, and two-finger magnification remain unverified.

The receiver-only smoke passed on Vela display ID 8 with the window fully on
the selected screen and standard touch scrolling enabled. The initial smoke
placed the window on the physical screen. Constructing the window with an
explicit `NSScreen` and screen-relative content coordinates corrected placement.
The Vela-only probe rejected physical display ID 1 before calling CoreHID.
The debug lab build and all six touchscreen report tests passed.

The earlier matched signing comparison used the same executable and local
certificate for both variants. The control launched and returned `nil` from
CoreHID. The variant claiming the entitlement was terminated at launch with
AMFI error `-413`, `No matching profile found`. The local certificate in that
comparison had no Apple Team ID. See the [matched signing evidence](vela-corehid-touch-signed-validation-2026-11-06.md).

## Obtain a profile for the lab

1. In a paid Apple Developer team, register the explicit macOS App ID
   `app.aiomni.awakepet.touchlab` for the lab. The Account Holder opens
   **Certificates, Identifiers & Profiles → Identifiers → the lab App ID → Capability Requests**.
   Request **HID Virtual Device**, with the exact Boolean entitlement
   `com.apple.developer.hid.virtual.device`. If the entry is absent, sign in to
   the Virtual HID request form or ask Apple Developer Support for the exact
   CoreHID capability. The request form requires sign-in. [Apple capability requests](https://developer.apple.com/help/account/capabilities/capability-requests), [Virtual HID request form](https://developer.apple.com/contact/request/system-extension/), [Apple DTS on the restricted entitlement](https://developer.apple.com/forums/thread/820708).
2. Describe the intended authenticated remote touch workflow and the local
   isolated prototype. Include the lab bundle ID, OS build, and AMFI `-413`
   result. Ask Apple which development and Developer ID profile types support
   the grant. The [request text in the previous report](vela-native-touch-report-2026-11-06.zh-CN.md) can be adapted to the lab ID.
3. After approval, enable the capability for the lab App ID and generate a new
   profile in the route Apple authorizes. If **Mac App Development** is
   available for this grant, choose the lab App ID, a matching **Apple
   Development** signing certificate with its private key on this Mac, and the
   registered test Mac. Register an Apple silicon Mac using its provisioning
   UDID. For Developer ID, use a profile and a **Developer ID Application**
   certificate that Apple authorizes for this capability. Developer ID
   availability for this team and grant remains unverified. [Development profiles](https://developer.apple.com/help/account/provisioning-profiles/create-a-development-provisioning-profile), [Managed capability provisioning](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/), [Developer ID signing](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

## Sign an isolated development copy

From the repository root, build an isolated lab bundle with
`python3 scripts/build-touch-lab.py --control-without-hid-entitlement`.
Set these variables locally to the printed lab bundle path, the Apple-issued
development profile, and the matching installed Apple Development identity:

- `VELA_TOUCH_LAB_CONTROL`
- `VELA_TOUCH_LAB_PROFILE`
- `VELA_TOUCH_LAB_IDENTITY`

The commands below make a fresh lab copy, validate the profile's grant and App ID,
embed it in `Contents/embedded.provisionprofile`, and sign the executable through
its enclosing app. The existing lab packager can still reproduce the local
certificate comparison. [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles).

```sh
(
  set -eu
  : "${VELA_TOUCH_LAB_CONTROL:?}" "${VELA_TOUCH_LAB_PROFILE:?}" "${VELA_TOUCH_LAB_IDENTITY:?}"
  test "$VELA_TOUCH_LAB_IDENTITY" != '-'
  test "$(plutil -extract CFBundleIdentifier raw -o - "$VELA_TOUCH_LAB_CONTROL/Contents/Info.plist")" = app.aiomni.awakepet.touchlab
  vela_touch_tmp=$(mktemp -d)
  trap 'rm -rf "$vela_touch_tmp"' EXIT
  vela_touch_dir=$(mktemp -d "$PWD/.build/touch-lab/provisioned.XXXXXX")
  vela_touch_app="$vela_touch_dir/VelaTouchLab.app"
  ditto "$VELA_TOUCH_LAB_CONTROL" "$vela_touch_app"
  cp "$VELA_TOUCH_LAB_PROFILE" "$vela_touch_app/Contents/embedded.provisionprofile"
  security cms -D -i "$vela_touch_app/Contents/embedded.provisionprofile" -o "$vela_touch_tmp/profile.plist"
  python3 - "$vela_touch_tmp" <<'PY'
from pathlib import Path
import plistlib
import sys

directory = Path(sys.argv[1])
profile = plistlib.loads((directory / 'profile.plist').read_bytes())
allowed = profile['Entitlements']
hid = 'com.apple.developer.hid.virtual.device'
app = 'com.apple.application-identifier'
team = 'com.apple.developer.team-identifier'
expected_ids = {prefix + '.app.aiomni.awakepet.touchlab' for prefix in profile['ApplicationIdentifierPrefix']}
if allowed.get(hid) is not True or allowed.get(app) not in expected_ids or allowed.get(team) not in profile['TeamIdentifier']:
    raise SystemExit('The profile must authorize the HID entitlement and the exact lab App ID.')
(directory / 'claims.plist').write_bytes(plistlib.dumps({key: allowed[key] for key in (hid, app, team)}))
PY
  codesign --force --options runtime --timestamp=none --entitlements "$vela_touch_tmp/claims.plist" \
    --sign "$VELA_TOUCH_LAB_IDENTITY" "$vela_touch_app"
  codesign --verify --deep --strict --test-requirement 'anchor apple generic' "$vela_touch_app"
  printf '%s\n' "$vela_touch_app"
  "$vela_touch_app/Contents/MacOS/VelaTouchLab" --probe
)
```

The development signing commands are ready for the team's approved profile and
matching identity. They have not been run with an Apple-issued HID profile here.
The runtime probe must report both `virtualDeviceEntitlementPresent: true` and
`deviceCreated: true` before proceeding. For a Developer ID profile, use its
matching identity and secure timestamp (`--timestamp`).

## Verify gestures on the selected display

In an isolated desktop, use **Display → Add virtual display** in Vela's web
controller. Use a logical desktop of at least 800 × 600 so the entire lab window
fits. Keep the session attached to retain its display. Set `VELA_TOUCH_LAB_APP`
to the signed lab path printed above, then run the stages in order:

```sh
vela_touch_lab="${VELA_TOUCH_LAB_APP:?}/Contents/MacOS/VelaTouchLab"
"$vela_touch_lab" --receiver-only --vela-virtual-display --duration 2
"$vela_touch_lab" --activate-probe --vela-virtual-display --duration 5
"$vela_touch_lab" --run --vela-virtual-display --isolated-desktop --duration 15 --output NEW.json
```

The activation probe checks enumeration and a Feature Get round trip with zero
input reports. The live sequence sends system-wide HID input. Keep the isolated
desktop free of other input. A passing result records direct touch lifecycles
at the intended coordinates, movement of the standard AppKit scroll view during
the single-contact stage, and native magnification during the two-contact stage.
The receiver uses AppKit gesture recognizers to observe direct touches.
[Apple TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support).
