# Vela companion artwork acceptance — 2026-11-03

Historical record, superseded by `vela-expression-restoration-2026-11-03.md`.
The user clarified that only descriptive references should be removed; replacing
the artwork and expressions was outside the intended scope and has been reversed.

Vela now uses a self-contained procedural lantern character. The retired external
reference character, downloaded geometry, face tables, palette tables, extractor,
reference illustrations, and affected historical design records have been removed
from the project. Previous local builds and reference backups were moved to a
private archive outside the project directory. The installed application was not
replaced, and no repository content was uploaded.

## Current artwork

`scripts/generate-companion.py` constructs the asset from elementary curves and
locally authored parameters without network access or external artwork inputs.
It produces 19 silhouettes, 25 paired eye poses, and 22 mood playlists. The default
lantern has a rounded body, a handle with a transparent opening, an inset visor,
and a small lower light. Its base palette is independently specified in Swift.

The generated asset declares schema version 2 and the authoring tag
`Vela procedural lantern v1`. Comparing it with the archived asset found no
unchanged shape records, no reused eye polygon pairs, and no unchanged mood
records. Existing nondefault shape preference identifiers remain stable; the
retired default identifier falls back to the lantern.

Both live Metal rendering pipelines use the lantern silhouette, including its
transparent handle opening. Other material effects and nondefault shape rendering
remain available. App icons and the README image were regenerated from the new
character. Third-party software dependency notices remain included.

## Validation

- Debug build and signed release packaging succeeded.
- All 36 Swift unit tests and 9 web unit tests passed.
- Generator reproducibility and localization checks passed; both catalogs retain
  742 matching translations with English source keys.
- The packaged application's native self-test passed, including all 19 shapes,
  25 eye poses, 22 moods, material effects, native language switching, state
  synchronization, and lifecycle cleanup. Live rendering checks were conclusive.
- Added native checks verified the vector silhouette and both live GPU masks:
  body and handle are visible, while the handle opening and outer corners remain
  transparent.
- Strict deep code-signature verification and the main bundle plist check passed.
- Scanning source, tests, scripts, resources, design records, documentation, and
  the signed distribution found zero references to the retired upstream character
  name, author, or pinned source revision.
- Packaged geometry and dependency notices match their source files; the README
  image matches the regenerated icon.

Logs and generated previews are local build outputs under `.build/`; the signed
application is `dist/Vela.app`. Browser integration, intrusive lid/display tests,
and installed-app replacement were not part of this artwork change. This record
does not supersede the separate repository privacy audit.

## Subsequent workspace cleanup — 2026-11-03

After validation, the build cache, signed distribution, and temporary private
archive containing retired references and previous builds were deleted at the
user's request. Generated logs and previews are therefore no longer retained.
Build and macOS metadata ignore rules were expanded, historical personal paths
and device addresses were sanitized, and network fixtures now use synthetic
addresses. The two network selection tests passed after recompilation.
