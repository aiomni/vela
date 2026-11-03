# Mobile remote console layout — 2026-11-03

The reported phone layout was reproduced at 360 CSS pixels: toolbar buttons
shrank to 45 px while Keyboard and Physical displays labels measured roughly
51 and 91 px. Labels painted beyond their buttons, and the fixed session actions
reduced the available tool strip to less than half the viewport.

Changes:

- At narrow and intermediate widths, session branding, language selection, and
  session actions occupy the first row. The six tools use a full-width second
  row with explicit minimum columns and wrapping labels. Small widths retain
  horizontal reachability instead of compressing text beyond button bounds.
- Wider desktop toolbars also retain scrollable overflow when labels do not fit.
- On phones, connection status and video metrics use separate footer rows. The
  language selector keeps a readable width, and safe-area insets protect controls.
- The on-screen keyboard has a bounded height at responsive widths, leaving
  remote screen space available even on a 320 × 568 viewport. Panels scroll
  internally when needed.
- Remote authentication, transport, input handlers, and video aspect ratio are
  unchanged. Tests use synthetic video, credentials, and input only. User-provided
  screenshots and their private desktop content or network addresses are not
  included in the repository.

Validation:

- 762 layout assertions passed across both languages at 320 × 568, 360 × 694,
  390 × 844, 430 × 932, 768 × 1024, 800 × 600, 844 × 390, 1024 × 768,
  1100 × 768, 1101 × 768, 1280 × 800, and 1440 × 900.
- Checks cover real text bounds, reachable tools, action separation, readable
  language selection, footer metrics, all five panels, keyboard screen space,
  toolbar collapse/expand, and unchanged peer/session identity.
- Existing browser fixtures passed: 18 language, 25 private-session, and 39 touch
  checks on desktop. All 39 touch checks also passed in a 390 × 844 mobile viewport.
- All 9 Node unit tests, localization checks, and companion integrity checks passed.
- Release packaging and strict signature validation passed; packaged web assets
  match the source. The installed application and running remote host were left
  unchanged. The updated app must be opened before the live phone client can
  receive the new assets.

Browser coverage uses Chromium device emulation; it does not establish results
for physical Android/iOS devices or Safari. Native desktop-dependent self-tests
were not repeated for this CSS-only application change.
