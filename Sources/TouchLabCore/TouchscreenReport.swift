import Foundation

/// A full parallel scan of two fingers, not a mouse/trackpad gesture descriptor.
public enum TouchscreenReport {
    public static let maximumContacts = 2
    public static let logicalMaximum: UInt16 = 32767
    public static let inputID: UInt8 = 1
    public static let featureID: UInt8 = 2
    public static let inputSize = 14

    public struct Contact: Equatable, Sendable {
        public let id: UInt8
        public let x: Double
        public let y: Double
        public let touching: Bool
        public init(id: UInt8, x: Double, y: Double, touching: Bool = true) {
            self.id = id; self.x = x; self.y = y; self.touching = touching
        }
        public var released: Contact { Contact(id: id, x: x, y: y, touching: false) }
    }

    public enum ValidationError: Error { case tooManyContacts, duplicateID, invalidCoordinate, invalidFeatureRequest }

    /// A complete feature wire report includes its report ID prefix.
    public static func featureResponse(reportID: UInt8?, maximumSize: Int) throws -> Data {
        guard reportID == featureID, maximumSize >= 2 else { throw ValidationError.invalidFeatureRequest }
        return Data([featureID, UInt8(maximumContacts)])
    }

    // Digitizers / Touch Screen, application collection, input report 1.
    // Each logical Finger: Tip Switch, In Range, Confidence, padding,
    // Contact Identifier, absolute 16-bit X/Y. Feature report 2: Contact Count Maximum.
    public static let descriptor: Data = {
        var bytes: [UInt8] = [0x05, 0x0d, 0x09, 0x04, 0xa1, 0x01, 0x85, inputID]
        for _ in 0..<maximumContacts {
            bytes += [
                0x09, 0x22, 0xa1, 0x02,
                0x09, 0x42, 0x09, 0x32, 0x09, 0x47,
                0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
                0x75, 0x05, 0x95, 0x01, 0x81, 0x03,
                0x09, 0x51, 0x15, 0x00, 0x26, 0xff, 0x00,
                0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
                0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
                0x15, 0x00, 0x26, 0xff, 0x7f, 0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
                0x05, 0x0d, 0xc0
            ]
        }
        bytes += [0x09, 0x54, 0x15, 0x00, 0x25, 0x02, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
                  0x85, featureID, 0x09, 0x55, 0x75, 0x08, 0x95, 0x01, 0xb1, 0x02, 0xc0]
        return Data(bytes)
    }()

    /// Coordinates are top-left display-normalized, not CSS pixels or AppKit points.
    /// Include a released contact with its last ID/position on the terminal scan.
    public static func encode(_ contacts: [Contact]) throws -> Data {
        guard contacts.count <= maximumContacts else { throw ValidationError.tooManyContacts }
        guard Set(contacts.map(\.id)).count == contacts.count else { throw ValidationError.duplicateID }
        var bytes: [UInt8] = [inputID]
        for contact in contacts {
            guard contact.x.isFinite, contact.y.isFinite,
                  (0...1).contains(contact.x), (0...1).contains(contact.y) else {
                throw ValidationError.invalidCoordinate
            }
            let x = UInt16((contact.x * Double(logicalMaximum)).rounded())
            let y = UInt16((contact.y * Double(logicalMaximum)).rounded())
            bytes += [contact.touching ? 0x07 : 0x04, contact.id,
                      UInt8(truncatingIfNeeded: x), UInt8(truncatingIfNeeded: x >> 8),
                      UInt8(truncatingIfNeeded: y), UInt8(truncatingIfNeeded: y >> 8)]
        }
        bytes += Array(repeating: 0, count: (maximumContacts - contacts.count) * 6)
        // Count valid records, including the terminal lift; padding slots are not contacts.
        bytes.append(UInt8(contacts.count))
        return Data(bytes)
    }
}
