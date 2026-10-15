import Foundation

/// Maps persistence-relevant app lifecycle edges onto the reason carried through Collector logs (testable without UIKit).
public enum StandardHRLifecycleFlush {
    public enum Event {
        case background
        case termination
    }

    public static func run(
        event: Event,
        flush: (LivePersistTrace.StandardHRFlushReason) async -> Void
    ) async {
        switch event {
        case .background:
            await flush(.background)
        case .termination:
            await flush(.termination)
        }
    }
}

/// A live HR/R-R batch failed to persist and was re-buffered. `Collector` swallows the error, so without this
/// line a store rejecting every insert reads like success in the log. The rendered text matches the Kotlin
/// `liveInsertFailedLine` for ASCII store errors (the 200-character bound counts grapheme clusters here, UTF-16
/// units there). Lives in the package, beside the other emitted-line builders, because `Collector` is app-target
/// Swift with no default CI.
public enum LivePersistTrace {

    public enum StandardHRFlushReason: String {
        case cadence
        case disconnect
        case background
        case termination
        case explicit
    }

    /// Bounded standard-HR transport-state diagnostics: host observation and buffer/persistence state only, no physiological values.
    public static func standardHRHostReceivedLine(
        hostUnixSeconds: Int,
        acceptedHRRows: Int, acceptedRRRows: Int,
        rejectedHRRows: Int, rejectedRRRows: Int,
        pendingHRRows: Int, pendingRRRows: Int
    ) -> String {
        "standard-hr transport host-received hostUnixSec=\(hostUnixSeconds)"
            + " acceptedHRRows=\(acceptedHRRows) acceptedRRRows=\(acceptedRRRows)"
            + " rejectedHRRows=\(rejectedHRRows) rejectedRRRows=\(rejectedRRRows)"
            + " pendingHRRows=\(pendingHRRows) pendingRRRows=\(pendingRRRows)"
    }

    /// Summarises the per-sample host-received line (written for every standard-HR sample, ~1/s, which was over
    /// half of a gym-session log). A sample the host refused (HR outside 30...220, R-R outside 250...3000 ms) is
    /// still written immediately; routine ones are counted and rendered once per window with count, span, widest
    /// gap, accepted/refused and pending. Full per-sample detail returns while the Test Centre HRV or Connection
    /// mode is on (`AGENTS.md`: gate per-sample readouts, keep rare-event evidence always on).
    public struct StandardHRHostReceivedTrace: Sendable {

        /// One host-received observation: the fields the per-sample line renders.
        public struct Sample: Sendable, Equatable {
            public var hostUnixSeconds: Int
            public var acceptedHRRows: Int
            public var acceptedRRRows: Int
            public var rejectedHRRows: Int
            public var rejectedRRRows: Int
            public var pendingHRRows: Int
            public var pendingRRRows: Int

            public init(hostUnixSeconds: Int, acceptedHRRows: Int, acceptedRRRows: Int,
                        rejectedHRRows: Int, rejectedRRRows: Int,
                        pendingHRRows: Int, pendingRRRows: Int) {
                self.hostUnixSeconds = hostUnixSeconds
                self.acceptedHRRows = acceptedHRRows
                self.acceptedRRRows = acceptedRRRows
                self.rejectedHRRows = rejectedHRRows
                self.rejectedRRRows = rejectedRRRows
                self.pendingHRRows = pendingHRRows
                self.pendingRRRows = pendingRRRows
            }
        }

        private var firstSecond: Int?
        private var lastSecond = 0
        private var samples = 0
        private var acceptedHR = 0
        private var acceptedRR = 0
        private var rejectedHR = 0
        private var rejectedRR = 0
        private var pendingHR = 0
        private var pendingRR = 0
        private var widestGap = 0

        public init() {}

        /// The lines to write for this sample; a finished window's summary comes first since it describes earlier samples.
        public mutating func record(_ sample: Sample, detailed: Bool) -> [String] {
            var lines: [String] = []
            if let first = firstSecond,
               // 60 s turns a streaming hour into 60 lines yet still shows a stall; a literal because a named constant would pair with the unrelated `windowSeconds` in the parity ledger.
               sample.hostUnixSeconds - first >= 60 || sample.hostUnixSeconds < first {
                // A clock that went backwards also ends the window: a span is only honest within one clock.
                if let summary = summaryLine() { lines.append(summary) }
                let previousLast = lastSecond
                let forwards = sample.hostUnixSeconds >= previousLast
                reset()
                // #2405: the gap that crossed this boundary is seeded into the NEW window (the summary just emitted describes
                // samples before the gap), so a stall longer than the window is still reported. Not seeded across a backwards
                // clock (no honest span) or across `close()`, where a disconnect already accounts for the silence.
                if forwards { widestGap = sample.hostUnixSeconds - previousLast }
            }
            if firstSecond == nil {
                firstSecond = sample.hostUnixSeconds
            } else {
                widestGap = max(widestGap, sample.hostUnixSeconds - lastSecond)
            }
            lastSecond = sample.hostUnixSeconds
            samples += 1
            acceptedHR += sample.acceptedHRRows
            acceptedRR += sample.acceptedRRRows
            rejectedHR += sample.rejectedHRRows
            rejectedRR += sample.rejectedRRRows
            pendingHR = sample.pendingHRRows
            pendingRR = sample.pendingRRRows
            if detailed || sample.rejectedHRRows > 0 || sample.rejectedRRRows > 0 {
                lines.append(standardHRHostReceivedLine(
                    hostUnixSeconds: sample.hostUnixSeconds,
                    acceptedHRRows: sample.acceptedHRRows, acceptedRRRows: sample.acceptedRRRows,
                    rejectedHRRows: sample.rejectedHRRows, rejectedRRRows: sample.rejectedRRRows,
                    pendingHRRows: sample.pendingHRRows, pendingRRRows: sample.pendingRRRows))
            }
            return lines
        }

