# Companion icons acceptance — 2026-11-05

## Change

Vela now uses the original companion's black silhouette and upper-right eye pose for both the application icon and menu bar icon. Both render from the same vector path, using the unchanged `pet.json` body and eye pose 0. The application icon has a near-white rounded tile; the menu bar icon uses transparent eye cutouts and AppKit template tinting.

The application and menu bar icons stay fixed across keep-awake states and companion appearance changes. Countdown labels, menu state, and status tooltips continue to report activity. Companion rendering, customization, expression playlists, and timing remain unchanged. Vela Connect is unchanged.

## Validation

- Debug product build passed.
- `Vela --generate-iconset .build/Vela.iconset` passed; the 512-pixel output was visually inspected against the supplied reference.
- `Vela --self-test` passed, including the native 18-pixel menu icon eye transparency checks, stable application artwork across power transitions, real assertion release, settings, and live rendering checks. The run reported no inconclusive rendering checks.
- `python3 scripts/check-companion.py` passed: all 19 shapes, 25 eye poses, and 39 expression records retain the original asset hash.
- `python3 scripts/check-localization.py` passed.
- Signed release packaging with `./scripts/build-app.sh release Vela` passed; output: `dist/Vela.app`.
- `codesign --verify --deep --strict dist/Vela.app` and `plutil -lint dist/Vela.app/Contents/Info.plist` passed.
- `git diff --check` passed.

No lockscreen, blackout, or closed-lid live probes were run.

## Remote web icon follow-up

The remote web landing header, connected-session toolbar, and browser favicon now use `companion-icon.svg`, which retains the same original body and eye pose 0. The animated login companion remains unchanged. The production static-asset allowlist and isolated mock server both serve the SVG as `image/svg+xml`.

Validation: all 19 Node web tests passed. In a fresh isolated browser context, localization checks passed (20), private-session checks passed (25), and touch checks passed (39), in that order. Both header images loaded, and the favicon returned HTTP 200 with the SVG MIME type. Responsive checks passed in both languages at widths 375, 419, 420, 421, 520, 521, 799, 800, 801, 1100, and 1101, as well as 568×320, 844×500, and 844×501. The landing header was visually inspected in the browser. Signed release packaging, strict signature verification, plist lint, and comparison of the packaged SVG against the source all passed.

## Release preflight

Before preparing v0.0.3, `swift test`, all seven Python release tests, all 19 Node web tests, localization checks, companion integrity checks, and `git diff --check` passed.
