import AppKit
import CoreHID
import IOKit
import IOKit.hidsystem
import Security
import TouchLabCore

actor FeatureDelegate: HIDVirtualDeviceDelegate {
    private var featureGetRequests = 0
    private var lastFeatureID = -1
    private var lastFeatureMaximumSize = 0
    func snapshot() -> [String: Int] {
        ["featureGetRequests": featureGetRequests, "lastFeatureID": lastFeatureID,
         "lastFeatureMaximumSize": lastFeatureMaximumSize]
    }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {
        throw HIDDeviceError.unsupported
    }
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        guard type == .feature else { throw HIDDeviceError.unsupported }
        featureGetRequests += 1
        lastFeatureID = id.map { Int($0.rawValue) } ?? -1
        lastFeatureMaximumSize = maxSize
        do { return try TouchscreenReport.featureResponse(reportID: id?.rawValue, maximumSize: maxSize) }
        catch { throw HIDDeviceError.badArgument }
    }
}

@MainActor
final class TouchEvidence {
    var values: [String: Any] = [
        "schemaVersion": 1,
        "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "deviceCreated": false, "deviceActivated": false, "reportsSubmitted": 0,
        "directTouchCallbacks": 0, "directTouchBegan": 0, "directTouchMoved": 0,
        "directTouchEnded": 0, "directTouchCancelled": 0,
        "magnificationActions": 0, "scrollOriginChanged": false,
        "nativeTouchAndGesturesVerified": false
    ]
    var samples: [[String: Any]] = []
    var stage = "idle"
    var lastReportedContacts: [TouchscreenReport.Contact] = []
    func increment(_ key: String) { values[key] = (values[key] as? Int ?? 0) + 1 }
    func sample(_ entry: [String: Any]) {
        if samples.count < 512 {
            samples.append(entry.merging(["stage": stage]) { first, _ in first })
        }
    }
    func finish(output: String?) throws {
        values["samples"] = samples
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        if let output { try data.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

@MainActor
final class VirtualTouchscreen {
    static let entitlement = "com.apple.developer.hid.virtual.device"
    let evidence: TouchEvidence
    private var device: HIDVirtualDevice?
    private var contacts: [TouchscreenReport.Contact] = []
    private var uniqueID: String?
    private var inputReportAttempted = false
    private let delegate = FeatureDelegate()
    init(evidence: TouchEvidence) { self.evidence = evidence }

    func create(displayID: CGDirectDisplayID?) {
        var entitlementError: Unmanaged<CFError>?
        let task = SecTaskCreateFromSelf(nil)
        let value = task.flatMap { SecTaskCopyValueForEntitlement($0, Self.entitlement as CFString, &entitlementError) }
        let entitlementPresent = value.map {
            CFGetTypeID($0) == CFBooleanGetTypeID() && ($0 as? Bool) == true
        } ?? false
        evidence.values["virtualDeviceEntitlementPresent"] = entitlementPresent
        if let error = entitlementError?.takeRetainedValue() {
            evidence.values["entitlementReadError"] = String(describing: error)
        }
        var extra: [String: AnyObject] = ["DisplayIntegrated": NSNumber(value: true)]
        if let displayID {
            extra["CGDirectDisplayID"] = NSNumber(value: displayID)
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                extra["DisplayIdentifier"] = CFUUIDCreateString(nil, uuid) as String as NSString
            }
        }
        evidence.values["requestedDisplayProperties"] = extra
        evidence.values["displayBindingStatus"] = "Experimental properties; not proof of WindowServer association."
        let uniqueID = UUID().uuidString
        self.uniqueID = uniqueID
        evidence.values["descriptorBytes"] = TouchscreenReport.descriptor.count
        evidence.values["inputReportBytes"] = TouchscreenReport.inputSize
        // Vendor 0 is an unassigned laboratory identity, never Apple's vendor ID.
        let properties = HIDVirtualDevice.Properties(descriptor: TouchscreenReport.descriptor,
            vendorID: 0, productID: 1, product: "Vela Touch Lab", manufacturer: "Vela",
            uniqueID: uniqueID, extraProperties: extra)
        device = HIDVirtualDevice(properties: properties)
        evidence.values["deviceCreated"] = device != nil
        evidence.values["creationResult"] = device == nil
            ? "HIDVirtualDevice.init returned nil; API exposes no underlying IOReturn."
            : "HIDVirtualDevice object initialized; activation and enumeration are separate checks."
        if device == nil {
            evidence.values["nextStep"] = entitlementPresent
                ? "Validate signing/provisioning, CoreHID logs and descriptor. Entitlement presence alone is not sufficient."
                : "The executing process lacks com.apple.developer.hid.virtual.device=true. Obtain valid authorization/signing; TCC consent is not this entitlement."
        }
    }

    func activate() async -> Bool {
        guard let device else { return false }
        await device.activate(delegate: delegate)
        evidence.values["deviceActivated"] = true
        return true
    }

    /// Only query this process's device; do not open/monitor physical HID devices.
    func recordEnumeration() {
        guard device != nil, let uniqueID else { return }
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator)
        evidence.values["enumerationResult"] = String(format: "0x%08x", result)
        guard result == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        var matches: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            let product = IORegistryEntryCreateCFProperty(service, "Product" as CFString, nil, 0)?.takeRetainedValue() as? String
            guard product == "Vela Touch Lab" else { continue }
            let entryUnique = IORegistryEntryCreateCFProperty(service, "PhysicalDeviceUniqueID" as CFString, nil, 0)?.takeRetainedValue() as? String
            guard entryUnique == uniqueID else { continue }
            var entry: [String: Any] = [:]
            var registryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS { entry["registryID"] = registryID }
            for key in ["PrimaryUsagePage", "PrimaryUsage", "DisplayIntegrated", "CGDirectDisplayID", "DisplayIdentifier"] {
                if let value = IORegistryEntryCreateCFProperty(service, key as CFString, nil, 0)?.takeRetainedValue() {
                    entry[key] = value
                }
            }
            matches.append(entry)
        }
        evidence.values["enumeratedDevices"] = matches
        evidence.values["deviceEnumerated"] = !matches.isEmpty
    }

