import Foundation
import IOKit.ps

enum PowerSafetyMonitor {
    static func battery() -> DutyBattery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            let percent = min(100, max(0, current * 100 / maximum))
            return DutyBattery(percent: percent,
                               onBattery: info[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }

    static func heat() -> DutyHeat {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}

@MainActor
final class PowerSourceChangeObserver {
    private let onChange: @MainActor () -> Void
    private var source: CFRunLoopSource?

    init?(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerSourceChangeObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.onChange() }
        }, Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        let source = created.takeRetainedValue()
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }
}
