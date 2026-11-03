# Phone-friendly virtual display presets — 2026-11-03

The web Display panel now offers 18 pixel-resolution presets, including 13
portrait modes, grouped as Phone, Tablet, High resolution, and Landscape. The
groups and guidance translate between English and Simplified Chinese. Custom
dimensions and the existing default 3840 by 2160 selection are retained.

Phone modes include 960 by 1920, 1080 by 1920, 1080 by 2160, 1080 by 2340,
1080 by 2400, 1170 by 2532, and 1284 by 2778. Tablet and higher-resolution
portrait groups add 1200 by 1920, 1536 by 2048, 1600 by 2560, 1440 by 2560,
1440 by 3120, and 2160 by 3840. Landscape adds 1920 by 1200 and 2560 by 1600
alongside the original three sizes.

Previously, HiDPI required at least 640 by 480 logical points without accounting
for orientation, rejecting common 1080-pixel-wide portrait configurations.
RemoteCore and the web client now accept the rotated minimum of 480 by 640
logical points for portrait. The original even backing-pixel requirement, axis
bounds, and 3840 by 2160 total pixel budget remain enforced. Every advertised
preset works with either HiDPI setting. At 1080 by 2400 with HiDPI, the logical
desktop is 540 by 1200 points.

Validation:

- All Swift tests passed, including portrait boundary acceptance, undersized
  HiDPI rejection, unchanged invalid-dimension and pixel-budget checks.
- All 11 Node tests passed, including all 18 HTML presets in both HiDPI modes.
- The virtual-preset browser fixture passed 133 assertions and checked 40 mock
  creation requests, localized groups, summaries, selection without automatic
  creation, custom rejection, and unchanged peer identity.
- Existing browser checks passed: 18 language, 25 private-session, 39 touch.
  Responsive checks passed at 360 by 694, 320 by 568, 844 by 390, and 1280 by 800.
- Localization, original companion integrity, release packaging, strict signature
  verification, and packaged-asset equality checks passed.

Browser testing used synthetic video and mocked display creation responses. No
live virtual display was created and the running host's topology, authentication,
and active connection were left unchanged. Actual mode availability remains
subject to macOS; the existing native creation/prepare checks verify the selected
pixel and logical dimensions before advertising a real display as ready.
