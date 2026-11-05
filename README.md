<p align="center"><img src="docs/assets/vela.png" width="96" alt="Vela companion"></p>

# Vela

**Keeping watch. Keeping you connected.**

[Chinese version](README.zh-CN.md)

Vela is a native macOS desktop companion that keeps your Mac available while you work, watches local coding agents, and lets you reconnect to your desktop from another device. It combines a small interactive character with practical keep-awake and remote desktop controls.

## Features

- **Desktop companion:** draggable shapes, expressive eyes, automatic moods, independent awake/resting colors, gradients, and live Metal effects. Hide the companion without stopping other features. The app and menu bar use a fixed monochrome companion icon, independent of companion appearance and keep-awake state.
- **Keep-awake controls:** keep the display awake, allow display sleep while the system runs, or continue with the lid closed. Choose an unlimited or custom duration; timed mode can start after continuous physical inactivity and reset on input.
- **Agent watch:** detect Claude Code, Codex, Gemini CLI, Cursor Agent, Copilot CLI, Aider, OpenCode, and custom executable names. Choose working-agent detection or process-presence keep-awake, with an idle grace period and battery/thermal protection.
- **Remote desktop:** connect with a WebRTC browser or the included **Vela Connect** Mac app. Select displays and streaming quality, send keyboard/mouse input and text, and use touch controls or desktop-switching gestures.
- **Virtual displays:** create a remote display with custom resolution and HiDPI. Optionally turn off physical displays while working on the virtual display; local input, disconnection, and recovery handling restore them.
- **Native settings:** five sidebar pages with compact grouped controls, a Liquid Glass navigation toolbar, and native switches and sliders. Choose Light, Dark, or Auto appearance; Auto follows the system. Accessibility preferences remain respected.
- **English and Simplified Chinese:** English is the default regardless of system language. Change the native app in **Settings → General → Language**, Vela Connect in its toolbar, or the website using its language selector. Selections persist independently, and switching does not restart remote sessions.

## Requirements

- macOS 26 or later and Swift 6 tooling / Xcode command-line tools.
- Network access for the pinned Swift Package Manager dependencies.
- A stable code-signing certificate for a usable app bundle. The build script reads `SIGNING_IDENTITY`, then `.signing-identity.local`; it never falls back to ad-hoc signing.
- Node.js for web unit tests; Python 3 for localization checks and browser fixtures.

## Build and run

```sh
swift package resolve
./scripts/build-app.sh release Vela
open dist/Vela.app
```

The package includes Vela Connect at:

```text
Vela.app/Contents/Applications/VelaConnect.app
```

Open it from **Settings → Remote → Open Vela Connect…**. Packaging signs and verifies both apps and their WebRTC frameworks. It does not notarize or automatically install the build into `/Applications`.

To create a disk image from the signed bundle:

```sh
./scripts/create-dmg.sh dist/Vela.app dist/Vela.dmg
```

Open the DMG and drag Vela to Applications. The disk image preserves the app's existing signature.

## Automated releases

The [release workflow](.github/workflows/release.yml) runs only when a `v*` version tag is pushed. Updates to `main` do not start builds or generate artifacts. You can also run it manually from Actions using an existing version tag; select `publish` to publish that tag's Release.

```sh
git tag v1.2.3
git push origin v1.2.3
```

The workflow validates the version, runs Swift/Python/Node tests, builds both apps on the official [Xcode 27 arm64 image](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/), and uploads DMG and ZIP downloads with SHA-256 checksums to Actions and GitHub Releases. Tagged versions update both apps' bundle versions; prerelease tags such as `v1.2.3-beta.1` create prereleases. It requires no personal GitHub token and does not create or move version tags or overwrite existing releases.

Without signing secrets it produces an explicitly named `unsigned` testing bundle. To sign with a fixed certificate, configure all three repository Actions secrets in **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded P12 containing the signing certificate and private key |
| `MACOS_CERTIFICATE_PASSWORD` | P12 export password |
| `MACOS_SIGNING_IDENTITY` | Certificate SHA-1 or signing identity name |

The certificate is imported into a temporary keychain and deleted after packaging. Partial signing configuration or signing failure stops the build; it never falls back to ad-hoc signing. Keep the same certificate to preserve permissions across updates. CI builds currently target Apple Silicon only and are not notarized. No local certificate or private key is uploaded automatically.

For compilation or unsigned bundle structure checks:

```sh
swift build -c debug
./scripts/build-app.sh release Vela --offline-check
```

The unsigned check output is `.build/offline-bundle/Vela.app`. Set `VELA_OUTPUT_DIR` to place signed builds in a different directory.

## Everyday use

