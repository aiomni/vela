import VelaLocalization
import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var keyLabel: String
    static let initial = Shortcut(keyCode: UInt32(kVK_ANSI_K),
                                  modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "K")
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let labels: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
                                       123: "←", 124: "→", 125: "↓", 126: "↑"]
        let ansi: [UInt16: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",
            12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",
            25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",
            39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",50:"`",
            122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        let label = labels[event.keyCode] ?? ansi[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }
}

@MainActor
final class HotKey {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private(set) var shortcut: Shortcut?
    var suspended = false
    var onPress: (() -> Void)?

    func install() throws {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == 0x41575054, key.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
                if !owner.suspended { owner.onPress?() }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if result != noErr { throw error(result) }
    }

    func register(_ candidate: Shortcut) throws {
        if candidate == shortcut && registration != nil { return }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(candidate.keyCode, candidate.modifiers,
            EventHotKeyID(signature: 0x41575054, id: 1), GetApplicationEventTarget(), 0, &next)
        guard result == noErr, let next else { throw error(result) }
        if let registration { UnregisterEventHotKey(registration) }
        registration = next
        shortcut = candidate
    }

    func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
        shortcut = nil
    }

    private func error(_ code: OSStatus) -> NSError {
        let message = code == eventHotKeyExistsErr
            ? L("This shortcut is already in use. Choose another combination. Your existing shortcut was preserved.")
            : L("Unable to register shortcut ({0}). Choose another combination or use the menu bar.", "\(code)")
        return NSError(domain: "Vela.HotKey", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
