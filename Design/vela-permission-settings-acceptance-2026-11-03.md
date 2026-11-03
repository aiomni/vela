# Settings permission placement — 2026-11-03

- Awake now contains an Input Monitoring permission row, current authorization
  status, and a direct link to the corresponding Privacy & Security pane. The
  explanation identifies physical input measurement for the idle countdown and
  states that unlimited mode does not require this permission.
- Remote contains the Device Control and Data Access permission row on macOS 27+;
  macOS 26 uses its original Accessibility name. The existing privacy deep link
  remains `Privacy_Accessibility`. The installed system's localization table
  confirms the new English and Chinese names.
- Remote permission settings remain accessible without a running host. Existing
  screen capture and input-control authorization requests are preserved when a
  host is present. Screen Recording requirements and status remain visible.
- Status uses Core Graphics preflight checks rather than treating an absent or
  disabled host's status file as an unknown authorization state. Returning to
  Settings refreshes permission status without committing unfinished fields.
- The Chinese Remote navigation label is now two characters meaning Remote;
  English remains Remote. Both translation catalogs and both READMEs are updated.
  Version-specific help text is regenerated during language refresh.

Validation: debug and release compilation; existing Swift tests with no failures;
localization and companion integrity checks; native control verification. An
isolated Chinese settings preview confirmed the new remote navigation and
permission names. The permission explanation was then moved below its group to
give it the full content width. Live grants and revocations were not performed;
the user's system privacy settings and installed app were not changed.
