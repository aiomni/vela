import Foundation
import Testing
@testable import TouchLabCore

@Test func parallelReportLayout() throws {
    let contacts = [TouchscreenReport.Contact(id: 7, x: 0, y: 1), .init(id: 9, x: 1, y: 0.5)]
    let bytes = Array(try TouchscreenReport.encode(contacts))
    #expect(bytes == [1, 7, 7, 0, 0, 255, 127, 7, 9, 255, 127, 0, 64, 2])
    #expect(bytes.count == TouchscreenReport.inputSize)
}

@Test func releasePreservesIdentityAndPosition() throws {
    let contact = TouchscreenReport.Contact(id: 11, x: 0.25, y: 0.75)
    let down = Array(try TouchscreenReport.encode([contact]))
    let up = Array(try TouchscreenReport.encode([contact.released]))
    #expect(down[1] == 7 && up[1] == 4)
    #expect(Array(down[2...6]) == Array(up[2...6]))
    #expect(down.last == 1 && up.last == 1)
    #expect(Array(try TouchscreenReport.encode([])) == [1] + Array(repeating: 0, count: 13))
}

@Test func rejectMalformedFrames() {
    #expect(throws: TouchscreenReport.ValidationError.self) {
        try TouchscreenReport.encode([.init(id: 1, x: .nan, y: 0)])
    }
    #expect(throws: TouchscreenReport.ValidationError.self) {
        try TouchscreenReport.encode([.init(id: 1, x: 0, y: .infinity)])
    }
    #expect(throws: TouchscreenReport.ValidationError.self) {
        try TouchscreenReport.encode([.init(id: 1, x: -0.01, y: 0)])
    }
    #expect(throws: TouchscreenReport.ValidationError.self) {
        try TouchscreenReport.encode([.init(id: 1, x: 0, y: 1.01)])
    }
    #expect(throws: TouchscreenReport.ValidationError.self) {
        try TouchscreenReport.encode([.init(id: 1, x: 0, y: 0), .init(id: 1, x: 1, y: 1)])
    }
    #expect(throws: TouchscreenReport.ValidationError.self) {
        try TouchscreenReport.encode((1...3).map { .init(id: UInt8($0), x: 0, y: 0) })
    }
}

@Test func mixedLiftCountsAllValidContacts() throws {
    let first = TouchscreenReport.Contact(id: 1, x: 0.2, y: 0.3)
    let second = TouchscreenReport.Contact(id: 2, x: 0.8, y: 0.7)
    let mixed = Array(try TouchscreenReport.encode([first.released, second]))
    #expect(mixed[1] == 4 && mixed[7] == 7 && mixed.last == 2)
    let lifted = Array(try TouchscreenReport.encode([first.released, second.released]))
    #expect(lifted[1] == 4 && lifted[7] == 4 && lifted.last == 2)
}

@Test func featureResponseIncludesReportIDAndRejectsInvalidRequests() throws {
    #expect(try TouchscreenReport.featureResponse(reportID: 2, maximumSize: 2) == Data([2, 2]))
    #expect(try TouchscreenReport.featureResponse(reportID: 2, maximumSize: 64) == Data([2, 2]))
    for id: UInt8? in [nil, 0, 1, 3] {
        #expect(throws: TouchscreenReport.ValidationError.self) {
            try TouchscreenReport.featureResponse(reportID: id, maximumSize: 2)
        }
    }
    for size in [-1, 0, 1] {
        #expect(throws: TouchscreenReport.ValidationError.self) {
            try TouchscreenReport.featureResponse(reportID: 2, maximumSize: size)
        }
    }
}

/// Independent HID short-item walk catches encoder/descriptor length drift.
@Test func descriptorHasTwoFingerCollectionsAndCorrectBitCounts() throws {
    let bytes = Array(TouchscreenReport.descriptor)
    var index = 0, page = 0, size = 0, count = 0, reportID = 0, depth = 0, fingers = 0
    var bits: [Int: Int] = [:], features: [Int: Int] = [:]
    var stack: [(Int, Int, Int, Int)] = []
    while index < bytes.count {
        let prefix = bytes[index]; index += 1
        #expect(prefix != 0xfe)
        let length = [0, 1, 2, 4][Int(prefix & 3)]
        #expect(index + length <= bytes.count)
        var value = 0
        for offset in 0..<length { value |= Int(bytes[index + offset]) << (8 * offset) }
        index += length
        switch prefix & 0xfc {
        case 0x04: page = value
        case 0x74: size = value
        case 0x94: count = value
        case 0x84: reportID = value
        case 0xa4: stack.append((page, size, count, reportID))
        case 0xb4: (page, size, count, reportID) = stack.removeLast()
        case 0x08: if page == 0x0d && value == 0x22 { fingers += 1 }
        case 0xa0: depth += 1
        case 0xc0: depth -= 1; #expect(depth >= 0)
        case 0x80: bits[reportID, default: 0] += size * count
        case 0xb0: features[reportID, default: 0] += size * count
        default: break
        }
    }
    #expect(depth == 0 && stack.isEmpty && fingers == 2)
    #expect(bits == [1: 104])
    #expect(features == [2: 8])
}
