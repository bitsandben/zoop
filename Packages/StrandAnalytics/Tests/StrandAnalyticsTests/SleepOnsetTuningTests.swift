import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Onset strictness scaling, the learned personal offset and the onset evidence
/// (`SleepOnsetTuning.swift`). Synthetic evenings in the shape of `SleepOnsetTrimTests`: 14:00–22:00
/// active, 22:00–23:05 quiet on the sofa at a chosen HR, then asleep at ~55 bpm until 07:00.
final class SleepOnsetTuningTests: XCTestCase {

    private let t14 = 1_749_513_600 - 10 * 3600
    private func at(_ hour: Int, _ minute: Int = 0) -> Int {
        let h = hour >= 14 ? hour - 14 : hour + 10
        return t14 + h * 3600 + minute * 60
    }

    private func gravity(_ from: Int, _ to: Int, active: Bool, fidgetEveryMin: Int? = nil) -> [GravitySample] {
        (from..<to).map { ts in
            let i = ts - from
            var moving = active
            if let every = fidgetEveryMin, i % (every * 60) < 20 { moving = true }
            let x = moving ? Double(i % 2) * 0.5 : 0.0
            return GravitySample(ts: ts, x: x, y: 0, z: 1.0)
        }
    }

    private func hr(_ from: Int, _ to: Int, _ bpm: (Int) -> Int) -> [HRSample] {
        stride(from: from, to: to, by: 2).map { HRSample(ts: $0, bpm: bpm($0)) }
    }

    private func sleepingBpm(_ ts: Int) -> Int { 55 + [0, 1, 2, 1, 0, -1, -2, -1][(ts / 60) % 8] }

    private func evening(sofaBpm: Int) -> (hr: [HRSample], grav: [GravitySample]) {
        let sleepStart = at(23, 5)
        var g = gravity(at(14), at(22), active: true)
        g += gravity(at(22), sleepStart, active: false, fidgetEveryMin: 8)
        g += gravity(sleepStart, at(7), active: false)
        g += gravity(at(7), at(9), active: true)
        var h = hr(at(14), at(22)) { _ in 85 }
        h += hr(at(22), sleepStart) { ts in sofaBpm + [0, 1, -1][(ts / 60) % 3] }
        h += hr(sleepStart, at(7)) { ts in
            let minIn = Double(ts - sleepStart) / 60.0
            if minIn < 10 { return Int((68.0 - 1.3 * minIn).rounded()) }
            return self.sleepingBpm(ts)
        }
        h += hr(at(7), at(9)) { _ in 85 }
        return (h, g)
    }

    private func start(_ e: (hr: [HRSample], grav: [GravitySample]), _ tuning: SleepOnsetTuning) throws -> Int {
        let s = SleepStager.detectSleep(hr: e.hr, gravity: e.grav, onsetTuning: tuning)
        return try XCTUnwrap(s.max { ($0.end - $0.start) < ($1.end - $1.start) }).start
    }

    private func isTrimmed(_ start: Int) -> Bool { start >= at(23, 0) && start <= at(23, 15) }

    // MARK: Threshold scaling

    func testStandardIsTheShippedRule() {
        let t = OnsetTrimThresholds.forStrictness(.standard)
        XCTAssertEqual(t, .standard)
        XCTAssertEqual(t.awakeMult, SleepStager.onsetTrimAwakeMult)
        XCTAssertEqual(t.awakeMinDeltaBpm, SleepStager.onsetTrimAwakeMinDeltaBpm)
        XCTAssertEqual(t.sleepBandMult, SleepStager.onsetTrimSleepBandMult)
        XCTAssertEqual(t.minLeadMin, SleepStager.onsetTrimMinLeadMin)
        XCTAssertEqual(SleepOnsetTuning.standard.signature, "")
    }

    func testStrictnessScalesEveryMargin() {
        let strict = OnsetTrimThresholds.forStrictness(.strict)
        let relaxed = OnsetTrimThresholds.forStrictness(.relaxed)
        let std = OnsetTrimThresholds.standard
        XCTAssertEqual(strict.awakeMult, 1.12, accuracy: 1e-9)
        XCTAssertEqual(strict.awakeMinDeltaBpm, 4.8, accuracy: 1e-9)
        XCTAssertEqual(strict.sleepBandMult, 1.072, accuracy: 1e-9)
        XCTAssertEqual(strict.minLeadMin, 6)
        XCTAssertEqual(relaxed.awakeMult, 1.30, accuracy: 1e-9)
        XCTAssertEqual(relaxed.awakeMinDeltaBpm, 12, accuracy: 1e-9)
        XCTAssertEqual(relaxed.sleepBandMult, 1.18, accuracy: 1e-9)
        XCTAssertEqual(relaxed.minLeadMin, 15)
        // Not margins: unchanged.
        for t in [strict, relaxed] {
            XCTAssertEqual(t.windowMin, std.windowMin)
            XCTAssertEqual(t.sleepLevelPct, std.sleepLevelPct)
            XCTAssertEqual(t.minHRMinutes, std.minHRMinutes)
            XCTAssertEqual(t.stillFrac, std.stillFrac)
        }
    }

