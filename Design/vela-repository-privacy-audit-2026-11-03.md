# Repository privacy audit — 2026-11-03

The current source tree had no Git metadata. The designated GitHub repository
was empty, with no advertised branch or tag history. A new local main branch
was initialized for the first publication; no existing history was rewritten.

Scope and findings:

- Reviewed the exact staged source tree, documentation, archived acceptance
  notes, configuration templates, fixtures, and image metadata.
- Gitleaks 8.30.1 reported no leaks in the staged tree. Its official release
  archive was verified against the upstream checksum manifest. A second scan
  covers all reachable commits before pushing.
- Additional pattern checks found no provider tokens, private key blocks,
  credentials embedded in URLs, personal home-directory paths, or personal
  email addresses in the candidate files.
- Password literals belong to isolated test or explicit development fixtures.
  Private IP literals are synthetic network-test addresses or UI examples.
  Public bundle identifiers remain for application and permission compatibility.
- PNGs contain no personal text or GPS metadata; the small EXIF directories in
  exported app icons contain image dimensions only. Design sheets contain icons.
- Build products, dependency checkouts, local signing configuration, logs, audit
  outputs, environment files, macOS metadata, and runtime scratch data are
  excluded. Added private-key, PEM, P8, and keychain ignore patterns.
- Commit attribution uses the authenticated GitHub account's public no-reply
  address rather than a personal email address.

Localization and original companion asset integrity checks passed. Existing web
unit tests passed after giving the Connection settings heading a distinct Chinese
translation; its previous translation collided with the Connect action and
prevented the existing reverse-localization test from restoring the button text.
The preceding application release build, native control checks,
and strict signature verification passed; this audit changes no application logic
or artwork. Third-party provenance and usage restrictions remain documented in
`Resources/ThirdPartyNotices.txt` and are not altered by this privacy review.

Scanner output and redacted pattern findings remain local under ignored
`.build/privacy-audit/`. These checks found no sensitive material in the reviewed
publication set; automated scans do not establish an absolute guarantee.
