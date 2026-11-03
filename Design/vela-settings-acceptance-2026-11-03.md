# Vela native settings acceptance — 2026-11-03

The settings window follows the user's final System Settings reference: a native
sidebar, navigation and page title in the toolbar, compact grouped rows, trailing
values, native switches and sliders, and semantic light/dark content surfaces.
There is no search field, large page icon, introductory banner, or custom-drawn
slider track. Chinese navigation titles are the requested five two-character
labels; English navigation remains English and is still the default.
The sidebar is 164 pt by default, limited to 184 pt, with compact row insets and
no redundant outer horizontal padding.

## Implementation

- `SettingsNavigation.swift` uses `NSSplitViewController` with a native sidebar
  item and an `NSToolbar`. The back/forward cluster uses `NSGlassEffectView`, not
  a simulated blur. Reduced transparency switches that custom glass cluster to
  an opaque semantic surface; the system controls the sidebar material. The
  optional macOS 27 interactive-glass property is availability guarded.
- `SettingsStyle.swift` shares compact rows, grouped surfaces, system typography,
  and adaptive separators. High-contrast appearances receive stronger borders.
- The Appearance page includes three selectable Light, Dark, and Auto thumbnails.
  The app-only selection applies immediately, persists as `velaAppearance`, is
  restored at launch, and returns to Auto on reset. Auto follows system appearance.
  Keyboard arrows and native button activation select a mode without changing
  keep-awake or remote state.
- The five pages organize existing general, keep-awake, Agent, appearance, and
  remote controls. Pages remain attached while hidden to retain controller and
  field state. Navigation history and keyboard focus survive category changes.
- `SettingsSlider.swift` delegates rendering, pointer tracking, keyboard input,
  and accessibility to `NSSlider`. Existing nonlinear duration and size mappings
  remain intact. Native slider actions reach their original callbacks.
- Language switching preserves unfinished duration, idle, and custom-Agent edits.
  Agent popup values use represented objects instead of translated label parsing.
- Companion geometry, all 25 eye poses, 39 expression records, 22 cycling moods,
  and the 19 shapes remain unchanged. Remote authentication, listeners,
  permissions, and display recovery behavior were not changed.

## Validation

- Debug build, 36 Swift unit tests, and 9 web unit tests passed.
- Full native self-test passed, including all five pages at 740 × 540, 800 × 620, and
  860 × 650 content sizes in light, dark, and both high-contrast appearances.
  Controls fit within their pages. The opaque navigation fallback was exercised
  in process without changing global accessibility preferences.
- Native slider callbacks, exposed accessibility children, sidebar keyboard-focus
  retention, navigation history, bilingual updates, and pending-edit retention
  passed. Existing power, Agent, login, appearance, and lifecycle checks passed.
- Native UI inspection confirmed the compact Chinese light layout, English dark
  layout, two-character Chinese navigation, and live language switching. Light, Dark, and Auto selection were also
  verified in the running native window, including the return to system appearance. The
  review window used private application preferences and remote files.
- Localization validation passed with 770 matching translations. Companion
  integrity validation confirmed the original asset checksum.

The visual review entry point and options are documented in `TESTING.txt`. Build
logs and generated test images remain ignored under `.build/`. No installed app
was replaced, production remote configuration changed, or repository uploaded.

## Final package

The signed release is `dist/Vela.app`, with its embedded Vela Connect controller;
`dist/Vela.zip` is the verified archive. Strict deep signature verification and
both bundle plist checks passed. Packaged expression data and both localization
catalogs match the source files, and both bundles retain English development
regions. The final packaged self-test in `.build/settings-release-self-test.log`
completed successfully, including conclusive live rendering checks and the new
appearance selection, persistence, keyboard, layout, and reset checks. Archive
integrity and the archived companion data were also verified.
