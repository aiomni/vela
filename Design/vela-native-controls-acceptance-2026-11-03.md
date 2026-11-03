# Native settings controls — 2026-11-03

The launch-at-login and remote-control switches now use AppKit's native mini
control size through `SettingsStyle.compactSwitch()`. On the review system this
measures 36 × 16 pt, compared with the previous regular 54 × 24 pt, matching the
System Settings reference. The controls retain native rendering, state, actions,
keyboard input, and accessibility without scaling or custom switch artwork.

Validation:

- The focused `--check-settings-controls` command passed in debug and in the final
  signed release bundle. It checks native switch sizing and on/off action delivery,
  plus rendered scrollbar hover behavior in light and dark appearances.
- Release packaging completed and deep, strict code-signature verification passed.
- Companion asset integrity and localization checks passed.
- The related scrollbar change passed 9 Node tests and 82 browser fixture checks;
  see `vela-scrollbars-acceptance-2026-11-03.md` for scope and browser fallbacks.

The earlier debug full self-test passed. A later full release self-test encountered
the existing companion hover/context suppression assertion while the installed
app was running and desktop focus changed. The focused command avoids those
desktop-dependent checks and does not start remote services, register hotkeys,
or create power assertions. The full self-test should run in an isolated desktop
session as described in `TESTING.txt`.

The installed application was left running. Updated review artifacts are
`dist/Vela.app` and `dist/Vela.zip`.
