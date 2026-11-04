# Remote detail zoom acceptance — November 4, 2026

Vela Connect and the browser now offer Fit window, pixel-for-pixel 100%, and
150%, 200% and 400% viewing. Zoom keeps the inspected source position, supports
centering, and does not reconnect the authenticated media session. Native viewing
uses the shared Vela overlay scrollbars; source-sized Metal drawables remain
bounded independently of the magnified view size.

Detail modes omit the window-size capture budget from streaming feedback. This
allows the host to retain the selected source resolution instead of enlarging a
window-sized low-resolution capture. The user's quality ceiling, negotiated codec
limits and congestion adaptation still apply. Returning to Fit restores the
viewport budget. Zoom cannot reconstruct detail lost in capture or compression;
this change does not implement a separate high-resolution region stream.

Scrollbars and Alt/Option-scroll pan locally. Ordinary scrolling continues to
control the remote computer. Browser Pan view also permits mouse or touch dragging
with remote input paused, an explicit Exit pan view control, and Escape to exit.
Exiting preserves view-only restrictions. Blur/cancel and mode changes release
input, and language switching preserves zoom and the connection.

## Validation

- Debug build passed. The hidden-window `VelaConnect --viewport-test` passed
  11 checks: fit, Retina physical-pixel mapping, 400% size, source-sized Metal
  drawables, centering, scrolled click coordinates, ordinary remote scrolling,
  local Option-scroll and actual native clip movement, view-only protection,
  and returning to fit. Events were delivered only to test views, never posted
  to the operating system.
- Swift tests: 55 passed, one optional browser transport test skipped, no failures.
  Existing HEVC/H.264 transport and streaming quality checks remained passing.
- Node tests: 19 passed, including detail-view capture feedback and Retina sizing.
- Real-browser mock fixture: 20 localization, 19 zoom, 25 session and 39 touch
  assertions passed. Zoom checks covered feedback changes, focus preservation,
  input coordinates after pan, local versus remote scroll, touch inspection,
  permission preservation, translation and authentication continuity.
- Zoom checks passed at desktop, mobile 390×844 with device scale 2, and short
  landscape 844×390. Both-language responsive checks passed at widths 320, 360,
  390, 430, 768, 800, 844, 1024, 1100, 1101, 1280 and 1440, plus 844×390 landscape.
  The Chinese mobile display panel was visually inspected without overflow.
- Localization catalogs matched (820 entries); companion shapes, eye poses and
  expression records remained unchanged. `git diff --check` passed.

No real desktop capture, input injection, display/power changes, or installed-app
replacement was performed. Native tests prove geometry and event routing in a
hidden window; they do not prove live native video presentation or GPU memory,
latency and network performance under sustained use. Reproduction commands and
the browser fixture sequence are in `TESTING.txt`.
