# Automatic private connection acceptance

## Implementation

- Existing settings migrate to Off. The host can opt in to private connection when locked or when all physical displays are asleep, or for every new connection.
- While the local desktop is unlocked and awake, Vela prepares a 2560 × 1440 HiDPI virtual display and a ScreenCaptureKit display filter. Settings distinguishes preparation from hardware verification.
- Authenticated discovery selects the prepared target without waking physical displays. The offer handler rechecks the policy and keeps the requirement for retries on the same authenticated session. The watchdog is armed before any display transaction.
- The host verifies that the virtual display is the only online output and the main display before requesting activity for a sleeping virtual display, if needed. Video starts on that display. Input remains blocked until a fresh frame arrives and the console and topology still match.
- The same authenticated console session stays active through lock and unlock. The browser and Vela Connect show the system lock screen and provide masked text helpers.
- Lock-and-restore confirms a macOS lock before requesting physical recovery. Showing the current desktop requires separate confirmation. Transport recovery can retain the isolated display for 30 seconds. The watchdog handles local input, topology changes, and host failure and attempts to lock first for automatic privacy. Watchdog recovery revokes the private connection's token so a browser retry cannot undo a local takeover.

## Automated evidence

- Debug build and Swift tests passed on Apple Silicon with macOS 27.0.1. Coverage includes legacy setting migration, the privacy policy matrix, retries that retain their privacy requirement, and the explicit restore override. The separately run synthetic browser transport test passed H.264 reception and frame-synchronized enhancement.
- All 19 web unit tests passed. Chromium fixtures passed 20 localization, 33 display-session, and 39 touch checks. Session checks cover the private lock screen, input availability, safe restoration, visibility confirmation, and media continuity through state changes.
- English and Simplified Chinese layouts passed at 320 × 700, 420 × 844, 421 × 844, 800 × 660, 801 × 660, and 844 × 390, including both automatic privacy restore buttons. The native viewport probe passed all 11 checks.
- English source, matching bilingual catalogs, and companion asset checks passed.

## Physical acceptance pending

The automated checks did not create a private session on the working desktop, lock the Mac, or measure a physical panel. Runtime symbols, successful display preparation, a logical topology check, and a fresh video buffer cannot establish that the macOS password UI renders or that a physical panel stays dark. No display, dock, and OS combination is recorded as verified.

With someone at the host and a separate controller, record the macOS build and display and dock combination. Observe every physical panel, including any backlight or monitor status prompt. Keep credentials and desktop captures out of the record.

| Scenario | Acceptance condition |
| --- | --- |
| Locked and physical displays asleep | Connect without a physical wake. See the genuine macOS password field on the virtual display, unlock, and verify pointer, keyboard, and text input. |
| Displays asleep and console unlocked | Connect to the virtual desktop with the physical panels dark. |
| Awake and unlocked | The conditional mode uses the ordinary connection. Always mode isolates physical displays before remote video. |
| Lock and unlock in an isolated session | Video switches to the real lock screen and back while physical outputs stay isolated. |
| Short and prolonged transport failure | Reconnect within the grace period on the virtual display. After expiry, observe the locked console and restored original layout. |
| Remote restore | Verify lock before restoring physical displays. Confirm that the separate visible restore action displays the desktop only after confirmation. |
| Local input, dock changes, and host failure | Verify the local escape and watchdog restore the available physical outputs and preserve recovery when hardware is temporarily disconnected. |
| Missing permissions, unavailable virtual capture, or changed console user | Verify that the private connection fails or ends with input disabled and no ordinary connection fallback. |

CoreGraphics treats sleeping and mirrored displays as online, so the isolation check includes those outputs. [Apple CoreGraphics documentation](https://developer.apple.com/documentation/coregraphics/cggetonlinedisplaylist(_:_:_:))
