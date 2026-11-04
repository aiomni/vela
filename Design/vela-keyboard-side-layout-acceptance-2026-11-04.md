# Switchable keyboard side layout — 2026-11-04

## Behavior

The remote keyboard supports a right-side layout in landscape and retains its
existing bottom layout. A compact Side / Bottom choice appears in the keyboard
header when both columns fit. The browser saves `vela.keyboardLayout` using
stable `side` / `bottom` IDs, defaulting to side. Portrait and narrow viewports
fall back to bottom without changing that preference.

Side width ranges from 440 to 680 CSS pixels, targeting 52% of workspace width.
It requires a 12-pixel gap, at least 320 pixels for the screen, and 180 pixels
of workspace height. The keyboard scrolls vertically; its layout/close header
stays reachable. Its screen viewport keeps the full workspace height. The
existing width transition animates screen movement. Touching the remote screen
does not dismiss a docked keyboard. Other tool panels retain their exclusivity.

Switching releases held modifiers, preserves unfinished text, and retains the
current peer and authentication. Masked text preservation is explicitly limited
to layout switching. Close, blur, disconnect, and normal input release retain
their existing masked-text clearing behavior. No text is saved with the layout
preference. English fallback HTML and both translation catalogs were updated.

## Validation performed

- JavaScript syntax, all 19 Node web tests, localization consistency, companion
  integrity, and git diff whitespace checks passed.
- In a fresh isolated browser, localization checks passed first (20), followed
  by keyboard-layout checks (30), private-session checks (25), touch checks
  (39), and responsive checks. At 568x320, localization and all five small-layout
  fallback checks passed.
- Both languages passed responsive checks at the previous 23 review viewports
  plus 771x390 and 772x390, covering the side-layout width boundary. Side layouts
  keep the screen and panel in separate columns and retain screen height;
  bottom layouts retain their existing screen-space reservation.
- A saved Bottom choice survived reload. Switching to Side, rotating to
  390x844 and back to 844x390 preserved unfinished text, the peer, and offer
  count, restoring side layout after the portrait fallback.
- Pinch checks (47) and zoom checks (15) passed with the side keyboard enabled,
  including preserved detail magnification when opening the keyboard. Side
  layout also passed modifier release, key delivery, masked-text preservation
  during switching, masked-text clearing on close, sticky-header reachability,
  manual reopening, and preference persistence checks.
- The Chinese 844x390 side layout was visually reviewed with synthetic video.

All browser API and input traffic used isolated fixtures. No real desktop
capture, input injection, installed-app changes, or release asset replacement
occurred. Physical Safari safe areas and on-device system keyboard behavior
remain outside this browser-emulation acceptance.
