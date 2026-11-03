# Vela expression restoration — 2026-11-03

The user clarified that removing descriptive character references must preserve
all existing artwork and expressions. The earlier character replacement was
outside that scope and is superseded by this restoration.

The complete companion asset was recovered from the previously installed app.
The restored file matches that original byte-for-byte, including all 19 shapes,
25 paired eye poses, and 39 expression records with their original eye playlists,
hold durations, and blink timing. The existing 22-mood automatic cycle is unchanged;
the other expression records remain retained and usable through mood overrides.
The original default shape, face placement, flat colors, and gradient stops were
restored. The temporary replacement silhouette and its rendering masks were
removed, and the documentation icon was regenerated from the restored character.

`scripts/check-companion.py` checks asset counts, reference validity, and the
original asset checksum to prevent future cleanup from changing these resources.
The agent instructions now explicitly separate descriptive text cleanup from
artwork and animation changes. The third-party notice retains factual provenance
and upstream usage restrictions without promotional character descriptions.

Validation passed:

- Debug build and all 36 Swift unit tests.
- All 9 web unit tests and the localization check with 742 matching translations.
- Asset integrity and byte-for-byte comparison against the installed resource.
- Full native self-test, including all 22 cycling moods, all 39 expression
  previews, shape morphing, material effects, native language switching, and
  lifecycle cleanup. Live rendering checks were conclusive.

Builds, logs, and test previews were produced outside the project in a temporary
validation directory and removed after verification. No release bundle was kept,
installed application replaced, or repository content uploaded.
