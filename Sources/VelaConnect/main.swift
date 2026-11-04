import AppKit
import RemoteRTC

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if CommandLine.arguments.contains("--viewport-test") {
        app.setActivationPolicy(.accessory)
        exit(runRemoteViewportChecks() ? 0 : 1)
    }
    let delegate = RemoteViewerApplication()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