    func testStandardTuningIsByteIdenticalToTheDefault() throws {
        let e = evening(sofaBpm: 76)
        XCTAssertEqual(SleepStager.detectSleep(hr: e.hr, gravity: e.grav),
                       SleepStager.detectSleep(hr: e.hr, gravity: e.grav, onsetTuning: .standard))
    }

    func testStrictCutsAModeratelyRaisedLeadThatStandardKeeps() throws {
        // ~7 bpm above the sleeping level: below Standard's awake bar, above Strict's.
        let e = evening(sofaBpm: 62)
        XCTAssertLessThan(try start(e, .standard), at(22, 20))
        XCTAssertTrue(isTrimmed(try start(e, SleepOnsetTuning(strictness: .strict))))
    }

    func testRelaxedKeepsALeadThatStandardCuts() throws {
        // ~13 bpm above the sleeping level: above Standard's awake bar, below Relaxed's.
        let e = evening(sofaBpm: 68)
        XCTAssertTrue(isTrimmed(try start(e, .standard)))
        XCTAssertLessThan(try start(e, SleepOnsetTuning(strictness: .relaxed)), at(22, 20))
    }

    // MARK: Personal offset

    func testPositiveOffsetMovesTheOnsetLater() throws {
        let e = evening(sofaBpm: 76)
        let base = try start(e, .standard)
        XCTAssertEqual(try start(e, SleepOnsetTuning(personalOffsetMin: 20)), base + 20 * 60)
    }

    func testNegativeOffsetNeverStartsBeforeTheWristWentStill() throws {
        let e = evening(sofaBpm: 76)
        let base = try start(e, .standard)
        XCTAssertEqual(try start(e, SleepOnsetTuning(personalOffsetMin: -30)), base - 30 * 60)
        // A night that was not trimmed already starts where the wrist went still: unchanged.
        let control = evening(sofaBpm: 55)
        let controlStart = try start(control, .standard)
        XCTAssertEqual(try start(control, SleepOnsetTuning(personalOffsetMin: -45)), controlStart)
    }

    func testOffsetHelperBounds() {
        let runStart = 1_000_000, runEnd = runStart + 8 * 3600
        XCTAssertEqual(SleepStager.applyingOnsetOffset(onsetTs: runStart + 3600, runStart: runStart,
                                                       runEnd: runEnd, offsetMin: 0), runStart + 3600)
        XCTAssertEqual(SleepStager.applyingOnsetOffset(onsetTs: runStart + 600, runStart: runStart,
                                                       runEnd: runEnd, offsetMin: -45), runStart)
        // Never leaves the run at or below minSleepMin.
        let shortEnd = runStart + 70 * 60
        let moved = SleepStager.applyingOnsetOffset(onsetTs: runStart, runStart: runStart,
                                                    runEnd: shortEnd, offsetMin: 45)
        XCTAssertGreaterThan(shortEnd - moved, SleepStager.minSleepMin * 60)
    }

    // MARK: Evidence

    func testEvidenceExplainsATrimmedNight() throws {
        let e = evening(sofaBpm: 76)
        let detected = try XCTUnwrap(SleepStager.detectSleep(hr: e.hr, gravity: e.grav)
            .max { ($0.end - $0.start) < ($1.end - $1.start) })
        let ev = try XCTUnwrap(SleepStager.explainOnset(hr: e.hr, gravity: e.grav,
                                                        sessionStart: detected.start, sessionEnd: detected.end))
        XCTAssertEqual(ev.outcome, .trimmed)
        XCTAssertEqual(ev.onsetTs, detected.start, "the explanation names the start detection used")
        XCTAssertLessThan(ev.stillSinceTs, at(22, 10))
        XCTAssertEqual(ev.appliedOffsetMin, 0)
        let above = try XCTUnwrap(ev.leadAboveLevelBpm)
        XCTAssertGreaterThanOrEqual(above, 18)
        XCTAssertLessThanOrEqual(above, 24)
        XCTAssertFalse(ev.minuteHR.isEmpty)
        XCTAssertEqual(ev.minuteHR.count, ev.minuteMoving.count)
    }

