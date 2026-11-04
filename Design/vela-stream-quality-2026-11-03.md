# Vela adaptive desktop streaming: implementation and acceptance

Date: 2026-11-03 (Asia/Shanghai)

## Goal and delivered behavior

Retain ScreenCaptureKit, VideoToolbox and WebRTC while making desktop interaction
responsive, restoring static detail, and upgrading workload after network recovery.
Keep one authenticated controller, existing input release behavior, and physical
display/session recovery. Dependencies and signing configuration remain unchanged.

The host owns a shared, deterministic `DesktopQualityController` in RemoteCore.
Automatic, Text clarity, and Smooth motion are independent of the existing
smooth/clear/native quality IDs. Automatic accounts for the receiver's pixel
viewport when sizing both the video and its expected bandwidth workload. Text
prefers frame-rate reduction; motion permits earlier dimension reduction. Pressure
must last two seconds before a downgrade; further changes have a three-second
cooldown. Recovery requires six seconds of measured health and headroom per step.
Missing metrics and low static-screen bitrate are not interpreted as congestion.
These thresholds are initial policy settings, not measured performance guarantees.

Raw capture has one replaceable pending frame, separate capture/delivery queues,
and a 250 ms stale-frame cutoff checked both before and after queuing. Capture
changes use SCStream.updateConfiguration and source adaptation on the existing
peer. A static refinement window starts 350 ms after content changes, runs for at
most one second / twelve repeats, and then uses approximately one refresh per
second. Congestion suppresses the additional refinement workload. libwebrtc alone
controls congestion, pacing and retransmission. Its transport and encoding bitrate
ceilings are aligned without forcing the bandwidth estimate or setting a minimum.

Both controllers send bounded viewport, preference and interval decode/drop
feedback, scoped to the active media ID. Decode feedback expires after five
seconds. Host interval metrics use the video's selected transport pair, not an
arbitrary nominated pair; Objective-C numeric booleans are handled. Poll exposes
structured policy and metrics, and the browser displays codec, capture/receive
sizes, encode/decode time and adaptive status. Candidate/transport diagnostics
include selected numeric metrics and opaque IDs, without candidate addresses.

## Optional lossless enhancement

Both controllers offer an explicit, default-off lossless text checkbox. The host
uses BGRA capture only while enhancement is opted in, the session is available,
H.264 is negotiated, no pressure is present, and measured bandwidth is at least
3 Mbps. Ordinary streaming retains NV12 and the hardware encoder path.

After 1.35 seconds of stable content, a utility task creates 512-pixel PNG tiles
from RGB capture. The task is cancellable. Each tile is at most 128 KiB; one scene
is at most 512 KiB before JSON/base64 framing. Chunks contain at most 8 KiB of
image data and travel on a separate unordered reliable data channel. A token
budget limits tile wire traffic to 10% of estimated bandwidth and at most 2 Mbps.
SCTP buffering is bounded, control traffic takes priority, and queued work expires
after five seconds. This does not provide a separate network congestion domain.

Frame identities contain a capture epoch, content version and dimensions. They
are embedded in H.264 user_data_unregistered SEI. This is necessary because
libwebrtc adds a randomized RTP timestamp offset after the encoder callback.
The native decoder and browser encoded-frame worker read identities from the
actual received access unit and associate them with its received RTP timestamp.
The browser additionally requires requestVideoFrameCallback RTP metadata; missing
capability disables enhancement. A failed encoded transform reconnects with that
feature disabled. Native enhancement composites over a snapshot of the exact
matched decoded frame, rather than assuming the independent Metal view has
already presented that frame. Missing native pixel buffers disable composition.

Receivers reject unmatched epochs/versions/dimensions, bound chunk reassembly and
PNG dimensions, expire partial assemblies, and discard superseded asynchronous
image decodes. Unknown displayed frames clear the overlay. Session transitions,
capture errors and disconnects cancel or invalidate enhancement state. Enhancement
is disabled on the system lock screen. It may cover only part of a large desktop;
frequent updates, including a blinking caret, can delay stable-scene enhancement.
No OCR, application-content logging, or desktop snapshots are persisted.

## HEVC result and fallback

A background synthetic 256 x 144 VideoToolbox probe requires hardware acceleration,
encodes a real frame, creates a hardware-only decoder for its actual format, and
checks decoded dimensions. Encoder/decoder hardware flags and successful round
trip are distinct from WebRTC adapter availability. Native offers require both
local validation and adapter support; the host requires its own validation and
peer opt-in. H.264 stays available. Negotiation errors or six seconds without a
decoded frame trigger a native H.264 retry. Enhancement uses H.264.

Measured on this execution machine:

- hardware HEVC encoder: true;
- hardware HEVC decoder: true;
- synthetic hardware round trip: true;
- bundled WebRTC H.265 encoder and decoder adapters: both false.

Therefore the pinned WebRTC 154.0.0 build **does not enable HEVC**. The dependency
was not replaced or unpinned. Enabling actual HEVC transport requires a compatible
WebRTC distribution/adapter and additional full-resolution, end-to-end validation;
the hardware probe by itself is not that validation.

## Validation evidence

- `swift test`: 50 XCTest cases, 49 passed and one optional browser harness skipped;
  no failures. Includes real encrypted 4K H.264/control transport and validation
  that in-band identities match decoded RTP frames, policy downgrade/recovery,
  viewport budgets, bounded refinement, native PNG gating and metric resets.
- The optional `DesktopBrowserTransportTests` was also run explicitly against a
  real browser using synthetic pixels, a temporary TLS listener, and a loopback
  proxy trusting the fixture certificate. Video decoded, in-band identities were
  read by the worker, and a matching PNG tile was drawn; browser acknowledgement
  completed the test. No real desktop capture or input injection was involved.
- `node --test Tests/WebClient/*.test.cjs`: 17 passed, including out-of-order
  reassembly, stale-scene rejection, asynchronous decode cancellation, decoder
  counter resets and in-band H.264 identity parsing.
- Browser mock integration: localization 19, session 25, and touch 39 checks passed.
  Responsive checks passed 64 checks per viewport in both languages, including
  390 x 844 portrait, 844 x 390 short landscape, and 500 x 844. Quality panel was
  visually inspected with the real browser screenshot tool.
- Localization: matching 807-entry native/web catalogs, English source and valid
  placeholders. Companion preservation: 19 shapes, 25 eye poses, 39 expression
  records unchanged.
- `Vela --watch-policy-test` passed. `Vela --self-test` passed, including live Metal
  drawable checks, isolated power-state checks, native language and settings tests.
  This does not verify Vela Connect's new overlay visually on a real connection.
- `git diff --check` passed. No packaging/signing configuration changes, installed
  app replacement, lockscreen probes, lid-live probes or blackout probes were made.

## Remaining real-device acceptance

Synthetic transport and policy tests prove correctness boundaries, not a measured
screen-to-screen latency or image-quality improvement on the user's network.
Still required for release-level performance claims: real ScreenCaptureKit hot
updates across displays, Vela Connect composition/color alignment, browsers that
lack encoded transforms, shaped UDP networks with loss and bandwidth changes,
long-session memory/energy behavior, and subjective small-text readability.
The earlier approximately one-second detail recovery and recovery-time targets
remain targets until those measurements exist. Reproduction instructions for the
nonintrusive synthetic browser harness are in TESTING.txt.
