import VelaLocalization
import AppKit

/// An isolated live window for checking the production Metal/AppKit layers at reference scale.
/// It never registers hotkeys, creates power assertions or writes the user's defaults.
@MainActor
final class StarRingLiveReview: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var timer: Timer?
    private var pets: [PetView] = []
    private var nativeController: PetController?
    private var reviewPalettePicker: PalettePickerController?
    private var reviewDefaultsDomain: String?
    private var interactionTrace: Timer?
    private var traceTicks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            var palette = PetPalette.stars
            if let index = CommandLine.arguments.firstIndex(of:"--review-palette"),index+1 < CommandLine.arguments.count,
               let selected = PetPalette(rawValue:CommandLine.arguments[index+1]),PetPalette.selectable.contains(selected) {
                palette = selected
            }
            var reviewSize: CGFloat = 200
            var padding: CGFloat = 20
            if let index = CommandLine.arguments.firstIndex(of:"--review-pet-size"),index+1 < CommandLine.arguments.count,
               let size = Double(CommandLine.arguments[index+1]),size.isFinite,(24...512).contains(size) {
                reviewSize = CGFloat(size)+40
                padding = 40
            }
            let reviewAll = CommandLine.arguments.contains("--review-all-effects")
            if !reviewAll,CommandLine.arguments.contains("--review-controls") {
                let domain = "app.aiomni.vela.effectsreview.\(UUID().uuidString)"
                let defaults = UserDefaults(suiteName:domain)!
                defaults.set(CommandLine.arguments.contains("--review-pet-size") ? Double(reviewSize-40) : 61,forKey:"petSize")
                let controller = try PetController(defaults:defaults)
                controller.setPalette(palette)
                controller.setColorStyle(.fade)
                if let index = CommandLine.arguments.firstIndex(of:"--review-mood"),index+1<CommandLine.arguments.count {
                    controller.view.moodOverride = CommandLine.arguments[index+1]
                }
                controller.setEnabled(true)
                controller.onToggle = { [weak controller] in
                    guard let controller else { return }
                    controller.setEnabled(!controller.view.isAwake)
                }
                let picker = PalettePickerController(pet:controller)
                reviewPalettePicker = picker
                controller.settingsButton.toolTip = L("Choose a preview effect")
                controller.settingsButton.setAccessibilityLabel(L("Choose a preview effect"))
                controller.onSettings = { [weak controller,weak picker] in
                    guard let controller,let picker else { return }
                    picker.toggle(attachedTo:controller.settingsButton)
                }
                controller.onPaletteChange = { [weak controller] in
                    guard let controller else { return }
                    controller.panel.title = L("{0} · Native interaction review", "\(controller.view.palette.title)")
                    controller.view.setAccessibilityLabel(L("{0}, production drag and hover interaction review", "\(controller.view.palette.title)"))
                    if CommandLine.arguments.contains("--review-event-log") {
                        fputs("NATIVE EVENT palette=\(controller.view.palette.rawValue)\n",stderr)
                    }
                }
                controller.panel.title = L("{0} · Native interaction review", "\(palette.title)")
                if CommandLine.arguments.contains("--review-dark-background") {
                    controller.panel.backgroundColor = NSColor(srgbRed:0.009,green:0.010,blue:0.014,alpha:1)
                }
                controller.view.setAccessibilityLabel(L("{0}, production drag and hover interaction review", "\(palette.title)"))
                controller.panel.center()
                if CommandLine.arguments.contains("--review-at-pointer") {
                    // Place only this isolated preview under the real pointer.
                    // The production monitor still reads NSEvent.mouseLocation.
                    let pointer = NSEvent.mouseLocation
                    let center = controller.view.convert(NSPoint(x:controller.view.bounds.midX,y:controller.view.bounds.midY),to:nil)
                    controller.panel.setFrameOrigin(NSPoint(x:pointer.x-center.x,y:pointer.y-center.y))
                }
                controller.show()
                nativeController = controller;reviewDefaultsDomain = domain
                if CommandLine.arguments.contains("--review-event-log") {
                    let hover = controller.view.onHover
                    controller.view.onHover = {
                        hover?()
                        fputs("NATIVE EVENT hover\n",stderr)
                    }
                    let drag = controller.view.onDragEnd
                    controller.view.onDragEnd = {
                        drag?()
                        fputs("NATIVE EVENT drag ended\n",stderr)
                    }
                    interactionTrace = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self,weak controller] _ in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            guard let controller else { self.interactionTrace?.invalidate();return }
                            let mouse = NSEvent.mouseLocation
                            let point = controller.container.convert(controller.panel.convertPoint(fromScreen:mouse),from:nil)
                            fputs("NATIVE STATE window=\(controller.panel.frame) pointerInContainer=\(point) visible=\(controller.panel.isVisible) occluded=\(!controller.panel.occlusionState.contains(.visible)) controls=\(controller.container.controlsVisible) hovered=\(controller.view.isHovered)\n",stderr)
                            self.traceTicks += 1
                            if self.traceTicks>=30 { self.interactionTrace?.invalidate() }
                        }
                    }
                }
                return
            }
            var palettes = reviewAll ? PetPalette.selectable.filter { $0 != .custom && $0 != .stars } : [palette]
            if let index = CommandLine.arguments.firstIndex(of:"--review-palettes"),index+1 < CommandLine.arguments.count {
                let selected = CommandLine.arguments[index+1].split(separator:",").compactMap { PetPalette(rawValue:String($0)) }
                    .filter { PetPalette.selectable.contains($0) }
                if !selected.isEmpty { palettes = selected }
            }
            let gallery = palettes.count > 1
            let columns = gallery ? min(5,palettes.count) : 1
            let rows = (palettes.count+columns-1)/columns
            let labelHeight: CGFloat = gallery ? 22 : 0
            if gallery, !CommandLine.arguments.contains("--review-pet-size"),let screen = NSScreen.main {
                reviewSize = min(reviewSize,(screen.visibleFrame.width-60)/CGFloat(columns),
                    (screen.visibleFrame.height-60)/CGFloat(rows)-labelHeight)
            }
            let panelSize = NSSize(width:reviewSize*CGFloat(columns),height:(reviewSize+labelHeight)*CGFloat(rows))
            let panel = NSPanel(contentRect: NSRect(origin:.zero,size:panelSize),
                styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            panel.title = gallery ? L("{0} effects · Live visual review", "\(palettes.count)") : L("{0} visual review", "\(palettes[0].title)")
            panel.isOpaque = false
            panel.backgroundColor = CommandLine.arguments.contains("--review-dark-background")
                ? NSColor(srgbRed:0.009,green:0.010,blue:0.014,alpha:1) : (gallery ? .white : .clear)
            panel.level = .floating
            panel.hasShadow = false
            let root = NSView(frame:NSRect(origin:.zero,size:panelSize))
            let geometry = try PetGeometry.load()
            for (index,palette) in palettes.enumerated() {
                let cell = NSView(frame:NSRect(x:CGFloat(index%columns)*reviewSize,
                    y:CGFloat(rows-1-index/columns)*(reviewSize+labelHeight),width:reviewSize,height:reviewSize+labelHeight))
                let material = LiveMaterialSurface()
                material.frame = NSRect(x:0,y:labelHeight,width:reviewSize,height:reviewSize)
                let pet = PetView(geometry:geometry)
                pet.frame = material.frame
                pet.drawingPadding = padding
                pet.palette = palette
                if let moodIndex = CommandLine.arguments.firstIndex(of:"--review-mood"),moodIndex+1 < CommandLine.arguments.count {
                    pet.moodOverride = CommandLine.arguments[moodIndex+1]
                }
                pet.materialSurface = material
                pet.isAwake = true
                pet.setAccessibilityLabel(L("{0} visual review, production live animation", "\(palette.title)"))
                cell.addSubview(material);cell.addSubview(pet)
                if gallery {
                    let label = NSTextField(labelWithString:palette.title)
                    label.alignment = .center
                    label.font = .systemFont(ofSize:12,weight:.medium)
                    label.textColor = CommandLine.arguments.contains("--review-dark-background") ? .white : .black
                    label.frame = NSRect(x:0,y:0,width:reviewSize,height:labelHeight)
                    cell.addSubview(label)
                }
                root.addSubview(cell);pets.append(pet)
            }
            panel.contentView = root
            panel.center()
            panel.orderFrontRegardless()
            self.panel = panel
            let epoch = ProcessInfo.processInfo.systemUptime
            var fixedPhase: Double?
            if let index = CommandLine.arguments.firstIndex(of:"--review-phase"),index+1<CommandLine.arguments.count,
               let phase = Double(CommandLine.arguments[index+1]),phase.isFinite,(0...300).contains(phase) {
                fixedPhase = phase
                panel.title += L(" · Fixed material phase")
                pets.forEach { $0.animationTime = phase }
            }
            let reviewPhase = fixedPhase
            let timer = Timer(timeInterval: 1/24,repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,let window = self.panel,window.isVisible,window.occlusionState.contains(.visible) else { return }
                    let phase = reviewPhase ?? (ProcessInfo.processInfo.systemUptime-epoch)
                    for pet in self.pets { pet.animationTime = phase;pet.needsDisplay = true }
                }
            }
            RunLoop.main.add(timer,forMode: .common)
            self.timer = timer
        }catch{
            fputs("Live review failed: \(error.localizedDescription)\n",stderr)
            NSApp.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate();timer = nil
        interactionTrace?.invalidate();interactionTrace = nil
        panel?.orderOut(nil)
        nativeController?.hide();nativeController = nil
        reviewPalettePicker?.popover.close();reviewPalettePicker = nil
        if let reviewDefaultsDomain { UserDefaults.standard.removePersistentDomain(forName:reviewDefaultsDomain) }
    }
}
