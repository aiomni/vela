# GitHub Actions release packaging — 2026-11-03

The workflow runs automatically only for pushed `v*` tags. Main-branch pushes
do not trigger builds or artifact uploads. Manual dispatch requires an existing
version tag and offers an explicit publish option. Version tags are validated
before packaging and must identify the checked-out commit. The workflow does
not create tags, move tags, or overwrite published releases.

The build job uses GitHub's official Xcode 27 arm64 hosted image, commit-pinned
actions, read-only repository permissions, and Python/Node/Swift checks. It
packages Vela with its embedded Vela Connect controller, including localized
resources and third-party notices. Numeric tag versions and the workflow build
number are applied to both bundles before signing. Archives include SHA-256
checksums and explicit signed/unsigned filenames. A separate Linux publish job
has repository write permission and verifies checksums before creating a Release.
Prerelease tags produce prereleases.

With no signing secrets, CI explicitly uses the unsigned offline bundle path.
With all three signing secrets configured, the P12 is decoded outside the
workspace into a temporary keychain, used for certificate lookup, then removed.
Partial secrets or signing failures stop the build. No local certificate or
private key is exported automatically, no keychain search list is changed, and
there is no ad-hoc signing fallback. Signing is optional; Apple notarization is
not implemented. This workflow produces Apple Silicon builds only.

Validation:

- Actionlint passed. Its custom-label configuration accounts for the official
  Xcode 27 image not yet present in the linter's built-in runner list.
- Six release tests passed, including tag-only events, required manual tags,
  minimal job permissions, tag/checkout agreement, safe version outputs,
  prerelease handling, and rejection of partial signing configuration.
- Local unsigned CI packaging passed; ZIP integrity, checksums, application
  permissions, embedded controller, and both bundle versions were verified.
- The existing local fixed-certificate packaging path passed strict signature
  verification with the updated script. The GitHub secret-import path has not
  been exercised with a production certificate.
- Source localization, companion integrity, Node tests, and Swift tests passed.

No version tag or GitHub Release was created during validation, so the hosted
runner and publication steps will first execute when a version tag is supplied.
Main updates intentionally cannot be used to start that validation. Installed
applications, active remote connections, local signing keys, and dist artifacts
were left unchanged; local CI test artifacts remain ignored under `.build/`.
