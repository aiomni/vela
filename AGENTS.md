# Working on Vela

## Product and architecture

Vela is a native macOS 26+ companion with manual keep-awake, local Agent watch, and authenticated remote desktop. Its tagline is **Keeping watch. Keeping you connected.** The native controller is **Vela Connect**.

This is a Swift Package Manager project using Swift tools 6, AppKit, IOKit, Carbon, ScreenCaptureKit, Metal, WebRTC, SwiftNIO, and NIOSSL. Remote targets intentionally compile in Swift 5 language mode. Keep dependency versions pinned in `Package.swift` and `Package.resolved`.

- `Sources/Vela`: main app, menu bar, settings, pet rendering, power/Agent state, and development probes.
- `Sources/VelaConnect`: native remote desktop controller.
- `Sources/VelaLocalization`: shared English-key localization and AppKit language controls.
- `Sources/RemoteCore`: protocol, configuration, password/session validation, and authentication. This layer has no AppKit dependency.
- `Sources/RemoteRTC`: screen capture, codec/peer handling, input, virtual displays, and physical display recovery.
- `Sources/RemoteServer`: app-owned HTTPS/WebRTC host lifecycle and the browser client in `Web/`.
- `Sources/RemoteDisplayBridge`: Objective-C bridge for runtime-checked display APIs.
- `Sources/LidServiceShared`: closed-lid command output parsing.
- `Sources/LockLab`: separate power/lock behavior experiment; do not fold it into normal startup.
- `Tests`: Swift tests and isolated web fixtures. `Design/` contains historical plans and acceptance evidence.

## Setup and build

Run commands from the repository root:

```sh
swift package resolve
swift build -c debug
./scripts/build-app.sh release Vela
```

The signed artifact is `dist/Vela.app`; its embedded controller is `Contents/Applications/VelaConnect.app`. `VELA_OUTPUT_DIR` overrides the signed output directory. `./scripts/build-app.sh release Vela --offline-check` builds an unsigned structure-check bundle under `.build/offline-bundle`.

Packaging reads `SIGNING_IDENTITY`, then `.signing-identity.local`. Do not print or commit local signing configuration, replace the certificate, fall back to ad-hoc signing, or weaken certificate-bound designated requirements. The script signs embedded frameworks and the controller before the main app. It does not notarize or replace the installed app automatically.

## Language and naming conventions

- Use **English only in source code**, identifiers, comments, diagnostics, and base HTML/plist content. Keep `README.md` and this file in English. Maintain `README.zh-CN.md` alongside the English README.
- User-facing native strings use `L("English text")` from `VelaLocalization`. Use numbered placeholders such as `L("Display {0}", String(id))` for dynamic values. Do not interpolate dynamic values into localization keys. Arguments are opaque; localize nested UI labels explicitly and preserve account/display names.
- Chinese translations belong in `Sources/VelaLocalization/Resources/zh-Hans.json` and `Sources/RemoteServer/Web/locales/zh-Hans.json`. Keep these catalogs identical and preserve placeholder numbers. Localized bundle descriptions belong in `Resources/Vela*/{en,zh-Hans}.lproj/InfoPlist.strings`.
- English is the default independently of macOS/browser language. Native apps store `velaLanguage`; the browser stores `vela.language`. A language change must not restart services, reconnect peers, modify input values, or alter keep-awake state.
- Browser code uses `VelaI18n.t` / `t` for dynamic UI and English fallback HTML for static content. Translate server errors at presentation boundaries. Keep protocol keys and server messages in English.
- Keep translated toolbar labels inside their buttons. At narrow widths separate session actions from the tool row, preserve horizontal reachability at minimum widths, and keep status text separate from video metrics. Validate the real browser layout in both languages using the responsive fixture, including breakpoint boundaries and a short landscape viewport.
- Use stable enum/raw IDs for behavior and preferences, never translated labels. Update menus, tooltips, accessibility labels, segmented controls, and hidden popovers when adding UI.
- Keep all production branding Vela / Vela Connect. The legacy bundle IDs and data path below are deliberate compatibility exceptions. Historical Design records and original third-party notices may retain older names or languages.
- Settings use native split-view sidebar navigation and a Liquid Glass toolbar, compact grouped rows, semantic system colors, and native switches/sliders. Do not add a settings search field or decorative page introductions. Only Chinese settings navigation titles use two characters; English navigation remains English.
- Settings switches use `SettingsStyle.compactSwitch()` and the native `.mini` control size, matching System Settings proportions. Do not scale or redraw the switch; preserve native state, actions, keyboard input, and accessibility.
- Manage Input Monitoring under Awake and remote input control under Remote. Use Device Control and Data Access terminology on macOS 27+, Accessibility on macOS 26, and keep Screen Recording requirements visible. Permission status must use current preflight checks even when remote access is off; settings links must not require an active host.
- Use `VelaScrollView` from the shared AppKit helpers for app-owned scroll regions. Its overlay thumbs stay narrow and translucent until hovered or dragged, without reducing native hit targets or resizing the viewport. Keep equivalent web scrollbar rules global and preserve contrast/transparency accessibility fallbacks.
- App appearance is stored as `velaAppearance` using `light`, `dark`, or `automatic`. Default to automatic (`NSApp.appearance = nil`), apply the saved choice before creating windows, and restore automatic on reset. Theme changes must not affect power, Agent, or remote state.
- Keep settings pages attached when switching categories so pending edits and controller state survive navigation. Language changes must preserve unfinished numeric fields and custom agent names. Agent popup values use represented objects, never parsing translated titles.

