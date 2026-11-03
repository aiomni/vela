# Vela scrollbar styling — 2026-11-03

All app-owned scroll regions now share `VelaScrollView`: the five settings pages,
their sidebar, and the separate LockLab log. Vela Connect currently has no custom
scroll regions. System-owned dialogs and global macOS preferences are unchanged.

The shared view uses an overlay-compatible `NSScroller` subclass. Only the knob
and track drawing methods are customized; AppKit retains wheel, drag, momentum,
hit testing, accessibility, and overlay fading. The visible thumb is 3 pt at rest
with 25% opacity, and 7 pt with 62% opacity when hovered or dragged. Its track is
transparent. High contrast increases visibility; reduced transparency uses an
opaque thumb. Hover does not resize the scroll viewport.

Web rules cover the document, desktop viewport, panels, text fields, and horizontal
shortcut/tool lists. Browsers supporting WebKit scrollbar selectors use a stable
12 px hit area with a visible 4 px / 8 px resting/hover thumb. Standard-property
fallbacks keep native thin scrollbars with stronger hover contrast. High-contrast
and forced-color preferences retain appropriate visibility. Styling does not add
pointer handlers or intercept remote input.

Validation:

- Debug build passed for all native targets.
- Native self-test passed, including rendered resting/hover thumb measurements in
  light and dark appearances, unchanged scroll values, and stable viewport size.
- Existing appearance, localization, settings, companion, power, and lifecycle
  self-tests passed; live rendering checks were conclusive.
- All 9 Node web unit tests and 82 browser fixture checks passed: 18 localization,
  25 session/privacy, and 39 gesture checks.
- Chromium computed styles confirmed the transparent 12 px track, 4 px resting
  thumb, native-property compatibility, and parsed hover rules for 8 px / 64%
  opacity. Horizontal and vertical scrolling preserved viewport dimensions.
- Localization and companion integrity checks passed; no expression data changed.

Local logs are ignored under `.build/`. No installed app, production remote
configuration, or global appearance/scrollbar preferences were changed.
