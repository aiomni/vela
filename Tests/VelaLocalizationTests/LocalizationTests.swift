import XCTest
@testable import VelaLocalization
import RemoteCore

final class LocalizationTests: XCTestCase {
    func testEnglishIsDefaultAndSelectionPersists() {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: Localization.preferenceKey)
        defer { defaults.set(old, forKey: Localization.preferenceKey) }
        defaults.removeObject(forKey: Localization.preferenceKey)
        XCTAssertEqual(Localization.language, .english)
        Localization.setLanguage(.simplifiedChinese)
        XCTAssertEqual(defaults.string(forKey: Localization.preferenceKey), "zh-Hans")
        XCTAssertEqual(Localization.language, .simplifiedChinese)
        defaults.set("unsupported", forKey: Localization.preferenceKey)
        XCTAssertEqual(Localization.language, .english)
    }

    func testCatalogHasMatchingPlaceholdersAndEnglishKeys() throws {
        XCTAssertGreaterThan(Localization.chinese.count, 700)
        let markers = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func slots(_ value: String) -> [String] {
            markers.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            }.sorted()
        }
        for (english, chinese) in Localization.chinese {
            XCTAssertFalse(english.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }, english)
            XCTAssertFalse(chinese.isEmpty, english)
            XCTAssertEqual(slots(english), slots(chinese), english)
        }
    }

    func testKnownUnknownAndReverseTranslation() throws {
        let key = "Turn on keep-awake"
        let chinese = try XCTUnwrap(Localization.chinese[key])
        XCTAssertEqual(Localization.text(key, language: .english), key)
        XCTAssertEqual(Localization.text(key, language: .simplifiedChinese), chinese)
        XCTAssertEqual(Localization.text(chinese, language: .english), key)
        XCTAssertEqual(Localization.text("A user-defined display", language: .simplifiedChinese), "A user-defined display")
    }

    func testFormattedServerMessagesAndArguments() {
        let key = "Remote port {0} could not start: {1}"
        XCTAssertEqual(Localization.text(key, arguments: ["8443", "{0}"], language: .english), "Remote port 8443 could not start: {0}")
        XCTAssertEqual(Localization.text("Display {0}", arguments: ["Connect"], language: .simplifiedChinese).suffix(7), "Connect")
        let message = Localization.text("Display {0}", arguments: ["42"], language: .simplifiedChinese)
        XCTAssertEqual(Localization.text(message, language: .english), "Display 42")
        let expanded = Localization.text("Display 42", language: .simplifiedChinese)
        XCTAssertEqual(expanded, message)
    }

    func testLegacyRemoteStoreWinsWithoutCopyingOrOverwriting() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("vela-migration-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support) }
        let modern = support.appendingPathComponent("Vela/RemoteControl", isDirectory: true)
        let legacy = support.appendingPathComponent("AwakePet/RemoteControl", isDirectory: true)
        XCTAssertEqual(RemoteFiles.defaultDirectory(applicationSupport: support), modern)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modern, withIntermediateDirectories: true)
        let certificate = legacy.appendingPathComponent("server.crt")
        try Data("existing-trust".utf8).write(to: certificate)
        XCTAssertEqual(RemoteFiles.defaultDirectory(applicationSupport: support), legacy)
        XCTAssertEqual(try String(contentsOf: certificate, encoding: .utf8), "existing-trust")
        XCTAssertFalse(FileManager.default.fileExists(atPath: modern.appendingPathComponent("server.crt").path))
    }
}