        /// The window so far, for a disconnect, background flush or termination: the last minute of a session must not leave with the process.
        public mutating func close() -> [String] {
            guard let summary = summaryLine() else { return [] }
            reset()
            return [summary]
        }

        private func summaryLine() -> String? {
            guard let first = firstSecond, samples > 0 else { return nil }
            return "standard-hr transport host-received summary"
                + " windowSec=\(lastSecond - first) samples=\(samples) gapMaxSec=\(widestGap)"
                + " acceptedHRRows=\(acceptedHR) acceptedRRRows=\(acceptedRR)"
                + " rejectedHRRows=\(rejectedHR) rejectedRRRows=\(rejectedRR)"
                + " pendingHRRows=\(pendingHR) pendingRRRows=\(pendingRR)"
        }

        private mutating func reset() {
            firstSecond = nil
            lastSecond = 0
            samples = 0
            acceptedHR = 0; acceptedRR = 0
            rejectedHR = 0; rejectedRR = 0
            pendingHR = 0; pendingRR = 0
            widestGap = 0
        }
    }

    public static func standardHRFlushAttemptLine(
        reason: StandardHRFlushReason, offeredHRRows: Int, offeredRRRows: Int
    ) -> String {
        "standard-hr transport flush-attempt reason=\(reason.rawValue)"
            + " offeredHRRows=\(offeredHRRows) offeredRRRows=\(offeredRRRows)"
    }

    public static func standardHRFlushSucceededLine(
        reason: StandardHRFlushReason, offeredHRRows: Int, offeredRRRows: Int,
        insertedHRRows: Int, insertedRRRows: Int
    ) -> String {
        "standard-hr transport flush-succeeded reason=\(reason.rawValue)"
            + " offeredHRRows=\(offeredHRRows) offeredRRRows=\(offeredRRRows)"
            + " insertedHRRows=\(insertedHRRows) insertedRRRows=\(insertedRRRows)"
    }

    public static func standardHRRebufferedForRetryLine(
        reason: StandardHRFlushReason, attemptedHRRows: Int, attemptedRRRows: Int,
        pendingHRRows: Int, pendingRRRows: Int, consecutiveFailures: Int
    ) -> String {
        "standard-hr transport rebuffered-for-retry reason=\(reason.rawValue)"
            + " attemptedHRRows=\(attemptedHRRows) attemptedRRRows=\(attemptedRRRows)"
            + " pendingHRRows=\(pendingHRRows) pendingRRRows=\(pendingRRRows)"
            + " consecutiveFailures=\(consecutiveFailures)"
    }

    /// - Parameters:
    ///   - transport: which live path failed (standard 0x2A37 reading or puffin REALTIME_DATA batch, #1118); they fail independently.
    ///   - errorName: the error's type name.
    ///   - consecutiveFailures: one failure is the transient the re-buffer absorbs; a climbing count is a store that will never accept the rows.
    public static func liveInsertFailedLine(
        transport: String,
        errorName: String,
        message: String?,
        hrFrames: Int,
        rrFrames: Int,
        consecutiveFailures: Int
    ) -> String {
        // Bounded (ASCII-only): a full error description can be enormous and the useful cases are distinguished well inside 200.
        let detail = message.flatMap { m -> String? in
            let trimmed = m.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : ": " + String(m.prefix(200))
        } ?? ""
        let run = consecutiveFailures >= 2
            ? " \(consecutiveFailures) consecutive failures — these rows are not landing and the re-buffer is"
                + " not recovering them."
            : " Re-buffered for the next cadence."
        return "Live persist FAILED on \(transport) — \(errorName)\(detail) (hr=\(hrFrames) rr=\(rrFrames))."
            + run
    }

    /// Rate limit for ``liveInsertFailedLine(transport:errorName:message:hrFrames:rrFrames:consecutiveFailures:)``;
    /// deliberately long, since one line a minute establishes that inserts are failing as well as sixty. A zero
    /// `lastEmitMs` emits, and so does a backwards clock (otherwise `lastEmitMs` would strand in the future).
    public static func shouldEmitLiveInsertFailure(
        lastEmitMs: Int64,
        nowMs: Int64,
        minGapMs: Int64 = 60_000
    ) -> Bool {
        lastEmitMs <= 0 || nowMs < lastEmitMs || nowMs - lastEmitMs >= minGapMs
    }
}
