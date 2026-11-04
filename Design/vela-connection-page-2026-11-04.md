# Vela connection page acceptance

Date: 2026-11-04 (Asia/Shanghai)

The browser login now uses a centered, bounded connection card with a smaller
display icon, an action-oriented title, a clear password/button hierarchy, and
encryption and host-permission notes below the form. The layout scrolls naturally
on short viewports. The header keeps branding and language selection together.
The English and Chinese catalogs include the new title. Authentication and
session code were not changed for this work; pre-existing workspace changes were
preserved.

Validation:

- `node --test Tests/WebClient/*.test.cjs`: 18 passed.
- `python3 scripts/check-localization.py`: passed, 809 matching translations.
- `python3 scripts/check-companion.py`: passed, original assets preserved.
- `git diff --check`: passed.
- Real in-app browser with `Tests/WebClient/mock-server.py`: localization 19,
  private-session 25, and touch 39 checks passed in the prescribed order.
- Login bounds and horizontal overflow checked in both languages at 320×640,
  390×844, 520×720, 521×720, 800×720, 801×720, 1100×720, 1101×720,
  844×390, 1440×900, and 2056×1290. All passed. The default 1280×720
  login fits without vertical scrolling. Desktop and phone screenshots inspected.
- Existing responsive session fixture passed in both languages at 320×640,
  520×720, 521×720, 800×720, 801×720, 1100×720, 1101×720, 844×390,
  and 1440×900 (62 or 64 assertions per viewport).

The session fixture advertises only H.264 SDP and synthetic canvas video. An
initial run with the browser's HEVC capability exposed a fixture reconnection
failure. The completed fixture run filtered HEVC from the browser's advertised
codecs in test memory to match that H.264 fixture. Reloading clears this temporary
override. This validates interface behavior, not HEVC decoding or a real remote
desktop. No live input, power, lock-screen, or physical-display probes were run.
No signed app bundle was rebuilt or installed.

## Follow-up: direct language buttons and simpler grouping

Both language selectors now use persistent EN / Chinese-autonym buttons with
synchronized pressed states, native keyboard activation, and localized accessible
names. The autonym is loaded from the shared catalog and stays the same in either
interface language. Selection still preserves inputs, preferences, and peers.

The final login removes the decorative screen icon, gradient background, and
repeated tagline. The card groups the connection task and its encryption status;
host preparation notes sit directly below it in larger secondary text. The page
has one primary action and uses spacing to separate related information.

Follow-up validation: 18 Node tests, localization (810 matching entries), companion
integrity, and diff whitespace checks passed. Browser localization now has 20
passing assertions using actual language-button clicks, including clicks on their
inner labels. The H.264 fixture passed 25 private-session and 39 touch assertions.
The updated session layout fixture passed 70 or 72 assertions at 320×640,
520×720, 521×720, 800×720, 801×720, 1100×720, 1101×720, and 844×390.
The final simpler login passed bounds/overflow checks in both languages at all
11 login viewports listed above. Final desktop and 390×844 phone screenshots were
visually inspected. Browser viewport overrides were cleared after verification.

## Follow-up: flat visual treatment

The login now sits directly on the page without a card background, border, or
shadow. Inputs and the primary action use solid fills and 6-pixel corners. Host
notes align with the form below a single divider. EN / Chinese-autonym switches
use text and an underline for the selected language, with native focus outlines
and forced-color selected-state support preserved.

Validation: 18 Node tests, localization, companion integrity, and diff whitespace
checks passed. Browser language-button integration passed 20 assertions. Login
bounds passed in both languages at all 11 viewports listed above; desktop and
390×844 phone screenshots were inspected. Session responsive checks passed at
1280×720, 320×640, 800×720, 801×720, 1100×720, 1101×720, and 844×390
(70 or 72 assertions per viewport). Viewport overrides were reset. No signed
bundle was rebuilt or installed.

## Follow-up: remove redundant copy

Removed the header subtitle, duplicate password instructions and placeholder,
passive encryption caption, and decorative button arrow. The action now reads
Connect. Host preparation guidance uses a native, initially collapsed Host setup
disclosure. Password fields retain visible labels; Mac account mode names the
account in that label. The transient authentication-loading status and failure
feedback remain available.

Validation: 18 Node tests, JavaScript syntax, localization (812 matching entries),
companion integrity, and whitespace checks passed. In the H.264 browser fixture,
localization passed 20 assertions, private-session behavior 25, touch 39, and
session layout 70. Both authentication modes were checked; the Mac account name
stays opaque across language changes, autocomplete stays off for account mode,
and authentication failures disable submission while showing the error. Retrying
restores submission. Setup expansion survives language changes and supports Enter
to collapse. Login layout passed 44 combinations: both languages, open/closed
setup, and all 11 viewports listed above. Final desktop and phone screenshots were
inspected. Viewport overrides were reset; no signed app was rebuilt or installed.

## Follow-up: connection button refinement

The primary action uses a muted sage fill and medium-weight 14-pixel text. Input
and button share a 44-pixel height and 8-pixel corners. Hover and press have solid
fill states; disabled controls use an explicit subdued palette. Keyboard focus
retains a visible outline. No shadows, gradients, extra icons, or copy were added.

Validation: 18 Node tests, localization, and diff whitespace checks passed. Browser
localization passed 20 assertions. The button label fit and equal input/button
heights passed in both languages at 320×640, 390×844, 844×390, and 1280×720.
Tab navigation focused the button with a visible outline. Disabled colors were
checked in the browser, and the normal screenshot was visually inspected.
Viewport overrides were reset. No signed bundle was rebuilt or installed.

## Follow-up: macOS lock-screen-inspired login

The login uses a centered circular computer symbol, identity heading, and compact
password field. The wide Connect action is replaced by a subdued arrow inside
the field with a 40×40 target. Its Connect name and tooltip remain localized,
and the password retains an associated screen-reader label. Native required-field
validation, Enter submission, and keyboard focus indicators are preserved.

Custom-password mode shows Your Mac and an Access password placeholder. Account
mode shows the actual account name and a Password placeholder. Account headings
are excluded from translation so names that match localization keys stay opaque.
The existing collapsed host-setup guidance and EN / Chinese-autonym buttons remain.

Validation: 19 Node tests, JavaScript syntax, localization, companion integrity,
and whitespace checks passed. The isolated H.264 fixture passed localization 20,
private-session 25, touch 39, and session layout 70 assertions. Actual Enter and
arrow-icon clicks each connected the fixture; empty Enter submission was rejected.
Keyboard focus reached the arrow with a visible outline. Account identity and
password autocomplete were checked in both languages, including an account named
Connect, and switching back to custom mode restored the translated heading.
Custom mode and a long-account-name mode passed both-language layout checks at
all 11 login viewports above (44 combinations). The arrow stayed within the field
and retained its target size. Final desktop and phone screenshots were inspected;
host guidance expanded without phone overflow and collapsed with Enter. Viewport
overrides were reset and test tabs closed. No real desktop input or lock-state
changes were made. No signed app bundle was rebuilt or installed.
