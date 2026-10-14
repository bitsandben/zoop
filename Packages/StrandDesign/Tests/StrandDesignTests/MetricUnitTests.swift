import XCTest
@testable import StrandDesign

final class MetricUnitTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let de = Locale(identifier: "de_DE")
    private let nbsp = "\u{00A0}"

    func testGermanUsesDecimalCommaAndGroupingDot() {
        XCTAssertEqual(MetricUnit.celsius.format(36.4, locale: de), "36,4\(nbsp)°C")
        XCTAssertEqual(MetricUnit.kilograms.format(75, locale: de), "75,0\(nbsp)kg")
        XCTAssertEqual(MetricUnit.steps.number(12_345, locale: de), "12.345")
    }

    func testEnglishKeepsCelsiusAndKilograms() {
        // `.asProvided` must stop en-US from converting to °F / lb.
        XCTAssertEqual(MetricUnit.celsius.format(36.4, locale: en), "36.4\(nbsp)°C")
        XCTAssertEqual(MetricUnit.celsius.spoken(36.4, locale: en), "36.4 degrees Celsius")
        XCTAssertEqual(MetricUnit.kilograms.spoken(75, locale: en), "75.0 kilograms")
    }

    func testFractionDigitsPerUnit() {
        XCTAssertEqual(MetricUnit.milliseconds.number(61.6, locale: en), "62")
        XCTAssertEqual(MetricUnit.breathsPerMinute.number(15.84, locale: en), "15.8")
        XCTAssertEqual(MetricUnit.score(fractionDigits: 1).number(14.24, locale: de), "14,2")
        XCTAssertEqual(MetricUnit.score.number(61, locale: en), "61")
        XCTAssertNil(MetricUnit.score.symbol(locale: en))
    }

    func testDeltaCarriesSignAndUnit() {
        XCTAssertEqual(MetricUnit.milliseconds.formatDelta(8, locale: en), "+8\(nbsp)ms")
        XCTAssertEqual(MetricUnit.celsius.formatDelta(-0.3, locale: de), "-0,3\(nbsp)°C")
        XCTAssertEqual(MetricUnit.milliseconds.formatDelta(0, locale: en), "0\(nbsp)ms")
    }

    func testSpokenFormsSpellTheUnitOut() {
        // German spoken forms are covered by MetricCatalogueTests (the templates live in the app).
        XCTAssertEqual(MetricUnit.milliseconds.spoken(62, locale: en), "62 milliseconds")
        XCTAssertEqual(MetricUnit.beatsPerMinute.spoken(54, locale: en), "54 beats per minute")
    }

    func testDurationAsHoursAndMinutes() {
        let sevenFortyThree = 7 * 3600.0 + 43 * 60
        XCTAssertEqual(MetricUnit.duration.format(sevenFortyThree, locale: en), "7h 43m")
        XCTAssertEqual(MetricUnit.duration.format(sevenFortyThree, locale: de), "7h 43min")
        XCTAssertEqual(MetricUnit.duration.spoken(sevenFortyThree, locale: de), "7 Stunden und 43 Minuten")
        XCTAssertEqual(MetricUnit.duration.formatDelta(-25 * 60, locale: en), "-25m")
    }

    func testPercentFollowsLocale() {
        XCTAssertEqual(MetricUnit.percent.format(62, locale: en), "62%")
        XCTAssertEqual(MetricUnit.percent.format(62, locale: de), "62\(nbsp)%")
    }

    func testRangeSharesOneUnit() {
        XCTAssertEqual(MetricUnit.milliseconds.formatRange(48...58, locale: en), "48–58\(nbsp)ms")
        XCTAssertEqual(MetricUnit.celsius.formatRange(33.5...35.5, locale: de), "33,5–35,5\(nbsp)°C")
    }

    func testImperialConversions() {
        XCTAssertEqual(MetricUnit.mass(.imperial).format(75, locale: en), "165.3\(nbsp)lb")
        XCTAssertEqual(MetricUnit.mass(.metric).format(75, locale: en), "75.0\(nbsp)kg")
        XCTAssertEqual(MetricUnit.temperature(.imperial).format(36.4, locale: en), "97.5\(nbsp)°F")
        // A difference scales by 9/5 with no +32 offset.
        XCTAssertEqual(MetricUnit.fahrenheit.formatDelta(0.5, locale: en), "+0.9\(nbsp)°F")
        XCTAssertEqual(MetricUnit.fahrenheit.formatRange(36...37, locale: en), "96.8–98.6\(nbsp)°F")
    }

    func testDeviationIsSigned() {
        XCTAssertEqual(MetricUnit.celsiusDeviation.format(0.4, locale: de), "+0,4\(nbsp)°C")
        XCTAssertEqual(MetricUnit.celsiusDeviation.format(-0.3, locale: en), "-0.3\(nbsp)°C")
        XCTAssertEqual(MetricUnit.fahrenheitDeviation.format(0.5, locale: en), "+0.9\(nbsp)°F")
    }

    func testDurationAxisIsHoursAndMinutes() {
        XCTAssertEqual(MetricUnit.duration.axisLabel(27_000, locale: en), "7h 30m")
        XCTAssertEqual(MetricUnit.milliseconds.axisLabel(62, locale: en), "62")
    }

    func testPopulationRangeVerdictDoesNotSayYour() {
        let r = MetricReadout(id: .hrv, label: "HRV", value: 80, unit: .milliseconds, typicalRange: 50...70,
                              rangeIsPersonal: false, verdict: .above, meaning: "m")
        XCTAssertEqual(MetricPresentation(r, locale: en).verdict, "Above the typical range")
        XCTAssertTrue(MetricPresentation(r, locale: en).accessibilityValue.hasSuffix("Above the typical range"))
    }

    func testCompactEmptyStateIsShort() {
        let r = MetricReadout(id: .hrv, label: "HRV", value: nil, unit: .milliseconds,
                              verdict: .unavailable(.noData(since: nil)), meaning: "m")
        XCTAssertEqual(MetricPresentation(r, locale: en).compactVerdict, "No data")
    }
}
