# Native remote touch through virtual HID — November 4, 2026

## Assessment

There is a concrete native-touch path worth a focused proof of concept. The best
candidate is an app-owned CoreHID virtual touchscreen, associated with Vela's
selected display, sending raw contact reports into the system. The open question
is whether WindowServer promotes such a third-party device into the macOS 27
direct-touch path used by AppKit. A working device or a moving mouse is not proof
of that promotion.

Directly copying Sidecar's private virtual-event-service path is a different
route. It requires a private event-dispatch entitlement documented in Apple's
source and present in the installed Sidecar agent. Finding its exported symbols
does not grant permission to use it.

No native-touch input was injected in this investigation. The result is a
feasibility assessment with local prerequisite evidence, not an end-to-end
demonstration or latency measurement.

## What was independently observed

The inspected host reports macOS 27.0.1, build 26A434. SDK declarations were read
from `/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk`.

The reproducible probe is `scripts/probe-native-touch.py`. Its captured output is
`Design/vela-native-touch-probe-2026-11-04.json`.

| Observation | Evidence strength | What it establishes |
| --- | --- | --- |
| IOKit exports digitizer-event construction, virtual-service creation/dispatch, and user-device creation/report APIs | Runtime symbol lookup | The APIs exist on this host; authorization and successful delivery are not established. |
| SkyLight exports `kSLSHIDEventTypeDirectTouch` and `SLSSidecarGestureEventsSupported` | Runtime symbol lookup | There is native direct-touch machinery, not merely Vela mouse emulation. Neither symbol was invoked. |
| SidecarDisplayAgent contains `TouchScreenDigitizer`, native-touch capability markers, and a display-UUID configuration diagnostic | Static binary inspection | The installed agent includes a screen-digitizer route and display-binding logic. |
| The agent imports `UniversalHID.HIDServiceProperties` setters for `cgDirectDisplayID`, `displayIdentifier`, and `displayIntegrated` | Imported symbol inspection | Display association is explicit in this implementation. A property name alone does not establish a supported third-party contract. |
| The agent imports both user-device report APIs and private virtual-service APIs | Imported symbol inspection | Multiple HID mechanisms coexist. Their presence does not prove which mechanism each contact uses. |
| The agent is signed with `com.apple.hid.manager.user-access-device`, `com.apple.iohideventsystem.server`, and private HID event-dispatch/monitor entitlements | Signature entitlement inspection | Apple's service operates with privileges beyond Vela's ordinary input-posting permission. |
| The probe found IOHIDResource, but opening its type-0 user client returned `0xe00002c2`, “invalid argument” | Actual open/close access probe | This process did not obtain a resource connection. The error alone does not diagnose the cause; it must not be relabeled as an entitlement-denied error. |

The last check calls no user-client methods, creates no HID device, and submits
no reports. Default probe execution omits even that access check. The probe does
not request TCC permission, read local signing configuration, sign binaries,
alter displays/power, capture the desktop, or inspect input events.

## Route A: Sidecar's private event-service mechanism

The installed agent imports `IOHIDVirtualServiceClientCreate`,
`IOHIDVirtualServiceClientDispatchEvent`, and `IOHIDEventCreateDigitizerEvent`.
Apple's `HIDVirtualEventService` header explicitly requires
`com.apple.private.hid.client.event-dispatch`. That requirement is independently
consistent with the agent's signature.

This is therefore not an API that can be adopted merely by loading IOKit with
`dlsym`. Do not add Apple's private entitlements to Vela's signature or alter
system services to obtain them. No ordinary third-party grant or broker accepting
Vela-authenticated contacts was established in this research.

Source: [Apple HIDVirtualEventService header](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/HID/PrivateHeaders/HIDVirtualEventService.h).

Private Sidecar session/configuration objects are less promising as the initial
integration point: they couple input to Apple's service, device/session
negotiation, and display configuration. They do not provide an established way
to attach Vela's browser peer. No request was sent to a Sidecar XPC service.

**Decision:** retain as implementation evidence, not the first production route.

## Route B: app-owned CoreHID touchscreen