    /// A separate acceptance rung: no dispatchInputReport, including cleanup.
    func inspectWithoutInput() async -> Bool {
        guard let device else { return false }
        guard let client = HIDDeviceClient(deviceReference: device.deviceReference) else {
            evidence.values["ownDeviceClientCreated"] = false
            return false
        }
        evidence.values["ownDeviceClientCreated"] = true
        let descriptor = await client.descriptor
        let usage = await client.primaryUsage
        let elements = await client.elements
        let descriptorMatches = descriptor == TouchscreenReport.descriptor
        let usageMatches = usage.page == 0x0d && usage.usage == 0x04
        evidence.values["ownDescriptorReadbackMatches"] = descriptorMatches
        evidence.values["ownPrimaryUsageMatches"] = usageMatches
        evidence.values["ownHIDElementCount"] = elements.count
        evidence.values["ownInputElementCount"] = elements.filter { $0.type == .input }.count
        evidence.values["ownFeatureElementCount"] = elements.filter { $0.type == .feature }.count
        do {
            let response = try await client.dispatchGetReportRequest(type: .feature,
                id: HIDReportID(rawValue: TouchscreenReport.featureID), timeout: .seconds(1))
            evidence.values["featureResponseBytes"] = Array(response)
            let callbacks = await delegate.snapshot()
            evidence.values["featureDelegateCallbacks"] = callbacks
            let roundtrip = response == Data([2, 2]) && (callbacks["featureGetRequests"] ?? 0) > 0
            evidence.values["featureRoundtripVerified"] = roundtrip
            evidence.values["noInputInspectionVerified"] = roundtrip && descriptorMatches && usageMatches &&
                evidence.values["deviceEnumerated"] as? Bool == true && !inputReportAttempted
            return evidence.values["noInputInspectionVerified"] as? Bool == true
        } catch {
            evidence.values["featureGetError"] = String(describing: error)
            evidence.values["featureDelegateCallbacks"] = await delegate.snapshot()
            evidence.values["featureRoundtripVerified"] = false
            return false
        }
        // This method's local client is released before close() releases the virtual device.
    }

    func send(_ next: [TouchscreenReport.Contact]) async throws {
        guard let device else { throw NSError(domain: "VelaTouchLab.Device", code: 1) }
        // Save before the await so a failing report still receives a best-effort lift.
        inputReportAttempted = true
        contacts = next
        if !next.isEmpty { evidence.lastReportedContacts = next }
        try await device.dispatchInputReport(data: TouchscreenReport.encode(next), timestamp: SuspendingClock().now)
        evidence.increment("reportsSubmitted")
        evidence.sample(["kind": "report", "contacts": next.map {
            ["id": Int($0.id), "x": $0.x, "y": $0.y, "touching": $0.touching] as [String: Any]
        }])
    }

    func close() async {
        if evidence.values["deviceActivated"] as? Bool == true && inputReportAttempted {
            do {
                try await send(contacts.map(\.released))
                try await send([])
                evidence.values["releaseReportsSubmitted"] = true
            } catch {
                evidence.values["releaseReportsSubmitted"] = false
                evidence.values["nativeTouchAndGesturesVerified"] = false
                evidence.values["releaseError"] = String(describing: error)
            }
        }
        evidence.values["inputReportAttempted"] = inputReportAttempted
        evidence.values["noInputTeardown"] = !inputReportAttempted
        contacts = []
        device = nil
        evidence.values["deviceReferenceReleased"] = true
        // CoreHID owns cancellation. Process exit also closes its app-owned user client.
    }
}
