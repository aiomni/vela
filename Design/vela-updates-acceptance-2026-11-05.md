# GitHub release updates acceptance — 2026-11-05

## Behavior

Vela checks the public GitHub latest-release endpoint at launch and hourly thereafter when the last successful check is at least 24 hours old. Checks can be disabled in General settings. Neither checks nor language changes restart services. A new stable semantic version exposes **Install and Restart** in Settings; the menu also indicates that an update is available.

Installation requires an explicit click. The app downloads the architecture-matched signed ZIP, verifies its GitHub SHA-256 digest and exact size, validates archive paths and expansion size, and checks the bundle version, minimum OS, identifiers, nested signatures, current certificate-bound designated requirement, and signing certificate. The bundled controller must use the same certificate. Unsigned assets are never selected. Requests use ephemeral sessions, bounded timeouts, and HTTPS redirects restricted to GitHub download hosts. API rate limiting has a separate localized status.

After verification, Vela closes the bundled controller and launches the downloaded app in temporary installer mode. The current app exits only after the installer reports readiness. The installer waits for the existing normal termination path, including remote shutdown and physical-display recovery, before modifying the app. It copies to the destination volume, validates again, and atomically exchanges the app directories with `renameatx_np(RENAME_SWAP)`. Replacement or launch-request failure restores the old app; if rollback itself fails, the old copy remains at the staged path. Successful launch requests remove the old copy and the private download staging directory. No persistent updater daemon or privileged helper is added.

Installation requires a writable app and parent directory, outside mounted disk images and App Translocation. Different signing certificates require a manual installation. Vela Connect updates within the main bundle. Existing preferences and remote files are reused; manual keep-awake does not resume after restart. This is an installer rollback, not crash monitoring of a running new version.

## Validation

- Full Swift tests passed, including nine updater tests for version ordering, signed-asset selection, metadata validation, digest tampering/truncation, archive paths/expansion limits, cleanup boundaries, unsigned rejection, atomic replacement, and rollback.
- `python3 Tests/Updates/run-signed-fixture.py` passed. Inert temporary bundles signed with the existing fixed certificate exercised actual validation, atomic replacement, LaunchServices relaunch, and modified-resource rejection. They never start a host or acquire power assertions, and do not modify installed applications.
- Production download preparation passed against the real signed v0.0.3 ZIP: download, digest/size checks, safe extraction, original signature validation, and cleanup. Metadata was obtained using the authenticated GitHub CLI because the development network's unauthenticated API quota was exhausted; no token is embedded or required by the shipped updater.
- Native self-test passed with no inconclusive rendering reports. It includes existing settings layout, language/pending-edit preservation, input, assertion ownership, and shutdown checks. The standalone preview executable could not be attached through the computer-use app picker; no manual native preview is claimed.
- All 19 web tests and all seven release packaging tests passed.
- Localization and companion integrity checks passed; both translation catalogs match.
- Signed v0.0.4 packaging, strict signature verification, both bundle version checks, and plist lint passed.
- `git diff --check` passed.

No real-app replacement, lockscreen, blackout, or closed-lid probe was performed for this feature. The updater's real replacement/relaunch test used inert temporary fixture apps.

## Reference contracts

- [GitHub release API and asset digests](https://docs.github.com/en/rest/releases/releases)
- [Apple code signing services](https://developer.apple.com/documentation/security/code-signing-services/)
