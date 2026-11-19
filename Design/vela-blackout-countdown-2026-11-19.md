# Companion blackout countdown

Clicking **Disconnect physical displays** starts a five-second countdown over the screens. The native panels use large translucent numerals, cool blue rings, a sweeping arc, and a short zoom on each number. Their background starts fully transparent and fades smoothly to solid black at five seconds. Reduced Motion keeps the numerals and ring layout static between seconds.

Keyboard and mouse events continue to their applications. A listen-only event tap observes physical Escape to cancel. Other input leaves the countdown deadline unchanged. The panels ignore mouse events, stay visible across application changes, and acquire no keyboard focus.

Vela finishes the digits at five seconds, then prepares the replacement displays and recovery watchdog. The opaque black cover remains until the physical display transaction finishes. Each cover follows its original display ID through layout changes, preventing a desktop flash during preparation. Escape during the countdown cancels the task before virtual displays are created. Sleep and application exit also cancel the task.

The recovery watchdog is created after the countdown. It ignores local input during display preparation. A committed-state marker enables local-input restoration after the physical display transaction succeeds. The callback checks this active state and physical-input classification. Existing remote-input exclusions, heartbeat recovery, and topology restoration continue through the same watchdog.

## Validation

- Swift tests cover the inactive and active states for physical keyboard and mouse events, including the remote-input exclusion. The separately configured synthetic browser transport test was skipped.
- Focused native checks passed for the five-second number boundaries, physical Escape classification, and raster background opacity at zero, 2.5, five, and six seconds. The final frame is opaque black. The countdown rendering was inspected from its generated preview.
- Node tests, matching localization catalogs, and companion asset integrity passed.
- The local signed preview is version 0.0.5, build 15. Strict bundle signature verification, property-list validation, and the signed executable’s focused native checks passed.
- Hidden-window geometry checks matched both attached screens, including the external screen’s negative origin.
- A signed companion-mode live probe restored both physical displays through local input. Its evidence is recorded in `vela-blackout-local-recovery-fix-2026-11-19.md`. The full animated countdown and fade-to-hardware handoff remain a separate desktop acceptance check in `TESTING.txt`.
- Build 15 was installed and relaunched with the existing certificate and designated requirement verified.
