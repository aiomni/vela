# Vela disk-image packaging acceptance — 2026-11-04

The initial v0.0.1 release generated ZIP downloads only. Release packaging now
also creates a compressed, read-only DMG containing Vela.app and an Applications
symlink. Vela Connect remains embedded in Vela.app. No signing identity,
designated requirement, application binary, installed app, or version tag changes.

`scripts/create-dmg.sh` accepts an existing versioned bundle and a new DMG path,
copies the complete bundle with ditto, and verifies the resulting image with
hdiutil. Existing output files are rejected. CI creates both formats in its
existing signed or explicitly unsigned mode; SHA256SUMS covers both. The publish
job uploads both formats while retaining tag validation and existing permissions.

## Validation performed

- Shell syntax checks passed for all three packaging scripts.
- Seven release tests passed, including a real fixture DMG mounted read-only
  without opening Finder. The test verifies main/controller/resource bytes,
  executable permissions, the Applications link, and overwrite rejection.
- The actual unsigned CI packaging path completed locally with version 0.0.1,
  build 1. Both ZIP and DMG checksums matched SHA256SUMS; the ZIP integrity check
  and mounted DMG app/controller version checks passed.
- A supplemental v0.0.1 local DMG was created from the previously released
  version 0.0.1, build 5 signed bundle. Read-only mount verification confirmed
  deep strict codesign verification, both bundle plists, original file hashes,
  bundle symlinks, and the Applications link.
- The supplemental DMG and its separate SHA-256 file were uploaded to the
  existing v0.0.1 GitHub Release. GitHub asset digests matched local hashes.
  The original tag and ZIP/checksum assets were preserved. Release notes identify
  the local certificate and lack of Apple Developer ID signing/notarization.

No app was installed or launched, no real desktop controls were exercised, and
no signing keys or private signing configuration were included in artifacts.
The updated workflow has been exercised through its local packaging command;
no additional production tag was created solely to test it on GitHub Actions.