    func testEvidenceForAnUntrimmedNight() throws {
        let e = evening(sofaBpm: 55)
        let detected = try XCTUnwrap(SleepStager.detectSleep(hr: e.hr, gravity: e.grav)
            .max { ($0.end - $0.start) < ($1.end - $1.start) })
        let ev = try XCTUnwrap(SleepStager.explainOnset(hr: e.hr, gravity: e.grav,
                                                        sessionStart: detected.start, sessionEnd: detected.end))
        XCTAssertNotEqual(ev.outcome, .trimmed)
        XCTAssertEqual(ev.onsetTs, detected.start)
        XCTAssertEqual(ev.onsetTs, ev.stillSinceTs)
    }

    func testEvidenceCarriesTheAppliedOffset() throws {
        let e = evening(sofaBpm: 76)
        let tuning = SleepOnsetTuning(personalOffsetMin: 15)
        let detected = try XCTUnwrap(SleepStager.detectSleep(hr: e.hr, gravity: e.grav, onsetTuning: tuning)
            .max { ($0.end - $0.start) < ($1.end - $1.start) })
        let ev = try XCTUnwrap(SleepStager.explainOnset(hr: e.hr, gravity: e.grav, sessionStart: detected.start,
                                                        sessionEnd: detected.end, tuning: tuning))
        XCTAssertEqual(ev.onsetTs, detected.start)
        XCTAssertEqual(ev.appliedOffsetMin, 15)
        XCTAssertEqual(ev.ruleOnsetTs, detected.start - 15 * 60)
    }

    // MARK: Learning from corrections

    private typealias L = OnsetCorrectionLearning
    private func c(_ key: Int, _ d: Double) -> L.Correction { L.Correction(nightKey: key, deltaMin: d) }

    func testNothingIsLearnedFromFewerThanThree() {
        XCTAssertNil(L.learnedOffsetMin([]))
        XCTAssertNil(L.learnedOffsetMin([c(1, 20), c(2, 25)]))
        XCTAssertEqual(L.learnedOffsetMin([c(1, 20), c(2, 25), c(3, 18)]), 20)
    }

    func testCorrectionsThatDisagreeTeachNothing() {
        XCTAssertNil(L.learnedOffsetMin([c(1, 20), c(2, -25), c(3, 18)]))
        XCTAssertNil(L.learnedOffsetMin([c(1, 20), c(2, 0), c(3, 18)]), "a zero correction points nowhere")
        // Three of four agreeing is enough.
        XCTAssertEqual(L.learnedOffsetMin([c(1, 20), c(2, -5), c(3, 18), c(4, 30)]), 19)
        // Earlier, too.
        XCTAssertEqual(L.learnedOffsetMin([c(1, -10), c(2, -14), c(3, -12)]), -12)
    }

    func testLearnedOffsetIsClamped() {
        XCTAssertEqual(L.learnedOffsetMin([c(1, 90), c(2, 120), c(3, 75)]), 45)
        XCTAssertEqual(L.learnedOffsetMin([c(1, -90), c(2, -120), c(3, -75)]), -45)
    }

    func testRecordingReplacesTheSameNightAndKeepsTwenty() {
        var list: [L.Correction] = []
        for i in 0..<25 { list = L.recording(c(i, Double(i)), into: list) }
        XCTAssertEqual(list.count, L.maxStored)
        XCTAssertEqual(list.first?.nightKey, 5)
        list = L.recording(c(10, 99), into: list)
        XCTAssertEqual(list.count, L.maxStored)
        XCTAssertEqual(list.filter { $0.nightKey == 10 }.map(\.deltaMin), [99])
        XCTAssertEqual(list.last?.nightKey, 10)
    }

    func testCorrectionIsMeasuredAgainstTheBareRule() {
        // Detection already carried a +20 min offset; the wearer moved the start a further 10 min later.
        let x = L.correction(nightKey: 7, detectedStartTs: 10_000, correctedStartTs: 10_600, appliedOffsetMin: 20)
        XCTAssertEqual(x.deltaMin, 30, accuracy: 1e-9)
    }

    func testCodecRoundTrips() {
        let list = [c(1, 12.5), c(2, -3)]
        XCTAssertEqual(L.decode(L.encode(list)), list)
        XCTAssertEqual(L.decode(nil), [])
        XCTAssertEqual(L.decode("garbage"), [])
    }
}
