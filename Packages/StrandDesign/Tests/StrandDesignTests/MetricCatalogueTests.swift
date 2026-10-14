import XCTest
@testable import StrandDesign

/// The zoop.metric.* strings resolve against the APP catalogue at runtime, which package tests cannot
/// load as a bundle. These tests read it as JSON instead: every key MetricStrings uses must exist in
/// English and German, and the German VoiceOver wording is composed from the real templates.
final class MetricCatalogueTests: XCTestCase {

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalogueURL = packageRoot
        .appendingPathComponent("../../Strand/Resources/Localizable.xcstrings").standardized
    private static let stringsSource = packageRoot
        .appendingPathComponent("Sources/StrandDesign/Metric/MetricStrings.swift")

    private func catalogue() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.catalogueURL) else {
            throw XCTSkip("app catalogue not present next to the package")
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["strings"] as? [String: Any])
    }

    /// The `other` form for plurals, the plain value otherwise.
    private func value(_ key: String, _ lang: String, in strings: [String: Any]) -> String? {
        guard let entry = strings[key] as? [String: Any],
              let locs = entry["localizations"] as? [String: Any],
              let loc = locs[lang] as? [String: Any] else { return nil }
        if let unit = loc["stringUnit"] as? [String: Any] { return unit["value"] as? String }
        let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: Any]
        return ((plural?["other"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    func testEveryMetricKeyHasEnglishAndGerman() throws {
        let strings = try catalogue()
        let source = try String(contentsOf: Self.stringsSource, encoding: .utf8)
        let regex = try NSRegularExpression(pattern: #""(zoop\.metric\.[A-Za-z0-9.]+)""#)
        let keys = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
        XCTAssertGreaterThan(keys.count, 40)
        for key in keys {
            XCTAssertNotNil(value(key, "en", in: strings), "\(key) missing en")
            XCTAssertNotNil(value(key, "de", in: strings), "\(key) missing de")
        }
    }

    func testGermanVoiceOverReading() throws {
        let strings = try catalogue()
        let p = MetricPresentation(MetricSamples.hrvSolid, locale: Locale(identifier: "de_DE"))
        let spoken = try XCTUnwrap(value("zoop.metric.unit.ms.spoken", "de", in: strings))
            .replacingOccurrences(of: "%@", with: try XCTUnwrap(p.number))
        let verdict = try XCTUnwrap(value("zoop.metric.verdict.above", "de", in: strings))
        XCTAssertEqual("\(p.label), \(spoken), \(verdict)", "HRV, 62 Millisekunden, Über deinem Bereich")
    }
}
