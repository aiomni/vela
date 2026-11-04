# Sidecar-style mobile mode feasibility — November 4, 2026

Follow-up: [Native touch through virtual HID](vela-native-touch-research-2026-11-04.md)
adds local macOS 27 prerequisite evidence and a more specific prototype target.

## Clarified requirement and decision

The requested feature is reuse of Apple's actual Sidecar interaction machinery,
not a Vela implementation of similar controls. The custom browser-workspace
proposal below does not satisfy that clarified requirement.

**An actual nearby Mac-to-iPad Sidecar session provides system interaction. A
Vela browser session cannot currently acquire it through a documented public
Sidecar integration API found in this investigation.** This is an assessment of
the supported integration surface, not proof that private experimentation is
technically impossible.

Apple documents expanded touch support for macOS 27 and iPadOS 27. Importantly,
this is a native AppKit input path, not just a sidebar graphic: gesture
recognizers receive direct Sidecar touches. AppKit can also emulate mouse,
scroll, magnify, and rotate behavior for third-party UI frameworks. Apple's
technote says those touches bypass local/global event monitors and ordinary
application/window event dispatch. Its APIs let a Mac application consume touch
from an already-connected Sidecar iPad; the technote does not expose a way to
make browser touches into system Sidecar touches or embed the Sidecar client.
[Apple TN3212](https://developer.apple.com/documentation/technotes/tn3212-adopting-gesture-recognizers-for-sidecar-touch-support)

The supported scenarios therefore differ:

| Scenario | Direct reuse of system Sidecar |
| --- | --- |
| Compatible nearby iPad and Mac, using Apple's own Sidecar session | Yes; the system owns the display/input path. Vela can coexist or provide guidance. A supported programmatic connection API has not been established here. |
| iPad opens Vela's remote webpage | No documented API found to attach that webpage's video and input to the system Sidecar client. |
| iPhone opens Vela | Outside Apple's documented Sidecar device support. |
| Internet access to a distant Mac | Outside Apple's documented Sidecar connection model; Vela's WebRTC session does not become a Sidecar session. |

Apple requires the same Apple Account with two-factor authentication. Wireless
Sidecar requires proximity within 10 metres and Wi-Fi, Bluetooth, and Handoff;
USB requires the iPad to trust the Mac. These are material constraints on the
original remote-browser goal.
[Apple Sidecar requirements](https://support.apple.com/en-us/102597)

If reuse across Vela's existing transport is essential, the next research topic
would be whether an authenticated host can admit remote touch contacts into
macOS's native touch pipeline, including display association and AppKit gesture
recognizers. That would be a separate feasibility experiment; no supported
global injection API or working method was established in this review. It
would still require a client touch transport and would not automatically import
Apple's iPad client UI or its media pipeline. Do not promise Sidecar-equivalent
behavior or latency on that basis.

Recommendation for the clarified request: use native Sidecar for the supported
nearby-iPad case. Do not start the custom browser mode described below under the
assumption that it meets the request. A private Sidecar/HID investigation needs
its own scope and compatibility evidence before an implementation decision.

This is an engineering assessment from source inspection and primary-source
research, not a working prototype or device acceptance. No production code,
dependencies, installed applications, displays, power state, or input state were
changed during this investigation. The workspace already contained unrelated
uncommitted changes; those were left in place.

## Earlier alternative: custom mobile workspace (outside the clarified scope)

The remaining sections preserve the initial assessment of Vela's existing
building blocks and a custom mobile interface. They are background material,
not the recommended implementation for the clarified direct-reuse requirement.

### What the earlier proposal meant by “Sidecar”

There are three independent choices:

- **Interaction:** the existing desktop interface or a mobile workspace with
  direct touch / trackpad input, compact controls, and keyboard access.
- **Display:** view an existing Mac screen or create an extended virtual screen.
- **Privacy:** the existing physical-display and session controls, explicitly
  selected independently of the mobile interface.

Changing the interaction profile should release held input and preserve the
current authenticated media session, selected screen, quality, unfinished text,
and picture position. Creating a screen is a separate host operation.

A virtual display extends the same logged-in desktop. It does not create another
macOS account, a separate application session, or independent mouse/keyboard
focus. Local and remote activity can interfere. Existing single-controller
restrictions still apply. Viewing an existing display provides a mirrored view;
creating a virtual display provides an additional desktop area.

Apple's current Sidecar documentation also deserves a version distinction:
expanded direct touch interaction is documented for iPadOS 27 with macOS 27;
earlier systems expose a more limited set of finger gestures. Vela's own
touch-to-mouse implementation can serve its macOS 26 baseline independently.
Apple Sidecar is an iPad feature; Vela's phone interface would be Vela's own
experience. [Apple Sidecar documentation](https://support.apple.com/en-us/102597)

## Existing implementation and remaining work

| Capability | Evidence in this checkout | Implication |
| --- | --- | --- |
| Encrypted media and input | `Sources/RemoteRTC/RemotePeer.swift`; `Sources/RemoteServer/RemoteHostService.swift` | Keep the current connection/authentication model. Reliable controls and non-retransmitted pointer movement already have separate channels. |
| Extended virtual screen | `Sources/RemoteRTC/VirtualDisplay.swift`; `Sources/RemoteDisplayBridge/RemoteDisplayBridge.m` | Screen creation and placement to the right of existing displays already exist. This is the core second-display mechanism. |
| Safe virtual-screen replacement | `RemoteHostService.configureVirtualDisplay`, `removeVirtualDisplay`, and `disconnect` | Existing code verifies a first frame before committing replacement and retains recovery ordering. Reuse it. |
| Direct touch / trackpad | `Sources/RemoteServer/Web/app.js`, `touchStart`, `touchMove`, `touchEnd` | Both modes already map to validated mouse input. The default is currently trackpad. |
| Picture zoom and pan | `app.js`, `startTouchPair` / `updateTouchPair`; `Tests/WebClient/pinch.browser.js` | Pinch enlarges the local picture. At Fit, parallel two-finger motion scrolls remotely; after enlargement it pans locally. |
| Desktop navigation | `app.js`, `desktopAction`; `Tests/WebClient/touch-gestures.browser.js` | Existing buttons and four-finger shortcuts can be reused; visible buttons remain necessary when the OS takes gestures. |
| Keyboard and shortcuts | `app.js`, keyboard rows, modifiers, shortcuts, and `text-form`; `index.html` | On-screen keys and committed Unicode text already exist. Chinese input currently uses a local text field plus Send, rather than transparent remote composition. |
| Side panels | `app.js`, `mousePanelCanDock`, `updateKeyboardLayout` | Existing panels are relatively wide: mouse controls reserve 264 pixels, side keyboard uses 440–680 pixels. A slim mobile rail still requires new layout work. |
| Fullscreen fallback | `app.js`, `toggleFullscreen` | DOM fullscreen and page-filling fallback exist. API rejection currently reports an error; it does not automatically enter the page-filling fallback. |
| Pen input | `app.js`, pointer event handlers; `Sources/RemoteCore/RemoteProtocol.swift`; `Sources/RemoteRTC/DesktopInput.swift` | Non-touch pointers follow the mouse path. There are no pressure, tilt, stylus identity, or tablet-proximity protocol fields. |
| Capture quality | `Sources/RemoteRTC/DesktopCapture.swift`; `Sources/RemoteCore/RemoteStreamQuality.swift` | Hardware video and adaptive quality already exist. They do not establish measured Sidecar-like latency or sustained device performance. |

The current capture includes the Mac cursor (`showsCursor = true`), while touch
also displays a local cursor. Inspect cursor duplication and perceived lag on
devices before deciding whether a separate cursor transport is warranted.

The virtual-screen bridge explicitly uses runtime-checked, SDK-undeclared
`CGVirtualDisplay` classes. This is an existing OS compatibility dependency, not a
new public Apple Sidecar integration. Keep capability checks and the fallback to
an existing screen. A future native iOS client would not remove this host risk.

## Recommended user experience

For **iPad**, start with direct touch, a collapsible 48–56 CSS-pixel control rail,
large hit targets, and an unobstructed picture. Put Escape, Command / Option /
Control / Shift, undo, right-click, keyboard, input release, and session actions
within easy reach. Retain trackpad mode for precise work. Treat Pencil as a
basic pointer in the first release, with explicit pen-versus-finger arbitration.

For **phones**, default to trackpad interaction, a compact bottom shortcut strip,
and quick detail enlargement. Offer direct touch as a choice. Fitting an entire
Mac desktop into a phone is insufficient for comfortable operation; precision
pointing and selective enlargement matter more than filling every pixel.

Keep the existing two-finger rule initially and explain it in a short guide.
Provide an explicit remote-scroll action while zoomed in, since two-finger
movement currently pans the picture. Avoid assigning essential actions only to
three/four-finger or screen-edge gestures that iPadOS may intercept.

Add a visible “Use extended display” action with a resolution preview. Do not
create a display merely because a touch device opens the page. Reuse a suitable
existing virtual screen rather than silently replacing user configuration.
Do not automatically black out physical displays or enter a private session.

Use viewport size and input capabilities, plus a saved user choice, rather than
user-agent detection. iPad Safari can identify itself as macOS, and multitasking
changes available space. [WebKit input and viewport guidance](https://webkit.org/blog/9674/new-webkit-features-in-safari-13/)

## Resolution and keyboard behavior

Choose the Mac desktop's logical size first, then derive backing pixels and
capture quality. CSS pixels, device pixels, Mac desktop points, and encoded video
pixels are distinct quantities. Device pixel ratio alone is not a sizing policy.

Examples satisfying the existing validator, before adapting to the actual
workspace aspect ratio:

| Use | Backing pixels with HiDPI | Mac desktop points |
| --- | --- | --- |
| Tablet landscape | 2048 × 1536 | 1024 × 768 |
| Tablet portrait | 1536 × 2048 | 768 × 1024 |
| Phone portrait | 1080 × 2400 | 540 × 1200 |
| Phone landscape | 1920 × 1080 | 960 × 540 |

Preserve even dimensions, width 640–3840, height 480–3840, the 3840 × 2160 total
pixel budget, and the orientation-specific HiDPI minimum of 640 × 480 landscape
or 480 × 640 portrait logical points. A 390-point-wide phone cannot request a
390-point-wide HiDPI Mac screen under current rules. Fit or pan the minimum
supported desktop instead. Some Mac applications also impose larger window
minimums. Browser CSS cannot reflow or enlarge controls inside arbitrary Mac apps.

Do not resize or recreate the host screen when the software keyboard opens,
browser chrome changes, or a panel appears. Adjust only the client viewport;
preserve the inspected source point. For rotation or a sustained window-size
change, offer an explicit screen adaptation action initially. Current resizing
replaces the virtual display, which can move windows and change display IDs.

Add `visualViewport` handling for the real system keyboard and test editable
focus separately from remote screen focus. Keep the current committed-text path
as the initial IME solution. A live composition bridge needs separate work for
composition, deletion, selection, autocorrection, and duplicate key suppression.
[WebKit Visual Viewport documentation](https://webkit.org/blog/9674/new-webkit-features-in-safari-13/)

## Browser and native boundaries

- **Fullscreen:** iPadOS has DOM fullscreen support. iPhone element fullscreen
  remains an open WebKit enhancement as of this review. Keep all controls usable
  in ordinary page mode and after a fullscreen request fails. Video-only native
  fullscreen is unsuitable for an interactive HTML control overlay.
  [WebKit fullscreen implementation](https://webkit.org/blog/13966/webkit-features-in-safari-16-4/)
  [Current iPhone fullscreen issue](https://www2.webkit.org/show_bug.cgi?id=206854)
- **Home Screen:** iOS/iPadOS 26 lets users add any site as a web app. Offer this
  for a less cluttered launch experience; a new manifest is useful for identity
  and icons, not an installation prerequisite on those versions. This does not
  grant native background execution or bypass certificate trust requirements.
  [WebKit Home Screen behavior](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/)
- **Wake lock and suspension:** request client screen wake lock only for an
  active, visible remote session and handle denial/release. On return, validate
  session and video readiness before accepting input. A web app cannot promise
  uninterrupted background control or prevent system suspension. Keep Mac power
  ownership separate from the mobile device's screen wake lock.
  [W3C Screen Wake Lock](https://www.w3.org/TR/screen-wake-lock/)
- **Pencil:** Pointer Events expose pen type and potentially pressure/tilt, but
  browser/device support and hardware capabilities vary. These values currently
  disappear before reaching the Mac. Professional drawing requires protocol
  design, ordered stroke handling, Mac tablet-event compatibility, and app/device
  tests. Current lossy pointer movement is designed for mouse responsiveness,
  not preservation of every drawing sample. A native client can improve capture
  and Pencil-specific gestures; it does not establish host app compatibility.
  [Pointer Events specification](https://www.w3.org/TR/pointerevents/)
- **Touch Bar:** implement Vela's own shortcut strip first. The current protocol
  has no facility for exporting the active Mac application's contextual Touch
  Bar. Do not describe static shortcuts as equivalent to that system integration.
- **Latency:** retain H.264 compatibility and existing HEVC capability/failure
  fallback. Safari 27 adds receiver latency/jitter-buffer controls that can be
  explored behind feature detection. They are tuning mechanisms, not a latency
  guarantee. Measure screen-to-screen response, text legibility, thermals, and
  energy consumption on actual devices.
  [WebKit Safari 27 WebRTC changes](https://webkit.org/blog/18325/webkit-features-for-safari-27-0/)

## Delivery sequence and acceptance

1. **Mobile interaction profile — moderate scope, highest confidence.** Implement
   compact tablet/phone layouts, stable profile preference, direct/trackpad
   choice, modifier/shortcut rail, keyboard viewport handling, and robust page
   fullscreen fallback. Ordinary controls can reuse the existing protocol.
2. **Extended-display workflow — moderate scope with lifecycle risk.** Add
   resolution selection, one-action creation, capability fallback, and explicit
   exit/rotation behavior. Preserve first-frame commit, previous-screen recovery,
   same-controller reconnect behavior, and authentication checks. Do not rely on
   `pagehide` or unload delivery to perform host cleanup.
3. **Pencil drawing and native iOS client — separate exploratory scope.** First
   prove end-to-end pressure/tilt and stroke fidelity in target Mac applications.
   Build a native client if device testing demonstrates that browser limits
   materially prevent the intended experience.

Before release, run the existing Node, localization, and browser fixtures,
starting with localization in a fresh context. Extend fixture coverage to profile
switching without peer/auth replacement, source-point preservation, input release,
zoomed remote scrolling, and unchanged user text. Test both languages at narrow
widths, exact breakpoints, and short landscape sizes.

Physical-device acceptance must include iPad Safari with finger/Pencil/hardware
keyboard; iPhone portrait and landscape with Chinese IME; Home Screen launch;
safe areas; split/windowed layouts; keyboard open/close; OS-intercepted gestures;
background/foreground; network interruption; and host lock/session transitions.
Virtual-display creation/removal and physical-display recovery require a separate
explicitly scoped live run. Existing browser emulation records do not establish
real iPad/iPhone gesture quality or new-mode acceptance.

No precise delivery or latency estimate is justified before the compact-layout
prototype and a real Safari device pass. The recommended first milestone is a
reviewable browser mode using existing screens, followed by the extension-screen
workflow. This isolates the principal UX uncertainty before adding host lifecycle
changes.
