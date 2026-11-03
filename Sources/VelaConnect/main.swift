import AppKit
import RemoteRTC

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = RemoteViewerApplication()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
