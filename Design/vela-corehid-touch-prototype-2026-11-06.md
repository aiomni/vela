# CoreHID virtual touchscreen prototype — November 6, 2026

## Result

**The minimum prototype is implemented and builds. The actual CoreHID creation
attempt returned `nil`, and the executing prototype process does not possess
`com.apple.developer.hid.virtual.device=true`. No device was activated, no contact
report was submitted, and native AppKit touch/gesture delivery remains unproven.**

This is a more direct prerequisite test than the historical resource-user-client
open probe: it calls the public `HIDVirtualDevice(properties:)` initializer with a
real touchscreen descriptor. The initializer is failable, not throwing, and
exposes no underlying `IOReturn`. Do not label its `nil` as a specific kernel
error or assume the absent entitlement is the only possible failure cause. The
absent entitlement is independently established by `SecTask` on this process.

The host reports macOS 27.0.1, build 26A434. SDK API inspection used the installed
Command Line Tools macOS 27.0 SDK; the repository's `swift build` invocation used
Xcode's macOS 27.2 SDK, targeting macOS 26. Native live sequence mode explicitly
requires macOS 27. No dependencies or production signing rules were changed.

Captured evidence:

- [Actual device-creation probe](vela-corehid-touch-probe-2026-11-06.json): exit 2,
  entitlement absent, initialization `nil`, activation false, reports 0,
  direct touches 0, native acceptance false.
- [Receiver-only smoke](vela-corehid-touch-receiver-2026-11-06.json): exit 0,
  AppKit receiver and touch-scrolling configuration created; no HID device,
  reports 0, direct touches 0, native acceptance false. It opened and closed a
  three-second temporary window; this is not touch delivery or visual acceptance.

The two invocations selected different existing displays because `NSScreen.main`
is focus-dependent. The probe's display had a negative desktop origin; that
metadata is not a passed negative-origin touch mapping test. Use explicit
`--display-id` for later controlled comparisons.

## Implementation

The separate `VelaTouchLab` SwiftPM executable is never started by Vela's normal
startup, is not packaged into the production app by the existing build script,
and has no remote-host/protocol dependencies.

- [TouchscreenReport](../Sources/TouchLabCore/TouchscreenReport.swift): independent
  two-finger parallel touchscreen HID descriptor, report validation and encoding.
  Digitizer page `0x0D`, Touch Screen usage `0x04`, two Finger logical collections;
  each contains Tip Switch, In Range, Confidence, Contact Identifier and absolute
  16-bit X/Y. Input report 1 is 14 bytes including ID; feature report 2 is two
  bytes including ID and advertises maximum contact count 2. Coordinates use
  top-left display-normalized `[0,1]`, not browser pixels or desktop points.
- [VirtualTouchscreen](../Sources/VelaTouchLab/VirtualTouchscreen.swift): public
  CoreHID creation/activation/input reports, signature entitlement readback,
  filtered own-device enumeration and bounded JSON evidence. Feature callbacks
  return full `[2,2]` reports and throw only `HIDDeviceError`. Own identity uses
  unassigned laboratory vendor ID 0 and product ID 1, never Apple's identity.
- [TouchReceiver](../Sources/VelaTouchLab/TouchReceiver.swift): a temporary window
  with shared `VelaScrollView`, native one-finger touch scrolling and an
  `NSMagnificationGestureRecognizer`. All recognizers explicitly allow `.direct`.
  A passive root-ancestor recognizer observes all four touch lifecycle callbacks
  without preventing standard control recognizers. Trackpad/mouse recognizer
  actions alone never establish direct-touch success.
- [Lab entry point](../Sources/VelaTouchLab/main.swift): distinct probe,
  receiver-only and explicitly isolated live modes; stage sequencing,
  focus/console/display/geometry checks, cancellation and process cleanup.
- [Report unit tests](../Tests/TouchLabCoreTests/TouchscreenReportTests.swift): byte
  layout, independent HID short-item bit/collection walk, malformed input,
  terminal release identity/position, mixed releases and feature request handling.

