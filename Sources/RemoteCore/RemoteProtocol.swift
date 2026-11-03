import Foundation

public struct RemoteDisplay: Codable, Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public let isVirtual: Bool?
    public let logicalWidth: Int?
    public let logicalHeight: Int?
    public init(id: UInt32, name: String, width: Int, height: Int, isVirtual: Bool? = nil,
                logicalWidth: Int? = nil, logicalHeight: Int? = nil) {
        self.id = id; self.name = name; self.width = width; self.height = height
        self.isVirtual = isVirtual; self.logicalWidth = logicalWidth; self.logicalHeight = logicalHeight
    }
}

public struct RemoteICECandidate: Codable, Sendable {
    public let candidate: String
    public let sdpMid: String?
    public let sdpMLineIndex: Int32
    public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        self.candidate = candidate; self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex
    }
}

public struct RemoteInput: Codable, Sendable {
    public var type: String
    public var action: String?
    public var x: Double?
    public var y: Double?
    public var button: Int?
    public var code: String?
    public var text: String?
    public var deltaX: Double?
    public var deltaY: Double?
    public var modifiers: [String]?
    public var sequence: UInt64?
    public var displayID: UInt32?
    public init(type: String) { self.type = type }
    public func validate() -> Bool {
        switch type {
        case "pointer":
            guard let action, ["move", "down", "up"].contains(action),
                  let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
                  (0...2).contains(button ?? 0), displayID != nil else { return false }
        case "scroll":
            guard let deltaX, let deltaY, deltaX.isFinite, deltaY.isFinite,
                  abs(deltaX) <= 2000, abs(deltaY) <= 2000, displayID != nil else { return false }
        case "key":
            guard let code, KeyMap.macKeyCode[code] != nil, ["down", "up"].contains(action ?? "") else { return false }
        case "text":
            guard let text, !text.isEmpty, text.utf8.count <= 8192 else { return false }
        case "release": break
        default: return false
        }
        return (modifiers ?? []).count <= 4 && (modifiers ?? []).allSatisfy { ["shift", "control", "alt", "meta"].contains($0) }
    }
}

public enum KeyMap {
    /// DOM KeyboardEvent.code maps physical keys; committed IME text uses the separate text message.
    public static let macKeyCode: [String: UInt16] = [
        "KeyA":0,"KeyS":1,"KeyD":2,"KeyF":3,"KeyH":4,"KeyG":5,"KeyZ":6,"KeyX":7,"KeyC":8,"KeyV":9,
        "KeyB":11,"KeyQ":12,"KeyW":13,"KeyE":14,"KeyR":15,"KeyY":16,"KeyT":17,
        "Digit1":18,"Digit2":19,"Digit3":20,"Digit4":21,"Digit6":22,"Digit5":23,"Equal":24,"Digit9":25,
        "Digit7":26,"Minus":27,"Digit8":28,"Digit0":29,"BracketRight":30,"KeyO":31,"KeyU":32,
        "BracketLeft":33,"KeyI":34,"KeyP":35,"Enter":36,"KeyL":37,"KeyJ":38,"Quote":39,"KeyK":40,
        "Semicolon":41,"Backslash":42,"Comma":43,"Slash":44,"KeyN":45,"KeyM":46,"Period":47,
        "Tab":48,"Space":49,"Backquote":50,"Backspace":51,"Escape":53,"MetaRight":54,"MetaLeft":55,
        "ShiftLeft":56,"CapsLock":57,"AltLeft":58,"ControlLeft":59,"ShiftRight":60,"AltRight":61,"ControlRight":62,
        "NumpadDecimal":65,"NumpadMultiply":67,"NumpadAdd":69,"NumLock":71,"NumpadDivide":75,
        "NumpadEnter":76,"NumpadSubtract":78,"NumpadEqual":81,"Numpad0":82,"Numpad1":83,"Numpad2":84,
        "Numpad3":85,"Numpad4":86,"Numpad5":87,"Numpad6":88,"Numpad7":89,"Numpad8":91,"Numpad9":92,
        "F5":96,"F6":97,"F7":98,"F3":99,"F8":100,"F9":101,"F11":103,"F13":105,"F16":106,
        "F14":107,"F10":109,"F12":111,"F15":113,"Insert":114,"Home":115,"PageUp":116,"Delete":117,
        "F4":118,"End":119,"F2":120,"PageDown":121,"F1":122,"ArrowLeft":123,"ArrowRight":124,"ArrowDown":125,"ArrowUp":126
    ]
}
