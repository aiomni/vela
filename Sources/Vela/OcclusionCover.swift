import VelaLocalization
import AppKit

/// Separate-process opaque fixture for native visibility verification only.
@MainActor
final class OcclusionCover: NSObject,NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let index = CommandLine.arguments.firstIndex(of:"--occlusion-cover"),
              CommandLine.arguments.count>index+5 else { exit(2) }
        let values = CommandLine.arguments[(index+1)...(index+5)].compactMap(Double.init)
        guard values.count==5,values.allSatisfy({ $0.isFinite }),
              (1...1024).contains(values[2]),(1...1024).contains(values[3]),
              (0...100).contains(values[4]) else { exit(2) }
        let frame = NSRect(x:values[0],y:values[1],width:values[2],height:values[3])
        let panel = NSWindow(contentRect:frame,styleMask:.borderless,backing:.buffered,defer:false)
        panel.title = L("Vela Occlusion Test Cover")
        panel.isOpaque = true;panel.backgroundColor = .black;panel.hasShadow = false
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        panel.contentView?.layer?.isOpaque = true
        panel.level = NSWindow.Level(rawValue:Int(values[4]))
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless();window = panel
        fputs("COVER READY\n",stderr)
        // Bound fixture lifetime even if its parent verification process fails.
        DispatchQueue.main.asyncAfter(deadline:.now()+8) { NSApp.terminate(nil) }
    }
}