A lift retains the contact ID, last coordinates and Confidence while clearing
Tip/In Range. Contact Count includes every valid record **including a lift**;
only the following empty scan has count zero. These parallel-report semantics
follow the [published touchscreen HID guidance](https://learn.microsoft.com/en-us/windows-hardware/design/component-guidelines/touchscreen-required-hid-top-level-collections).
That is descriptor guidance, not a claim that WindowServer accepts this descriptor.

Full feature-report prefix handling is consistent with Apple's underlying
[IOHIDDevice report processing](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDDevice.cpp)
and [user-device callback implementation](https://github.com/apple-oss-distributions/IOKitUser/blob/main/hid.subproj/IOHIDUserDevice.c).
An authorized own-device feature roundtrip is still required; no live feature
roundtrip was possible here.

## Reproduce without contact injection

Run from the repository root:

```sh
swift build -c debug --product VelaTouchLab
swift test --filter TouchLabCoreTests
BIN_DIR="$(swift build -c debug --show-bin-path)"
"${BIN_DIR:?}/VelaTouchLab" --probe
"${BIN_DIR:?}/VelaTouchLab" --receiver-only --duration 3
```

`--probe` attempts real initialization but never calls `activate`, sends reports,
opens a window or requests TCC. Successful object creation would still be distinct
from kernel enumeration and native touch acceptance. `--receiver-only` creates no
HID device and injects no input. Optional `--output NEW.json` saves JSON in a new
file; the final write also refuses overwrite, not merely the initial path check.

The local build output resolved to `.build/out/Products/Debug`. Use
`--show-bin-path`, rather than assuming `.build/debug` on every build backend.
See [the validation instructions](../TESTING.txt) for modes and exit codes.

## What authorization is actually required

### Established requirement

The device-creating executable must actually hold this Boolean code-signature
entitlement:

```xml
<key>com.apple.developer.hid.virtual.device</key>
<true/>
```

[Example entitlement plist](vela-corehid-touch-entitlements.example.plist) is
reference material only. It is **not** integrated into signing, is not a profile,
and does not confer authority merely by existing in the app bundle or repository.
The entitlement belongs to the process that calls CoreHID. Granting it only to an
outer wrapper or a different executable does not authorize the creator.

Sources: [Apple entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device),
[CoreHID virtual-device guide](https://developer.apple.com/documentation/corehid/creatingvirtualdevices),
and [Apple's resource-user-client entitlement check](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDResourceUserClient.cpp).
The local public user-device SDK header also states this entitlement requirement.
The pinned open kernel source is not asserted to be an exact running-kernel match.

Device Control / Accessibility, Input Monitoring, Screen Recording, administrator
credentials and an `NSIsTouchNative` plist key are **not substitutes** for this
signed virtual-HID entitlement. This prototype did not request or modify any of
those permissions. Future authorized runtime failures should be diagnosed as
observed, not preemptively assigned to a TCC category.

### Provisioning and grant availability: verify, do not assume

The exact CoreHID key's public reference specifies Boolean type but contains no
managed-capability classification, approval form, supported certificate types,
or development/Developer ID/App Store provisioning procedure. The public CoreHID
article also omits those signing steps. Consequently, this investigation does
**not** establish that Apple-managed approval is mandatory, that the key is
freely selectable, or that Developer ID distribution supports it for this account.

Apple's general [provisioning guidance](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
states that unrestricted macOS entitlements can work without profiles, while
restricted entitlements require a profile allowlist. If Apple treats this key as
restricted for the intended signing route, the Apple-issued profile must authorize
it and match the App ID/team/certificate/signature. macOS app profiles use
`Contents/embedded.provisionprofile`; a loose executable is not a substitute for
an appropriate profile-bearing app container. Do not claim this exact key requires
such a profile without confirming its classification.

For a genuinely managed capability, Apple's [managed-capabilities procedure](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/)
is approval, enabling on the eligible App ID, then generating eligible profiles.
That general procedure does not itself classify the CoreHID key.

### Concrete next steps for the team/account holder

1. Check the team's Developer Portal App ID / Xcode capability options for this
   **exact CoreHID entitlement**. Preserve Vela's production App ID
   `app.aiomni.awakepet`. An isolated signed lab can use a separate team-owned test
   App ID; do not change either shipped compatibility identifier.
2. If not exposed or its profile/distribution support is unclear, contact
   [Apple Developer Support](https://developer.apple.com/support/) with the exact
   question below. Ask whether approval is required, how to enable it, and which
   signing/profile routes support it; do not silently substitute DriverKit.
3. Once legitimate authorization is available, sign an isolated lab app with the
   team's existing signing workflow and any required authorized profile. Include
   its localization resource bundle if packaging it as an app. Verify the
   executing binary's actual entitlement and signature, then repeat `--probe`.
   Do not replace certificates, ad-hoc re-sign shipped apps, edit profile contents,
   disable security controls, or add Apple-private entitlements as a workaround.

Suggested support inquiry:

> We are prototyping an app-owned virtual touchscreen using the public CoreHID
> HIDVirtualDevice API on macOS 27. The application is Vela, production App ID
> app.aiomni.awakepet. The creating process needs the Boolean entitlement
> com.apple.developer.hid.virtual.device=true. Our local prototype currently lacks
> that signed entitlement and HIDVirtualDevice initialization returns nil. Is this
> entitlement restricted or managed for development and Developer ID distribution?
> If approval is required, which request procedure should our team follow? Which
> certificate/profile combinations support it, and should it be enabled on our App
> ID and included in a macOS provisioning profile? We need an app-owned CoreHID
> device, not a DriverKit extension or Apple-private HID event-dispatch permission.

The **different** [DriverKit virtual-HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.family.hid.virtual.device)
explicitly has a request-form procedure. It is not the authorization used by this
CoreHID prototype. Neither DriverKit installation nor private Sidecar event-service
entitlements are currently needed for the chosen prototype architecture.
No Portal request, profile/certificate change or signing operation was performed.

## Live acceptance once creation is authorized

**HID reports are system-wide input, not window-scoped events.** Experimental
`DisplayIntegrated`, `CGDirectDisplayID` and `DisplayIdentifier` properties are
supplied, and their registry values are observable, but no supported third-party
WindowServer binding contract has been established. Property echo cannot prove
where the very first contact lands; a bad binding can affect unrelated UI before
a focus-loss guard reacts. Use an isolated, non-sensitive desktop with the test
window visible. Live mode requires an explicit `--isolated-desktop` acknowledgment.

```sh
"${BIN_DIR:?}/VelaTouchLab" --run --isolated-desktop --duration 15 --output NEW.json
# Optional: --display-id ID for an already existing test display.
```

The sequence is one-finger scroll, two-finger pinch, then a final contact/lift
release test: four contact lifecycles total. Success requires:

- Four direct `NSTouch` starts and four ends, no cancellation or pending native
  contact; one lifecycle in scroll, two in pinch, one in final release.
- Per-stage begin/move/end coordinates matching the submitted trajectories within
  20 logical points, including sufficient movement samples in scroll and pinch.
- The standard scroll view's content origin changes during the scroll stage.
- A native magnification recognizer changes magnitude during a direct-touch
  pinch stream; ordinary trackpad magnification does not count.
- Successful terminal/empty cleanup report submission; failure cannot leave the
  acceptance flag true.

Apple's [TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support)
explains why ordinary event monitors, responder-chain touch handlers and
`NSApp`/`NSWindow.sendEvent` cannot observe Sidecar direct touches. The receiver
uses recognizers instead. `NSIsTouchNative` is an opt-out of mouse emulation for
embedded non-AppKit frameworks, not a required AppKit opt-in or HID entitlement.

AppKit does not expose authenticated report-source provenance here. Coordinate
and lifecycle correlation narrows false positives but is not cryptographic
attribution; no physical mouse/trackpad/direct-touch input is permitted during the
controlled run. Do not promote a contaminated result to acceptance.

Focus, console, screen, window geometry or timeout changes cancel the sequence.
Cleanup attempts terminal lifts and an empty scan; HID cancellation is not an
explicit `NSTouch.cancelled` command. The asynchronous main-actor watchdog cancels
stalled tasks and exits the process after a grace period, closing its user client.
It is not an independent watchdog for a synchronous main-thread/kernel stall.
Emergency teardown is recorded without claiming native lift delivery.

## Validation and remaining limits

- `swift build -c debug --product VelaTouchLab`: passed after correcting Swift
  CF ownership and Objective-C identity bridging errors.
- `swift test`: passed with one explicitly optional browser-harness test skipped.
- `swift test --filter TouchLabCoreTests`: all six focused tests passed after the
  final build, including descriptor layout, mixed terminal lifts and feature
  responses/invalid requests.
- `python3 scripts/check-localization.py`: passed; native/web catalogs identical.
- `python3 scripts/check-companion.py`: passed; original companion assets intact.
- Entitlement example passes `plutil -lint`; patch passes `git diff --check`.
- Actual CoreHID creation probe and receiver-only smoke results are linked above.

No authorized device activation, kernel descriptor parsing acceptance, live
feature readback, raw digitizer report submission, native scroll/pinch acceptance,
Vela virtual-display binding, network contact transport, mixed physical-input
handling, lock-screen interaction, driver installation, display/power change or
production package/signature modification was established. The receiver is ready
for that next authorized experiment; these tests do not manufacture that outcome.
The historical [November 4 research](vela-native-touch-research-2026-11-04.md) and
[probe](vela-native-touch-probe-2026-11-04.json) remain unchanged.