## Compatibility requirements

Retain `app.aiomni.awakepet` for Vela and `app.aiomni.awakepet.remoteviewer` for Vela Connect. Renaming identifiers can invalidate TCC grants and system login registration.

`RemoteFiles.defaultDirectory` reuses an existing `AwakePet/RemoteControl` store in place; otherwise it uses `Vela/RemoteControl`. The old store wins if both exist so old and new versions share a runtime lock. Do not copy over existing keys, reset passwords, regenerate certificates solely for branding, or start multiple remote hosts against separate stores.

## Validation

Run checks relevant to changes:

```sh
swift test
node --test Tests/WebClient/*.test.cjs
python3 scripts/check-localization.py
python3 scripts/check-companion.py
.build/debug/Vela --watch-policy-test
.build/debug/Vela --self-test
```

`--self-test` opens temporary windows and briefly exercises real IOKit assertions. It uses isolated app and remote preferences, but needs a visible desktop for conclusive live rendering checks. Record inconclusive rendering checks honestly.

For browser integration, start `python3 Tests/WebClient/mock-server.py --port 8769`. In a fresh context load `/language-tests.js` and call `runLocalizationChecks()` first, then load `/session-tests.js` / `runPrivateSessionChecks()` and `/touch-tests.js` / `runTouchChecks()`. These fixtures change no real desktop state. Check both languages and narrow layouts when changing UI.

For packaging changes, also verify the bundle:

```sh
codesign --verify --deep --strict dist/Vela.app
plutil -lint dist/Vela.app/Contents/Info.plist
```

Do not run `scripts/verify-lid-live.sh`, lockscreen probes, or blackout probes as routine tests. They request administrator approval, change real power/display state, or inject input. Use them only when those real-device actions are within the user's requested work, and preserve recovery behavior.

## Behavioral constraints

- No keep-awake assertion at normal startup. Manual sessions do not automatically resume; explicitly enabled remote access follows the main app lifecycle.
- Manual, Agent, and remote keep-awake owners must not release each other's assertions.
- Preserve physical-display recovery ordering, local-input escape, watchdog heartbeat handling, and original topology restoration. Turning off physical displays is not password locking.
- Ordinary lock-screen control uses macOS's real password interface. Never bypass TCC, FileVault, authentication, system lock policies, or account boundaries.
- Remote control is single-controller, authenticated, and encrypted. Preserve Origin/Host validation, password derivation, rate limits, certificate pinning/trust, session expiry/revocation, and input release on blur/disconnect.
- Do not add remote helpers or persistent privileged daemons to replace the app-owned host or temporary recovery monitors without an explicit requirement.
- Keep secrets, passwords, keys, private screen data, and full process command lines out of logs and fixtures.
- Preserve bundled third-party dependency notices. Preserve all existing companion shapes, eye poses, expression playlists, and timing data. Requests to remove character branding or descriptive references must not change artwork or animation. Run `scripts/check-companion.py` to detect unintended asset changes. Preserve the asset provenance and upstream usage restrictions in the third-party notices.

## Documentation and evidence

Keep README instructions executable and describe current behavior. `TESTING.txt` distinguishes automated checks from intrusive live verification. Older `Design/` records are historical; do not rewrite past evidence to claim new testing. Record material changes and current validation in a new dated acceptance record when appropriate.