Vela starts with keep-awake off and the companion visible. Use the menu bar or hover over the companion to reveal keep-awake, Agent watch, mode, and Settings controls. The default global shortcut is **Control + Option + Command + K**.

Manual and Agent keep-awake share the selected mode. Agent working detection uses a `caffeinate` child process or roughly 60 seconds of CPU activity; choose process-presence mode for low-CPU network waits. Detection is local to the current user, so remote or container processes are not visible.

Settings include duration, idle threshold, Agent grace time, battery threshold, custom agent names, login startup, appearance, and language. Keep-awake starts off after relaunch; explicitly enabled remote control resumes with the app.

Closed-lid sessions request administrator approval and temporarily manage `pmset disablesleep`. The recovery monitor restores the original setting after a normal stop, process exit, or heartbeat failure. It is not a persistent system daemon and cannot recover across a reboot before login. If a closed-lid session ends with a reboot or power loss, check `pmset -g` and restore `sudo pmset -a disablesleep 0` if needed.

## Connect remotely

1. In **Settings → Remote**, choose a custom password or the current local macOS account, then explicitly enable remote access. Custom passwords require at least 10 characters.
2. Grant Vela **Screen Recording** and **Device Control and Data Access** access (called **Accessibility** on macOS 26) via **Settings → Remote**. Manage **Input Monitoring** separately in **Settings → Awake** on the host Mac. Grant Local Network access if macOS requests it; follow any quit/reopen instructions.
3. Use an actual address shown by Settings, normally `https://IP:8443`. LAN-only or all-interface IPv4/IPv6 listening can be selected; all interfaces includes reachable VPN interfaces. Use brackets for IPv6, for example `https://[fd00::1234]:8443`. Only stable, ready IPv6 addresses are advertised. Temporary privacy addresses and addresses with unavailable state are excluded to preserve certificate trust; unspecified, multicast, and link-local addresses are also excluded; link-local scope identifiers are not supported. `0.0.0.0` and `::` are bind addresses, not connection destinations. VPN routing and access policies must permit both HTTPS and WebRTC media. Address changes can renew the certificate and require trust verification again.
4. In Vela Connect, verify the host's SHA-256 certificate fingerprint before trusting it. For a browser, export the public certificate, verify its fingerprint, and import it into the controller's trust store before entering a password. Never copy the private key.
5. Connect, choose a display, and use the on-screen input tools as needed. Only one controller is allowed at a time. Changing authentication or the access password revokes existing sessions.

**Browser device memory:** opt into **Remember this device for 30 days** at password sign-in. The same browser profile can then reload or reopen the same host address without entering the access password again; ordinary Disconnect keeps this authorization. To remove it, disconnect and use **Host setup → Forget this device**, or uncheck the option. **Settings → Remote → Disconnect all sessions**, changing Vela's authentication method or custom access password, disabling remote access, or changing the host certificate revokes remembered browser access. Credentials expire after 30 days, survive an ordinary Vela restart, and do not store the password. Clearing cookies, private browsing, or using another address/profile can require another password sign-in. Remembering the browser does not unlock macOS; the system lock screen still requires the current Mac password. Native Vela Connect is unchanged.

The selected macOS account is the local account running Vela. Its password is verified by macOS and is not stored. Touch ID and Apple ID passwords are not supported. For an ordinary locked session, remote access shows the real macOS lock screen; click its password field and enter the Mac password to unlock. This does not cover FileVault or the first login after boot.

Remote control needs direct network reachability over LAN or VPN. Vela does not configure router forwarding, a cloud relay, public STUN, or TURN. HTTPS provides the page and signaling; WebRTC negotiates its media ports, preferably UDP.

## Streaming quality

The host uses ScreenCaptureKit, VideoToolbox hardware H.264/HEVC, and WebRTC. Both controllers offer **Automatic**, **Text clarity**, and **Smooth motion** preferences alongside the existing resolution limits. Automatic fits the desktop to the controller's pixel viewport. Text clarity preserves resolution longer when bandwidth falls; Smooth motion permits earlier resolution reduction. The host reduces workload after sustained pressure and restores it gradually after measured recovery, without reconnecting for normal quality changes.

Both controllers offer **Fit window**, **100%** pixel-for-pixel viewing, and **150% / 200% / 400%** detail zoom. Zoom preserves the inspected position and requests the selected source quality rather than reducing capture to the window size; network adaptation and the chosen resolution limit still apply. Use scrollbars or Alt/Option-scroll to pan locally. On phones, pinch the remote picture with two fingers to zoom around that detail, then move two fingers to pan the enlarged picture. One-finger mouse input and both hardware and on-screen keyboards remain available. At Fit window, parallel two-finger motion still scrolls the remote computer; mouse-wheel scrolling always remains remote. Zoom cannot restore detail already lost in capture or transmission.

