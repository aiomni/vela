# Hardware HEVC end-to-end acceptance — November 4, 2026

This record supersedes the HEVC limitation in the historical November 3 streaming
record. ScreenCaptureKit, VideoToolbox and WebRTC remain the media pipeline.
Package dependencies and resolved versions are unchanged, including WebRTC 154.0.0.

## Implementation

The pinned framework already provides H.265 negotiation and RTP transport. Vela
now supplies the missing Apple adapters through its public Objective-C encoder
and decoder protocols. No private C++ bridge or replacement framework is needed.

- The encoder requires hardware VideoToolbox HEVC Main, real-time operation and
  disabled frame reordering. It translates length-prefixed output into Annex B,
  includes VPS/SPS/PPS on keyframes, and preserves RTP timestamps and rotation.
- The decoder validates bounded Annex B input, reconstructs parameter sets and
  length-prefixed samples, and requires hardware VideoToolbox decoding. Parameter
  changes rebuild its session. Picture size is capped at 4K pixel area and 3840
  pixels per axis; Main 10, HDR and 4:4:4 are not advertised.
- Native NV12 buffers use the direct path. Adapted buffers use bounded Core Image
  scaling when the WebRTC dimensions differ from the backing capture buffer.
  Pool pressure drops a frame. Only one hardware frame is outstanding; pending
  bitrate/framerate changes apply between completed frames. Obsolete sessions
  are invalidated rather than drained into the live stream.
- A higher receiver maximum level, including Chrome's level 180, is accepted;
  the encoder remains bounded to its advertised level 156. Capture dimensions,
  frame rate and bitrate respect the negotiated Main-tier limits.
- Capability gating requires a synthetic system hardware round trip, adapter
  availability, and an actual synthetic 3840×2160 adapter round trip. Creating a
  session or finding an SDP codec alone does not enable HEVC.
- Vela Connect and the host both validate hardware before enabling HEVC. Browsers
  additionally require compatible H.265 Main WebRTC capabilities and a positive
  hardware-efficient `MediaCapabilities.decodingInfo` result for 4K WebRTC decode.
- H.264 remains in codec preferences. Unsupported peers negotiate H.264; encoder
  initialization failure can switch within WebRTC. Controllers retry with H.264
  after negotiation/startup failure or six seconds without decode progress,
  excluding session recovery/account verification. A browser explicitly reporting
  inefficient decoding also falls back. Actual RTP codec statistics update the
  UI and capture limits when an internal fallback differs from initial SDP.
- Lossless PNG enhancement continues to use H.264 frame identities. Enabling it
  changes codec through the existing authenticated reconnect path. Disabling it
  permits HEVC again unless this session has already encountered an HEVC failure.

## Validation

All media fixtures used generated pixels, loopback encrypted WebRTC connections
and temporary certificates. No desktop capture, real input injection, display
changes, password entry or installed-app replacement was performed.

- `swift test`: 56 tests, 55 passed and the optional browser fixture skipped;
  no failures. The six HEVC transport tests include a direct hardware adapter
  round trip, encrypted native 4K H.265, reliable control delivery, live 4K-to-1080p
  resizing with retained luma contrast, profile/level bounds, malformed NAL input,
  unsupported-peer H.264 in both directions and injected encoder-init failure.
- Native transport statistics identify `video/H265` and `VideoToolboxHEVC` for
  both actual encoded and decoded frames. The resize transport case also passed
  three consecutive independent runs after the rate-update serialization fix.
- The explicit real-Chrome browser fixture decoded 3840×2160 H.265 frames and
  acknowledged completion. The host reported actual `VideoToolboxHEVC` encoding.
  Browser hardware capability was positive; its runtime hardware statistic was
  omitted (`null`), so browser runtime hardware selection is not independently
  asserted from that statistic. An explicit `false` would fail acceptance.
- Browser mock checks passed: 20 localization, 25 session, 39 touch and 7 codec
  fallback assertions. The codec fixture proves stalled HEVC schedules H.264,
  replaces the media connection, preserves authentication, restores input and
  avoids a reconnect loop. These are separate from real codec transport evidence.
- Node web tests: 18 passed. Localization validation: 810 identical translations.
  Companion validation preserved 19 shapes, 25 eye poses and 39 expression records.
  `git diff --check` passed.

A repeated resize check exposed VideoToolbox service contention while rate
properties were updated during asynchronous format-description production.
Thread samples showed both operations waiting on the encoder service. Serializing
rate changes between completed frames and bounding outstanding input addressed
the observed failure; this does not establish that every hardware/OS combination
is free of VideoToolbox faults. Capability and runtime fallbacks remain necessary.

## Limits and reproduction

Commands for native, browser and recovery fixtures are in `TESTING.txt`. This is
transport correctness evidence on the current Apple hardware and browser. It is
not a measurement of screen-to-screen latency, network congestion recovery,
continuous 4K frame rate, energy use or long-session stability. Real ScreenCaptureKit
capture, native presentation and shaped-network acceptance remain separate work.
Unsupported hardware or browsers continue using H.264.

API workflow reference: [Apple VideoToolbox compression sessions](https://developer.apple.com/documentation/videotoolbox/vtcompressionsession-api-collection).
