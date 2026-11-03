import VelaLocalization
import Foundation
import IOKit.pwr_mgt

enum KeepAwakeMode: String, CaseIterable {
    case display
    case system
    case lid

    var assertionType: CFString {
        switch self {
        case .display: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        case .system, .lid: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        }
    }
}

@MainActor
final class PowerController {
    private(set) var assertion: IOPMAssertionID?
    private(set) var displayAssertion: IOPMAssertionID?
    private(set) var mode: KeepAwakeMode?
    var isEnabled: Bool { assertion != nil }

    func enable(_ requestedMode: KeepAwakeMode = .display) throws {
        if assertion != nil && mode == requestedMode && isActuallyHeld() { return }
        disable()
        assertion = try createAssertion(requestedMode.assertionType)
        if requestedMode == .lid {
            do {
                displayAssertion = try createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
            } catch {
                disable()
                throw error
            }
        }
        mode = requestedMode
    }

    private func createAssertion(_ type: CFString) throws -> IOPMAssertionID {
        var value = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Vela: user enabled keep-awake" as CFString, &value)
        guard result == kIOReturnSuccess else {
            throw NSError(domain: "Vela.Power", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: L("Unable to enable keep-awake ({0})", "\(result)")])
        }
        return value
    }

    func isActuallyHeld() -> Bool {
        guard let assertion, let mode,
              hasAssertion(assertion, type: mode.assertionType) else { return false }
        if mode == .lid {
            guard let displayAssertion else { return false }
            return hasAssertion(displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
        }
        return displayAssertion == nil
    }

    private func hasAssertion(_ id: IOPMAssertionID, type: CFString) -> Bool {
        guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        else { return false }
        return (properties[kIOPMAssertionTypeKey as String] as? String) == (type as String)
    }

    func disable() {
        if let displayAssertion { IOPMAssertionRelease(displayAssertion) }
        if let assertion { IOPMAssertionRelease(assertion) }
        displayAssertion = nil
        assertion = nil
        mode = nil
    }
}
