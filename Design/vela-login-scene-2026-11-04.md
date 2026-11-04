# Vela login companion and quiet backdrop

Date: 2026-11-04 (Asia/Shanghai)

The login background is now a lighter blue-gray (`#293943`). A low-contrast ASCII
dot field slowly changes brightness and density. Its character positions stay
fixed, with a quiet region around the login controls. The canvas is decorative,
noninteractive, explicitly behind the content, capped at 1600×1000 backing pixels,
and repainted approximately twice per second.

The circular computer icon is replaced with the existing companion's blob
silhouette and original idle eye poses. Its body, eye interpolation, blink,
breathing, and gaze formulas follow the native idle animation. The geometry,
idle playlist, timing, and face data are embedded directly in the existing HTML;
no new public asset endpoint or network dependency was added. The source asset
is unchanged. `check-companion.py` additionally compares the web silhouette and
embedded eye/timing data with the original asset and checks for the provenance
notice. Existing third-party ownership and usage restrictions remain in force.

The scene clock and both renderers stop during remote sessions and while the
document is hidden. Returning to login resumes them. Reduced motion renders one
static pose and backdrop. Increased contrast, forced colors, and reduced
transparency hide the backdrop and stop motion. The scene does not read input
values or change authentication, language, power, or remote-control state.

Validation:

- JavaScript syntax, 19 Node tests, localization (822 matching entries), original
  companion integrity plus web-export checks, and diff whitespace checks passed.
- The isolated H.264 browser fixture passed localization 20, private-session 25,
  touch 39, and responsive session layout 70 assertions.
- Both-language login layout and bounded/noninteractive canvas checks passed at
  320×640, 390×844, 520×720, 521×720, 800×720, 801×720, 1100×720,
  1101×720, 844×390, 1440×900, and 2056×1290 (22 combinations).
- Browser observation confirmed pet movement and three backdrop paints over
  1.2 seconds. Reduced-motion emulation left both unchanged over 650 ms.
- Connected sessions hid the backdrop and stopped pet and canvas updates;
  disconnecting resumed them. A synthetic hidden-document visibility event also
  paused both renderers. This last check simulates the event, not an OS hide.
- Increased-contrast emulation hid the backdrop and stopped both renderers.
- At 1280×720, the backdrop drew 3600 glyphs per paint. Two instrumented samples
  took approximately 5–6 ms each; this is a local observation, not a device-wide
  performance guarantee.
- Final desktop and phone screenshots were visually inspected. Temporary media
  and viewport emulation were cleared. No real display, input, lock, or power
  probes were run; no signed bundle was rebuilt or installed.

## Follow-up: one large synchronized dither companion

The full-page ASCII field is replaced by a single large, centered companion in
ordered Bayer dithering. Its tint stays subdued behind the login controls. Size
follows the viewport and is capped at 820 CSS pixels. The original silhouette and
current eye paths are rasterized to a 160×160 mask, then dithered and scaled with
nearest-neighbor sampling.

One pose is calculated per animation frame and passed to both the foreground SVG
and the background renderer. Body rotation, breathing, bounce, gaze, blinking, and
winks therefore use the same state. Both renderers share the existing clock,
40-ms minimum update interval, session pause, and accessibility behavior.

Validation: JavaScript syntax, 19 Node tests, localization, companion integrity,
and whitespace checks passed. Browser verification independently rendered the
foreground SVG's actual transform and eye paths and compared that mask with the
background source mask for 147 frames over 6.1 seconds. Every mask matched with
zero differing pixels; the sample included a blink reaching approximately 6% of
normal eye height. Both scenes stayed static with reduced motion, paused during
a connected fixture session, and resumed after disconnecting.

The H.264 browser fixture passed localization 20, private-session 25, touch 39,
and responsive session layout 70 assertions. Both-language layout, bounded
canvas, and noninteractive-background checks passed all 11 viewports above
(22 combinations). At 1280×720, 27 instrumented dither renders averaged 0.49 ms,
with a 1.3-ms maximum; these are local observations. Final desktop and phone
screenshots were inspected. Temporary emulation was cleared and test tabs closed.
No signed app bundle was rebuilt or installed.
