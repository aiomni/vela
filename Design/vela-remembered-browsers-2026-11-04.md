# Browser device memory

Date: 2026-11-04 (Asia/Shanghai)

## Behavior

Browser password sign-in offers an initially unchecked Remember this device for
30 days option. A remembered browser can reload or reopen the same host address
and receive a short access session automatically. Ordinary Disconnect revokes
the short session and ends media/input, while keeping browser authorization.
On the login screen, the arrow can reconnect without a password. Unchecking the
option or choosing Host setup → Forget this device revokes that browser grant.
Changing authentication, the Vela custom password, remote configuration generation,
or certificate invalidates grants. The host's Disconnect all sessions counter
also revokes them. An ordinary Vela restart preserves valid grants.

Vela Connect keeps its existing authentication flow. Remembered browser access
does not unlock macOS or bypass the real lock screen, account boundaries, TCC,
FileVault, or single-controller ownership. System-account policy and identity are
checked again during every resume. Changing an OS account password alone is not
used as a browser-grant rotation signal; host-side revocation remains available.

## Credential and protocol design

- Each browser grant is a fresh 256-bit random secret, sent only as a Secure,
  HttpOnly, SameSite=Strict, host-only cookie with Path=/ and a 30-day Max-Age.
  The __Host- cookie name includes the configured port to avoid replacing other
  Vela instances' cookies. Cookies themselves are host-scoped, not port-isolated.
- Host persistence contains SHA-256 hashes, issue/expiry dates, and an opaque
  configuration/certificate binding. It contains neither raw grants nor passwords.
  The registry uses the existing remote directory, with 0700 directory and 0600
  file permissions; parsing is bounded to 64 KiB and 32 grants.
- The binding includes authentication generation, mode, account identity, custom
  password verifier, disconnect generation, port, and certificate fingerprint.
- Device cookies authorize only POST /api/device/resume and /api/device/forget.
  Both require the exact same HTTPS Origin and JSON requests. All control APIs
  continue requiring their existing short-lived Bearer token.
- The existing eight-hour absolute and two-minute idle session lifetimes remain.
  Repeated resume may reuse a still-valid in-memory session owned by the same
  browser, avoiding session exhaustion or takeover of an unrelated controller.
- Resume is rate/concurrency bounded. After asynchronous account-policy checks,
  it rechecks configuration, lifecycle epoch, and grant revocation before issuing
  a session. Cookie replacement/opt-out revokes the preceding associated session.
- No production password or credential is put in localStorage. Browser fixtures
  use only a boolean simulation flag, explicitly separate from real credentials.

References: [MDN cookie guidance](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Cookies)
and [OWASP session-management guidance](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html).

## Validation

- Full `swift test`: 61 tests executed, one optional synthetic-browser harness
  skipped, no failures. After the final session-capacity response adjustment,
  all five remembered-browser unit/TLS/policy tests passed again.
- Real isolated HTTPS tests verified cookie flags, opt-in, cross/missing Origin
  rejection, cookie-only control API rejection, logout versus forgetting, host
  restart, host revocation, password changes, opt-out, and short-session revocation.
- Account-mode tests denied remembered access when account policy disallowed it,
  and verified that revocation during in-flight policy validation cannot mint a
  session. Unit tests cover expiry, replacement, hash-only persistence, permissions,
  corrupt data, context binding, duplicate cookies, and header-injection rejection.
- Node web tests: 19 passed. Localization: 830 matching entries. Companion integrity
  and whitespace checks passed.
- H.264 mock browser: localization 20, private-session 25, touch 39, responsive
  session layout 70, and remembered-browser flow seven assertions passed.
- Actual fixture-page reload after enrollment automatically connected with zero
  password requests and one device-resume request. Forgetting and reloading
  restored required password entry. Unchecking the remembered option also removed
  trust and restored the password field.
- Password and remembered states passed both-language layout checks at 320×640,
  390×844, 520×720, 521×720, 800×720, 801×720, 1100×720, 1101×720,
  844×390, 1440×900, and 2056×1290 (44 combinations). Desktop UI inspected.

Mock-browser reload tests simulate a cookie with a non-secret fixture flag; real
TLS tests exercise server cookie headers and credential validation. These checks
do not claim an installed-app/browser-certificate-trust test or alter OS trust.
Clearing cookies, private browsing, another profile/address, expiry, or revocation
can require another password sign-in.

## Local signed update package

Built with the existing signing configuration using
`VELA_OUTPUT_DIR="$PWD/dist/remembered-browser" ./scripts/build-app.sh release Vela`.
The main app and embedded Vela Connect passed `codesign --verify --deep --strict`;
both Info.plist files passed `plutil -lint`. The signed bundle's browser assets
contain device memory and exclude fixture storage. A ZIP and verified SHA-256
file are under `dist/remembered-browser/`. No installed application was replaced
or launched, and no notarization was performed by this local build.
