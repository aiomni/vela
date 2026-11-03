import VelaLocalization
import Foundation

struct ColorTransition {
    private var from = 0.0
    private(set) var target = 0.0
    private var startedAt = 0.0
    let duration = 0.4

    func value(at time: Double) -> Double {
        let progress = min(1, max(0, (time - startedAt) / duration))
        let eased = progress * progress * (3 - 2 * progress)
        return from + (target - from) * eased
    }

    mutating func set(_ target: Double, at time: Double, animated: Bool) {
        guard self.target != target else { return }
        from = animated ? value(at: time) : target
        self.target = target
        startedAt = time
    }
}

struct PetMood: Decodable {
    let eyes: [Int]
    let holdSeconds: [Double]
    let blinkSeconds: [Double]?
}

struct PetAnimation {
    static var catalog: [(id: String, title: String)] { [
        ("idle", L("Everyday")), ("curious", L("Curious")), ("happy", L("Happy")), ("listening", L("Listening")),
        ("playful", L("Playful")), ("thinking", L("Thinking")), ("surprised", L("Surprised")), ("proud", L("Proud")),
        ("searching", L("Looking Around")), ("shy", L("Shy")), ("working", L("Focused")), ("laughing", L("Laughing")),
        ("confused", L("Confused")), ("excited", L("Excited")), ("suspicious", L("Suspicious")), ("bored", L("Bored")),
        ("celebrate", L("Celebrating")), ("angry", L("Angry")), ("drowsy", L("Drowsy")), ("scared", L("Startled")),
        ("sad", L("Sad")), ("sleeping", L("Napping"))
    ] }
    struct Frame {
        let mood: String
        let from: Int
        let to: Int
        let blend: Double
        let lid: Double
        let winkEye: Int?
        let rotation: Double
        let squash: Double
        let bounce: Double
        let gazeX: Double
        let gazeY: Double
    }
    let moods: [String: PetMood]

    func eyeStep(_ mood: PetMood) -> Double {
        min(1.2, max(0.75, mood.holdSeconds.reduce(0, +) / 4))
    }
    func duration(_ id: String) -> Double {
        let mood = moods[id]!
        return max(3.6, Double(mood.eyes.count) * eyeStep(mood) + 0.6)
    }
    var cycleDuration: Double { Self.catalog.map { duration($0.id) }.reduce(0, +) }

    func frame(at rawTime: Double, override: String? = nil, reduced: Bool = false) -> Frame {
        let time = rawTime.isFinite ? max(0, rawTime) : 0
        var local = time.truncatingRemainder(dividingBy: cycleDuration)
        var moodIndex = 0
        while local >= duration(Self.catalog[moodIndex].id), moodIndex < Self.catalog.count - 1 {
            local -= duration(Self.catalog[moodIndex].id)
            moodIndex += 1
        }
        let name = override.flatMap { moods[$0] == nil ? nil : $0 } ?? Self.catalog[moodIndex].id
        let mood = moods[name]!
        if override != nil { local = time.truncatingRemainder(dividingBy: duration(name)) }
        let step = eyeStep(mood)
        let phase = local / step
        let index = min(mood.eyes.count - 1, Int(phase))
        let from = index > 0 ? mood.eyes[index - 1] :
            (override == nil ? moods[Self.catalog[(moodIndex + Self.catalog.count - 1) % Self.catalog.count].id]!.eyes.last! : mood.eyes.last!)
        let progress = Int(phase) >= mood.eyes.count ? 1 : min(1, (phase - floor(phase)) / 0.48)
        // A damped response gives eye transitions a soft spring-like arrival.
        let blend = min(1, max(0, 1 - exp(-7 * progress) * cos(7 * progress)))
        let blinkPeriod = min(5.5, max(2.6, (mood.blinkSeconds?.reduce(0, +) ?? 7) / 2))
        let blinkPhase = time.truncatingRemainder(dividingBy: blinkPeriod)
        let blinkLid = mood.blinkSeconds != nil && blinkPhase < 0.24 ? max(0.06, abs(blinkPhase - 0.12) / 0.12) : 1
        // Several moods share eye polygons. Give the quiet ones a persistent
        // eyelid shape so they remain recognizable between brief blinks.
        let restingLid: Double = switch name {
        case "drowsy": 0.58
        case "sleeping": 0.16
        case "sad": 0.78
        case "suspicious": 0.68
        default: 1
        }
        let lid = min(blinkLid, restingLid)
        let wink = ["idle", "happy", "excited", "curious", "playful"].contains(name)
            && time.truncatingRemainder(dividingBy: 11.3) > 10.95
        let upbeat = ["excited", "playful", "celebrate", "laughing"].contains(name)
        var rotation = sin(time * 0.9) * 0.04
        var bounce = sin(time * 1.8) * 0.016
        var squash = 1 + sin(time * 2.1) * 0.016
        var gazeX = sin(time * 0.65) * 3
        var gazeY = cos(time * 0.45) * 2
        if upbeat {
            bounce -= abs(sin(local * 3.6)) * 0.055
            rotation += sin(local * 2.8) * 0.12
            squash += cos(local * 7.2) * 0.035
        }
        switch name {
        case "curious", "confused": rotation += sin(local * 1.5) * 0.13
        case "thinking": rotation -= 0.08; gazeY -= 7
        case "searching", "listening": gazeX = sin(local * 2) * 13
        case "shy": rotation += 0.12; gazeX -= 7; gazeY += 4
        case "surprised": squash += 0.09; bounce -= 0.035
        case "scared": rotation += sin(local * 22) * 0.075; squash -= 0.07; bounce += 0.025
        case "angry": rotation += sin(local * 13) * 0.065; squash -= 0.035
        case "proud": bounce -= 0.018; gazeY -= 4
        case "drowsy": rotation += 0.08; squash -= 0.035; gazeY += 5
        case "sleeping": rotation += 0.13; squash -= 0.06; gazeY += 7
        case "sad": rotation += 0.09; squash -= 0.04; gazeY += 5
        default: break
        }
        return Frame(mood: name, from: reduced ? mood.eyes[0] : from, to: reduced ? mood.eyes[0] : mood.eyes[index],
            blend: reduced ? 1 : blend, lid: reduced ? restingLid : lid, winkEye: reduced || !wink ? nil : Int(time / 11.3) % 2,
            rotation: reduced ? 0 : rotation, squash: reduced ? 1 : squash, bounce: reduced ? 0 : bounce,
            gazeX: reduced ? 0 : gazeX, gazeY: reduced ? 0 : gazeY)
    }
}

/// The button-eye character owns its idle body motion. Shared mood boundaries
/// must not reset its rotation, breathing or height between exploration clips.
struct ButtonEyeMotion {
    static func body(at rawTime: Double, reduced: Bool) -> (rotation: Double, squash: Double, bounce: Double) {
        guard !reduced else { return (0, 1, 0) }
        let time = rawTime.isFinite ? max(0, rawTime) : 0
        return (sin(time * 0.65) * 0.025,
                1 + sin(time * 1.1) * 0.006,
                sin(time * 0.95) * 0.009)
    }
}
