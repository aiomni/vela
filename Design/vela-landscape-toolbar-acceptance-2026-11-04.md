# Compact landscape remote toolbar — 2026-11-04

## Change

Landscape viewports no taller than 500 CSS pixels now use a single toolbar row.
The duplicate brand/status block is hidden, tool icons and labels sit together,
and language/session actions remain visible. Tools scroll horizontally when
needed, without allocating another scrollbar row. Tool labels remain inside
their buttons; toolbar buttons retain 44-pixel heights. The status bar also
uses one compact row and omits the duplicate keyboard entry.

Safe-area padding, panel scrolling, keyboard space reservation, and the existing
toolbar collapse/expand behavior remain available. The layout change uses CSS;
it does not reconnect peers or modify authentication, display, or input state.

At 844x390, the toolbar decreased from 115 to 53 CSS pixels and the status bar
from 35 to 32. The workspace increased from 240 to 305 pixels (27% more height).

## Validation

The real client was served through the isolated mock server. Chrome mobile/touch
emulation passed localization checks first (20), private-session checks (25),
and touch checks (39). The responsive fixture passed in both languages at all
23 viewports:

- Compact landscape: 568x320, 667x375, 740x360, 800x360, 844x390, 932x430,
  1024x499, 1100x500, 1101x500, and 1280x500.
- Height boundary: 844x501.
- Portrait: 320x740, 360x740, 390x844, and 430x932.
- Existing width boundaries: 768x800, 800x800, 844x800, 1024x800, 1100x800,
  1101x800, 1280x800, and 1440x800.

Checks cover compact toolbar height, touch targets, horizontal tool reachability,
translated label bounds, pinned actions, status/metric separation, every panel,
keyboard space, collapse/expand, and session continuity. Pseudo-full-screen exit
labels passed at 844x390 and 568x320, followed by a portrait/landscape rotation
sequence that preserved the same peer and offer count. The Chinese landscape
layout was also visually reviewed using the synthetic video fixture.

All 19 Node web tests, localization validation, companion integrity validation,
and git diff whitespace checks passed. No real desktop capture, display changes,
or input injection occurred. These browser checks do not constitute physical
iPhone/Safari safe-area verification. This acceptance covers the source changes;
the existing v0.0.1 download assets were not replaced.