Apple's public CoreHID API can emulate a peripheral and submit input reports.
`HIDVirtualDevice.Properties` accepts a report descriptor and `extraProperties`.
The underlying user-device SDK header requires
`com.apple.developer.hid.virtual.device`, and Apple's open kernel source checks
that entitlement or its privileged Apple counterpart before admitting the user
client. This is separate from Accessibility / Device Control consent.

Sources: [CoreHID virtual-device API](https://developer.apple.com/documentation/corehid/creatingvirtualdevices),
[HID virtual-device entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device),
[Apple resource-user-client authorization](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDResourceUserClient.cpp).

Vela would need a valid entitlement/provisioning setup for this route. No
Developer Portal request was submitted, no provisioning profile was changed or
read, and no conclusion is made about which capabilities the user's account can
obtain. A normal local build cannot be assumed to have this authorization.

Unlike a DriverKit extension, an app-owned device could live with Vela's remote
host and be destroyed with it. CoreHID therefore offers a way to investigate
without introducing a persistent daemon or installed driver. Switching to
DriverKit would add authorization, signing, activation, and lifecycle work; it
would not by itself prove WindowServer recognition of native touch.

### Why this is more than speculative symbol hunting

Apple's open `IOHIDEventDriver` parses touchscreen/finger digitizer elements and
can construct collection events containing multiple finger children. Its event
service source recognizes touchscreen usage and marks it display-integrated.
The generic stack therefore has building blocks for raw contacts.

Sources: [Apple digitizer report handling](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDEventDriver.cpp),
[Apple display-integrated usage handling](https://github.com/apple-oss-distributions/IOHIDFamily/blob/777ccd9698845aadf711e32d843c8c9b777431d9/IOHIDFamily/IOHIDEventService.cpp).

Those open-source revisions are not a claim of an exact match to the running
kernel. In particular, they do not document the closed WindowServer/AppKit
classification logic on macOS 27. An ordinary USB/virtual digitizer might still
produce generic pointer/tablet events, be ignored for direct touch, or require
additional service metadata. `extraProperties` is a possible carrier for mapping
properties, not proof that WindowServer accepts them from this device class.

Do not assume an Apple vendor/product identity, an `Authenticated` property, or
the name “Sidecar” makes a generic device equivalent to Apple's service. Establish
the minimal accepted descriptor and metadata using Vela's own device identity.

**Decision:** strongest candidate for a bounded prototype; native-touch promotion
and display mapping remain unproven.

## External reverse-engineering evidence

The `sidecar-touch-backport` repository was inspected at HEAD
`2441128f1df3f6e5ae3977de0ffba9cf35ac28ee`. Its investigation distinguishes old
and extended touch reports, capability negotiation, and device/display mapping.
It records a case where modified reports reached the host but native touch still
failed, together with a WindowServer display-association failure. The current
tweak sets the outgoing display-capability mask to 2; the checked-in notes stop
at proposing that value as the next experiment.

These are the author's observations, not independently reproduced here. Neither
the README's success claim nor a capability-mask change proves standalone
third-party virtual-HID support. The implementation is an iPad system-extension
tweak, not a library Vela can use in its browser client.

Sources: [Author's investigation notes](https://github.com/joshrad-dev/sidecar-touch-backport/blob/2441128f1df3f6e5ae3977de0ffba9cf35ac28ee/sidecar-ipados16-vs-27-notes.md),
[Author's tweak](https://github.com/joshrad-dev/sidecar-touch-backport/blob/2441128f1df3f6e5ae3977de0ffba9cf35ac28ee/Tweak.x).

## Minimal proof that would settle the question

The prototype should test this pipeline:

`authenticated browser contacts → Vela → virtual touchscreen → display binding → AppKit recognizers`

1. Use an isolated native test window with a standard scroll view and native
   click/pan/magnification recognizers. Record only generated contact IDs,
   phases, coordinates, recognizer results, and the test display association.
2. After valid HID authorization is available, create an inactive app-owned
   touchscreen with its own identity. Verify enumeration, descriptor parsing,
   and display binding before enabling reports. Start with an existing display;
   prove Vela's CGVirtualDisplay separately rather than assuming equivalence.
3. Deliver a deterministic one-finger contact lifecycle inside the test window.
   The success criterion is a direct `NSTouch` received by the native gesture
   path and correct standard-control behavior, not a `CGEvent` mouse click.
4. Verify one-finger scrolling, a two-contact pinch, contact cancellation, and
   coordinates on a non-main display. Repeat with HiDPI, a negative display
   origin, and a Vela virtual display.
5. Verify that cancellation/removal leaves no active contact; then test network
   loss and session transitions. Keep lock-screen input on the existing password
   interface and existing input path until separately accepted.

Apple states that Sidecar direct touches do not appear in ordinary event monitors
or application/window event dispatch. Consequently, a global CGEvent tap is not
a valid native-touch acceptance observer. Use recognizers in the receiving app.
Source: [Apple TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support).

If the device enumerates and raw digitizer events exist but no direct touches
reach AppKit, investigate WindowServer classification/display association before
building more browser UI. If native touch requires Apple-only privileges, treat
that as a product constraint rather than disguising mouse emulation as success.

## Necessary Vela integration work if the prototype succeeds

- The browser must transmit raw contact identity, phase, position, display ID,
  sequence, and session/display generation. Current `RemoteInput` only carries
  pointer/scroll/key/text/release. This is contact transport and validation;
  gesture interpretation would be delegated to macOS.
- Start the prototype with one bounded reliable ordered contact stream. Current
  non-retransmitted pointer moves must not reorder contact starts/ends or mix
  generations during display replacement. Preserve terminal/cancel messages and
  cancel safely on congestion rather than replaying stale touches.
- Normalize contacts against the actual source-picture rectangle, accounting for
  fit/letterboxing and local zoom/pan. Do not equate CSS pixels, capture pixels,
  and Mac desktop points.
- Disable current browser mouse/scroll gesture conversion for contacts sent to
  the native path. Decide explicitly how local picture inspection is invoked so
  the browser and Mac do not both act on the same pinch.
- Gate device activity by the authenticated controller, session validity,
  selected display, current console state, input permission, and view-only mode.
  Cancel all contacts on blur, disconnect, lock/account change, and display
  change. Use a host watchdog as well as browser cancellation.
- Prove how generated HID events are distinguished from physical input before
  combining the feature with blackout or Agent input policies. Current
  `DesktopInput.post` tags Quartz events; blackout recovery also checks source
  PID, and `PhysicalInputMonitor` treats PID 0 as physical. Native HID and system
  mouse emulation may not preserve the existing tags. Both false local-input
  classification and invisible real physical input must be excluded.
- Gate the intended macOS 27 touch behavior by runtime capabilities. Continue
  the existing mouse/trackpad route on macOS 26; CoreHID availability alone does
  not imply the newer AppKit semantics.

If this route succeeds, the browser's device type need not be an Apple Sidecar
peer: a phone or another tablet could send the same authenticated contacts.
That is an architectural possibility, not verified iPhone acceptance. It would
reuse native touch interpretation, not Apple's on-device Sidecar controls,
Pencil-specific client features, or media transport.

## Validation performed and limits

- Inspected Apple documentation/source, SDK declarations, installed system
  binary imports/markers, signature entitlement keys, and runtime exports.
- Ran `python3 scripts/probe-native-touch.py --check-hid-access` and saved the
  result. Checked the script's syntax and verified that its default mode omits
  the resource access operation. No access check is treated as touch acceptance.
- No device registration, contact injection, real input monitoring, Sidecar
  connection, TCC prompt, display/power change, driver installation, signing
  modification, or production-code change was performed.
- No native-touch test app or end-to-end prototype was built. The initial
  `xcrun --show-sdk-version` command failed to locate its SDK; subsequent work
  read the explicit SDK path and used a Python probe. No build validation is
  claimed. Full application tests are unnecessary for these standalone research
  artifacts and were not run.

The deliverable is a specific prototype target with two explicit gates:
authorized virtual-HID creation, then native direct-touch recognition on the
selected display. Only passing the latter establishes the capability the user
requested.
