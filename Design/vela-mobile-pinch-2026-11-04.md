# Mobile pinch zoom acceptance — November 4, 2026

The mobile browser now zooms the remote picture directly with two fingers. It
anchors the source detail under the fingers, supports continuous scale changes,
and pans the enlarged picture when both fingers move. It does not magnify the
browser's toolbar or require an input-pausing mode. The previous Pan view controls
have been removed; the earlier remote-zoom record describes that historical UI.

One finger continues to operate the remote mouse in either Trackpad or Direct
touch mode. Direct-touch coordinates include zoom and viewport scrolling. Remote
dragging, long-press right-click, hardware keyboard events, on-screen keys and text
entry remain available. At Fit window, parallel two-finger movement retains remote
scrolling; when enlarged it pans the local picture. Mouse wheels retain remote
scrolling. Three/four-finger gesture handling remains separate.

Pointer updates are grouped per animation frame so two parallel fingers are not
classified as a pinch based on an intermediate pointer update. A pinch cancels
pending single-touch click/drag work, and remaining fingers cannot become a new
mouse drag after a finger lifts. Cancel, blur and disconnect clear pending work.
View-only users can inspect locally without gaining remote input permission.

Detail zoom retains the selected capture-quality budget. The displayed picture's
width remains stable when the keyboard or viewport layout changes, and new source
frames do not replace the gesture scale with a window-fit scale. Recovery and
account-verification overlays remain outside the scrolling picture so panning
cannot reveal an older frame behind the overlay.

## Validation

- Debug build passed, including copied browser resources. Node: 19 tests passed.
  Localization catalogs matched and companion preservation checks passed.
- The isolated browser pinch fixture passed 47 checks at 320×640, 390×844,
  844×390 and 1280×800 with device scale 2. Coverage includes source-point anchoring,
  bounded panning, direct click coordinates, remote dragging, right-click, hardware
  and on-screen keys, text entry, keyboard-open sizing, view-only, cancellation,
  language switching, source-quality feedback and authentication continuity.
- Related fixtures passed: 20 localization, 15 manual zoom, 25 session and 39
  existing touch assertions. Existing two-finger fit scrolling and four-finger
  desktop shortcuts remained passing.
- Chrome's native touch-event pipeline also produced local 2× zoom while the page
  scale stayed unchanged and no remote mouse/scroll/key gesture input was emitted.
  Browser mouse clicks, keyboard A and on-screen Enter worked afterward, with the
  keyboard open and detail magnification retained. These checks used a loopback
  mock connection, not the real host input endpoint.
- Both-language responsive checks passed at widths 320, 360, 390, 430, 768, 800,
  844, 1024, 1100, 1101, 1280 and 1440, plus short landscape 844×390.
  `git diff --check` passed.

Run `/language-tests.js` first in a fresh browser context on the isolated mock
server, then `/pinch-tests.js` and `await runPinchChecks()`. The fixture uses
generated video and in-memory input records. No real capture, system input,
display/power changes or installed-app replacement was performed. Physical
iPhone/iPad Safari and Android device gesture feel have not been verified.
