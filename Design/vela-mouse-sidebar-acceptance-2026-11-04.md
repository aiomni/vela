# Mouse and touch sidebar — 2026-11-04

## Behavior

Mouse and touch now uses two mode buttons, compact mouse/desktop action rows,
and a collapsed gesture guide. The mode value and existing input actions retain
their stable IDs. The view-only action uses a shorter label and retains its
state and descriptive accessible title. English and Chinese catalogs match.

After video dimensions are known, a landscape workspace with at least 300 CSS
pixels of height automatically opens mouse controls when the full fitted video
still fits beside a 264-pixel sidebar and a 12-pixel gap. The remaining screen
region must be at least 320 pixels wide. Smaller layouts retain the manual
popup. Docked controls do not cover the video or close when the video is touched
or dragging is enabled.

Closing restores the full screen region with a 260 ms width transition, moving
the fitted video smoothly to the center. The existing reduced-motion rule
disables transitions. Explicit dismissal persists for the current connection,
including rotation and language changes. The toolbar reopens the controls.
Automatic panels hide in portrait and return when landscape space permits;
opening another tool temporarily yields the sidebar. Collapse, Escape, blur,
and close retain input-release and masked-text clearing behavior.

## Validation performed

- Browser source and sidebar fixture syntax checks passed.
- All 19 Node web unit tests passed; localization and original companion asset
  checks passed; git diff whitespace checks passed.
- Fresh mock-browser localization checks passed first (20). Sidebar checks
  passed at 844x390 (21), including a sampled intermediate animation position,
  final centering, unchanged fitted video width, collapsed help, mode changes
  in both languages, preserved dock on touch, drag release on close, explicit
  dismissal, manual reopening, and unchanged peer/offer count.
- At 568x320 the sidebar fixture passed 18 checks with automatic docking disabled;
  manual popup content remained horizontally bounded in both languages.
- Private-session checks (25), touch input checks (39), and responsive checks
  passed after the sidebar changes. Both languages passed at the same 23
  viewports listed in the compact landscape toolbar acceptance record.
- An automatic 844x390 sidebar hid at 390x844 and returned at 844x390 without a
  new peer or offer. The Chinese layout was visually reviewed with synthetic
  video. All fixture input remained in the mock channel.

No real desktop capture, device input, permission changes, or app installation
was performed. Physical Safari safe areas and the system reduced-motion setting
were not exercised on a phone. Existing release assets were not replaced.
