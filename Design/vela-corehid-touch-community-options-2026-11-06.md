# Community options for the CoreHID authorization gate — November 6, 2026

## Bottom line

The community supplies useful virtual-HID implementations and a more concrete
**Virtual HID entitlement request route**, but this search found no reproducible
normal-security, profile-free, software-only way to deliver native AppKit direct
touch on current macOS.

A physical USB HID bridge is a genuinely different architecture that avoids the
Mac app creating a virtual HID device. It does **not** establish native AppKit
recognition or display binding; a community experiment on exactly macOS 27.0.1
build 26A434 reached digitizer enumeration but still failed native touch.

This is read-only community research, not another live injection experiment.
No certificate, provisioning profile, keychain trust, SIP/AMFI setting, feature
flag, driver, display or power state was changed. The only local command was
`hidutil help` (and working-directory inspection). No project implementation was
changed in this research round.

## 1. Exact same error: a concrete request route exists

The [Stack Overflow CoreHID question](https://stackoverflow.com/questions/79839945/what-are-the-requirements-for-generating-a-hidvirtualdevice-on-macos)
(December 6, 2025) describes the same progression: unsigned SwiftPM executable
initializes `HIDVirtualDevice` as nil; adding the Boolean virtual-HID entitlement
and signing with an Apple Development certificate causes immediate termination.

The [accepted answer](https://stackoverflow.com/a/79840890) (December 8, 2025)
quotes **`AppleMobileFileIntegrityError -413: No matching profile found`** and
points to the [Apple request form](https://developer.apple.com/contact/request/system-extension/),
selecting **Virtual HID** as the entitlement kind. It provides a
[form screenshot](https://i.sstatic.net/gb2UQdIz.png). This is guidance for the
exact public CoreHID key, not merely an assumption based on DriverKit naming.

The question/answer were retrieved through the public Stack Exchange API
([question](https://api.stackexchange.com/2.3/questions/79839945?site=stackoverflow&filter=withbody),
[answer](https://api.stackexchange.com/2.3/questions/79839945/answers?site=stackoverflow&filter=withbody)).
The answer is community advice (accepted, score 1), not proof of approval or
Apple's current grant policy. The Apple form redirects to sign-in; no account was
opened and its authenticated contents were not inspected.

A more recent near-target example is
[Topti's April 2, 2026 investigation](https://github.com/Yukaii/topti/blob/main/docs/investigations/2026-04-02-corehid-entitlement.md).
It is a CoreHID virtual stylus/digitizer project. The author records selecting
**HID Virtual Device**, submitting the request and receiving Apple's
review-status acknowledgment. Its current [README](https://github.com/Yukaii/topti)
still lists the virtual stylus path as blocked while awaiting authorization.
This demonstrates a requestable route in the author's account, **not** completed
approval, a guaranteed grant, or successful native touchscreen delivery.

[macgip's entitlement note](https://github.com/leetrout/macgip/blob/main/notes/entitlements.md)
(October 11, 2026) describes a Portal route:
Certificates, Identifiers & Profiles → Identifiers → the App ID → Capability
Requests → virtual HID device → Request. After approval it says to enable the
capability and regenerate eligible profiles. The note assigns this to the Account
Holder. Apple documents the general
[Capability Requests mechanism](https://developer.apple.com/help/account/capabilities/capability-requests).
The exact capability visibility and grant eligibility for Vela's team remain
unverified. The note contains other DriverKit claims that should not be adopted
without checking current SDK/docs; only its CoreHID request route is useful here.

### Consequence for Vela

Request `com.apple.developer.hid.virtual.device` / Virtual HID specifically for
Vela's app-owned, authenticated remote-contact use. Do not reuse Topti's submission
text claiming no remote-control functionality: that would misrepresent Vela.
Keep the application description accurate about authentication, explicit enable,
bounded input, cancellation and no lock/account bypass.

This improves the previous generic “ask Developer Support” guidance by providing
an exact community-used form category and Portal route. Approval timing,
Developer ID eligibility and the user's account-specific process are still not
established.

## 2. Can normal development signing avoid the profile?

No verified current-stock-macOS example was found in this search. The local
[matched experiment](vela-corehid-touch-signed-comparison-2026-11-06.json) remains
specific to the existing local certificate with hardened runtime enabled. It must
not be generalized into a proof that every possible signing mode behaves identically.

However, community evidence argues against “just remove hardened runtime” or
“just obtain any Apple certificate” as a known solution:

- The Stack Overflow question's posted `codesign` invocation does not request
  hardened runtime, yet its signed executable is killed with the same profile
  error. Prior signature flags were not independently measured, so this is not
  conclusive proof about an un-hardened binary.
- [ControlDeck's actual spike record](https://github.com/ViniZap4/ControlDeck/blob/46151468605ba4d9e5c6378079bb56cd3c934333/spikes/VirtualPadSpike/README.md)
  reports both ad-hoc signing and a bare Apple Development certificate without a
  granting profile being killed on macOS 26.5. Its
  [run script](https://github.com/ViniZap4/ControlDeck/blob/46151468605ba4d9e5c6378079bb56cd3c934333/spikes/VirtualPadSpike/run.sh)
  is retained to reproduce failure, **not** a working workaround.
- [OpenLogi issue 1917](https://github.com/AprilNEA/OpenLogi/issues/1917) reports an
  entitlement-claimed ad-hoc process killed on macOS 26.7, while unsigned and
  root processes return nil from user-device creation. The proposed route is a
  profile authorizing the agent. The author also reports Logi Options+ using a
  Developer ID profile granting the exact key; this installed-vendor inspection
  was not reproduced here.
- [HIDTouch](https://github.com/koshi545/HIDTouch) explicitly separates local
  certificate signing for stable TCC identity from its still-blocked virtual
  digitizer path. Its self-signed-certificate instructions do **not** grant HID
  creation authorization.

Topti's investigation also **attributes** to Apple DTS
[forum thread 820708](https://developer.apple.com/forums/thread/820708) that virtual
CoreHID has no development-only entitlement variant and CoreHID is preferred over
DriverKit. Direct forum retrieval hit human verification; that was not bypassed.
Treat this as the author's sourced summary, not as a primary reply independently
read in this session.

Apple's [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
explains unrestricted versus restricted macOS entitlements and the profile
allowlist requirement. The public [HID key reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device)
still does not spell out the exact approval process.

No normal signing variant was changed or executed in this research round. Search
absence is not a proof of universal impossibility, but there is insufficient
evidence to recommend a profile-free development route.

## 3. Existing signed community driver: Karabiner

[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/55b60bd86f0fb57119ae1730fce9ba1e11f892c0/README.md)
(package 8.7.0 at the inspected snapshot) explicitly supports macOS 27 Apple
Silicon. It distributes a signed DriverKit device service, daemon and client.

But the [client API](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/blob/55b60bd86f0fb57119ae1730fce9ba1e11f892c0/include/pqrs/karabiner/driverkit/virtual_hid_device_service/client.hpp)
contains typed keyboard/consumer/vendor/top-case/generic-desktop/pointing reports,
not arbitrary report-descriptor upload or touchscreen digitizer reports.

- User-approved system extension and installation are required.
- The service daemon and its clients require root.
- A custom digitizer fork requires driver, protocol and daemon changes plus
  appropriate signing/DriverKit authorization; modified binaries cannot inherit
  upstream's signature/profile grant.
- This introduces a privileged persistent component, contrary to the original
  lightweight app-owned prototype.

It is a possible **keyboard/mouse fallback**, not a drop-in native-touch broker.
No driver was downloaded or installed. Top-level licensing is public-domain /
Unlicense, while the client header retains a Boost Software License notice;
component notices must be preserved if code is reused.

## 4. Physical USB HID proxy: avoids only virtual-device creation

A board with native USB device support, such as RP2040/RP2350 or ESP32-S2/S3,
could receive the remote contact stream and present a physical HID digitizer to
the Mac. Vela would not call CoreHID to create a virtual peripheral.

[TinyUSB](https://github.com/hathach/tinyusb) (MIT) supports these device families.
Its [generic HID descriptor callback](https://github.com/hathach/tinyusb/blob/master/examples/device/hid_generic_inout/src/usb_descriptors.c)
and [raw HID report transport](https://github.com/hathach/tinyusb/blob/master/src/class/hid/hid_device.c)
provide the building blocks. This is a proposed hardware architecture, not an
implemented or native-touch-accepted Vela prototype. Physical accessory and
connection policies still apply.

A particularly relevant counterexample is
[macos27-external-touch's evidence](https://github.com/glasses666/macos27-external-touch/blob/main/EVIDENCE.md)
on **the same macOS 27.0.1 / build 26A434**. The author used a rooted Android tablet
as a USB HID gadget with a touchscreen descriptor:

- It enumerated as a digitizer with `DisplayIntegrated` after an unsupported
  private feature flag was enabled and the Mac rebooted.
- `NSScreen.touchCapabilities` changed to MultiTouch.
- WindowServer still rejected it for **no usable `displayUUID`**.
- Device/service property setters reported success but did not make the value
  available to the event-service/WindowServer path.
- Even the author's SIP-disabled debugger experiments did **not** produce native
  touch. The published record intentionally does not include those procedures.

Those are community observations, not local reproduction. The claim that the
property is provider/driver-owned is the author's inference; it does not prove a
DriverKit driver or a creation-time CoreHID property will solve it.

Thus a physical bridge can separate the authorization gate from the native
classification gate, but is **not** a demonstrated solution for native AppKit
touch. Do not treat USB enumeration, capability flags or property echoes as
success. No private feature flag was changed here.

## 5. Things that look like solutions but are not

- **Built-in `hidutil`:** local `hidutil help` lists only help, dump, property and
  list. There is no create-device or dispatch-report command on this host.
- **Apple's user-device test source:**
  [IOHIDUserDeviceTest.c](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/tools/IOHIDUserDeviceTest.c)
  includes touchscreen descriptors, but its main is gated on internal security
  policies, and its [entitlements](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/tools/IOHIDUserDeviceTest-Entitlements.plist)
  claim Apple's privileged user-device access. It is descriptor reference, not a
  public authorized relay.
- **CGEvent touch drivers:** HIDTouch's working output is mouse/scroll emulation;
  its experimental undocumented magnify-event encoding does not deliver raw
  direct NSTouch and requires interpreting gestures in the sender. That is not
  the original raw-contact → native-system-gesture goal.
- **“Team selection automatically fixes it” tutorials:** ControlDeck's older
  scope table says no approval wait/runtime prompt, while the later actual
  [Phase 0 record](https://github.com/ViniZap4/ControlDeck/blob/46151468605ba4d9e5c6378079bb56cd3c934333/VIRTUAL_CONTROLLER_SCOPE.md)
  contradicts it with a hard profile gate. Prefer observed results over tables.
  Another search result used nonexistent `HIDVirtualDevice.error/deactivate` APIs;
  it is not a reliable executable recipe.
- **Disabling SIP/AMFI:** some community gamepad experiments depend on reduced
  security. That is not a normal signing solution, not demonstrated native touch,
  and not appropriate to execute on the existing Vela development desktop. No
  instructions or unknown scripts were run.

## Recommended next action

1. Keep CoreHID as the software prototype and use the now-concrete Virtual HID
   request route. Approval alone still does not prove direct touch: repeat the
   no-input activation/feature ladder, then isolated native receiver acceptance.
2. If avoiding Mac virtual-HID authorization is a hard requirement, consider a
   separate physical USB bridge investigation **with explicit hardware scope**;
   budget for unresolved display association/native classification, not just
   report encoding. Do not promise a software-only phone/tablet solution from it.
3. Retain Vela's existing authenticated pointer/scroll fallback while these gates
   are unresolved. Do not relabel mouse emulation or synthetic magnify as native
   direct-touch success.

Research limits: Google returned no useful body; GitHub code search requires
sign-in and some public API calls were rate-limited. Public issue search,
Stack Exchange API, raw repository files and DuckDuckGo were used instead. Apple
forum verification and form sign-in boundaries were respected. Sources with
current-main links may evolve; pinned ControlDeck/Karabiner snapshots are cited
where available. No community claim was promoted to local macOS acceptance.