When content stops changing, a bounded refinement burst restores detail before returning to low-frequency refreshes. The browser Quality panel shows the active codec, host capture and received sizes, encoding/decoding times when available, and adaptive status. A low bitrate on a static desktop is normal.

**Lossless text enhancement** is optional and off by default in both controllers. It sends bounded PNG tiles from RGB capture only on a stable, uncongested desktop with sufficient measured bandwidth. H.264 in-band frame identities ensure tiles match the received video; incompatible browsers continue with video only. Tile traffic is capped at 10% of estimated bandwidth, at most 2 Mbps, and may cover only part of a large desktop. Frequent content changes can postpone it. Language changes preserve connections and selections.

Vela supplies hardware-only VideoToolbox HEVC adapters for the H.265 SDP/RTP support in pinned WebRTC 154.0.0. Vela Connect first validates a synthetic 4K adapter round trip; the host enables HEVC only after its own validation and peer opt-in. Browsers additionally require WebRTC H.265 Main-profile capabilities and a hardware-efficient WebRTC decoding capability result. H.264 remains available when either end lacks support, negotiation/initialization fails, or decoded frames stop progressing for six seconds outside session recovery. The displayed codec follows actual RTP statistics. HEVC uses 8-bit Main profile; enabling lossless enhancement switches to H.264. See [HEVC acceptance](Design/vela-hevc-end-to-end-2026-11-04.md) for verified results and limits.

## Virtual and physical displays

Create and select a virtual display in the web **Display** panel. There are 18 presets, including 13 portrait sizes grouped for phones, tablets, and higher resolutions, plus custom dimensions. For a phone, try 1080 × 2400 with HiDPI; its logical desktop is 540 × 1200. The maximum pixel budget is 3840 × 2160, including portrait layouts. HiDPI uses half-sized logical dimensions in each direction and requires at least 640 × 480 landscape or 480 × 640 portrait desktop points; the Quality panel shows actual received dimensions.

After confirming the virtual display works, open **Physical displays** to turn off the Mac's built-in and external physical displays. Remote input continues on the virtual display. Local keyboard/mouse input or **Restore all physical displays** restores them. Disconnection restores physical displays before closing the virtual one.

Turning off physical displays is not a password lock. Actual macOS locking restores physical displays and switches capture to the system lock screen. Unlocking returns to the previously selected desktop display. Display management uses runtime-checked private APIs and may change with macOS updates; macOS manages window movement during topology changes.

## Development and checks

```sh
swift test
node --test Tests/WebClient/*.test.cjs
python3 scripts/check-localization.py
.build/debug/Vela --watch-policy-test
.build/debug/Vela --self-test
```

The native self-test briefly creates real power assertions and test windows, then releases them. It uses isolated preferences and remote settings. Live Metal rendering checks require a visible desktop; obscured checks are reported as inconclusive.

For browser integration checks without changing the real desktop:

```sh
python3 Tests/WebClient/mock-server.py --port 8769
```

Open `http://127.0.0.1:8769` in a fresh browser context. Load `/language-tests.js`, `/session-tests.js`, or `/touch-tests.js` and call `runLocalizationChecks()`, `runPrivateSessionChecks()`, or `runTouchChecks()` respectively. Run the localization checks first in a fresh page. These fixtures replace WebRTC and API calls; they do not control your Mac.

See [AGENTS.md](AGENTS.md) for architecture, localization conventions, and agent workflows, and [TESTING.txt](TESTING.txt) for additional test boundaries.

## Compatibility and current limits

- Vela retains the existing `app.aiomni.awakepet` and `app.aiomni.awakepet.remoteviewer` bundle identifiers to preserve signing identity and system permissions. Keep the same signing certificate; a changed installation path can still require macOS approval.
- Existing `~/Library/Application Support/AwakePet/RemoteControl` data is reused in place, including its certificate and runtime lock. New installs use `~/Library/Application Support/Vela/RemoteControl`. The rename does not reset passwords or generate new certificates by itself.
- No audio, file transfer, clipboard synchronization, cloud relay, or pre-login access is implemented. Remote control does not itself keep a closed lid awake.
- The existing companion shapes, expressions, and animation sequences are preserved. Run `python3 scripts/check-companion.py` to check asset integrity. Asset provenance and upstream usage restrictions are documented in [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt), which is bundled with the app; these assets are not relicensed by Vela.
- Older files under `Design/` record historical development and acceptance results. They can contain the previous product name and superseded behavior.
