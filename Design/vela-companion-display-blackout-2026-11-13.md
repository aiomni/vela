# Companion display blackout

The companion’s **Disconnect physical displays** action is available with remote access enabled or disabled. It captures the current display arrangement before attaching one temporary virtual display per physical display. It uses the source display’s desktop dimensions and retains HiDPI when the backing dimensions fit the existing virtual display limits. For larger modes it uses a supported backing resolution. macOS manages application window placement when the display configuration changes.

Vela waits for Input Monitoring and the existing recovery watchdog before committing a session-scoped display configuration. A dedicated idle-display assertion keeps the virtual desktop awake. The action keeps the current console session and issues no lock or display sleep request. Local HID input restores the physical layout and removes the temporary displays. The watchdog also handles parent exit, heartbeat loss, session changes, and display topology changes.

The authenticated web and native controllers can select available virtual displays during companion blackout. The companion’s recovery stays independent of the controller disconnecting. The remote connection's existing privacy requirements still apply.

## Validation

- The focused native control check verifies the new icon, hover-bar layout, action routing with an inert callback, and disabled state while starting or active.
- Swift tests cover replacement resolution limits and decoding existing recovery records. The Swift and Node suites, catalog check, and companion asset check passed. Swift skipped the separately configured synthetic browser transport test.
- The release bundle was signed and passed strict recursive signature verification. Both application property lists passed validation.
- The browser fixture covers local-only restoration and display selection in companion blackout, ordinary remote blackout and restoration, and automatic privacy. Localization, touch, and bilingual responsive layout checks ran in headless Chrome at 320 × 780, 568 × 320, 768 × 900, 844 × 390, 1100 × 500, 1101 × 500, and 1440 × 900.
- The existing closed-lid watchdog fixture in `--watch-policy-test` failed on both the new debug build and the already-installed build.
- Read-only display enumeration on macOS 27.0.1 identified the built-in panel and an external 5K monitor as physical displays. Real display disconnection, hardware-input recovery, and the active session on the replacement displays remain to be verified on hardware using the steps in `TESTING.txt`.
