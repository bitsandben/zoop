import Foundation

// The smart alarm's live heart-rate stream, as one night's record: when the app asked for the stream and why it
// let go, which samples arrived, and where they stopped for more than a minute (the app suspended, or the strap
// out of range: the record cannot tell those apart, so it names only the gap). Pure folds, tested without a strap.

extension SmartAlarmNight {

    /// Why the app asked for the live stream, or stopped asking.
    public enum LiveReason: String, Codable, Sendable {
        /// On: the window opens within the lead time.
        case windowOpening
        /// On: the strap reconnected inside the window.
        case reconnected
        /// On: the Live screen closed inside the window; the smart alarm took the stream back.
        case liveScreenClosed
        /// Off (for the smart alarm): the Live screen opened and now owns the stream.
        case liveScreenOpened
        /// Off: the strap reported its alarm went off.
        case woken
        /// Off: the early wake passed without a report from the strap.
        case earlyWakePassed
        /// Off: the window ended.
        case windowEnded
        /// Off: the strap disconnected.
        case strapDisconnected
        /// Off: iOS is closing the app.
        case appTerminating
        /// Off: still held long after the window end (should not happen; the watchdog caught it).
        case watchdog
        /// Off: the setting or the alarm was turned off, or the alarm moved.
        case settingOff
        /// Off: a previous run left the stream on and nothing wants it now (sent on the first connection).
        case leftOnByPreviousRun
    }

    /// One request to the stream: `on` is the app's own reference, not proof the strap streamed.
    public struct LiveToggle: Codable, Equatable, Sendable {
        public var at: Int
        public var on: Bool
        public var reason: LiveReason
        public init(at: Int, on: Bool, reason: LiveReason) { self.at = at; self.on = on; self.reason = reason }
    }

    /// No live sample between `start` and `end` while the stream was held.
    public struct LiveGap: Codable, Equatable, Sendable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
    }

    public struct LiveStream: Codable, Equatable, Sendable {
        /// A pause between samples longer than this is a gap.
        public static let gapS = 60

        public var toggles: [LiveToggle] = []
        public var firstSampleAt: Int?
        public var lastSampleAt: Int?
        /// Samples received with a time inside the window (one per second at most).
        public var samplesInWindow = 0
        public var gaps: [LiveGap] = []

        public init() {}

        public var isHeld: Bool { toggles.last?.on ?? false }
        /// The last "off", when the stream is no longer held.
        public var lastOff: LiveToggle? { isHeld ? nil : toggles.last }

        /// Records a request; a repeat of the current state is not news.
        public mutating func toggle(on: Bool, reason: LiveReason, at: Int) {
            if isHeld == on, !toggles.isEmpty { return }
            if !on, toggles.isEmpty { return }
            toggles.append(.init(at: at, on: on, reason: reason))
        }

        /// Folds samples received while held, in time order. Only samples while held count toward gaps: a
        /// pause while the app had let go of the stream is not the stream failing.
        public mutating func note(samples ts: [Int], window: GoalWake.Window) {
            for t in ts.sorted() {
                if let last = lastSampleAt {
                    guard t > last else { continue }
                    if t - last > Self.gapS { gaps.append(.init(start: last, end: t)) }
                }
                if firstSampleAt == nil { firstSampleAt = t }
                lastSampleAt = t
                if t >= window.start && t <= window.end { samplesInWindow += 1 }
            }
        }

        /// A gap still open at `now`: held, and nothing arrived for more than `gapS` (counted only for display).
        public func openGap(now: Int) -> LiveGap? {
            guard isHeld, let since = lastSampleAt ?? toggles.last?.at, now - since > Self.gapS else { return nil }
            return .init(start: since, end: now)
        }
    }

    /// Evaluations in the window by what drove them.
    public var evaluationsByTrigger: (stream: Int, timer: Int, appWake: Int) {
        let c = checksInWindow
        return (c.filter { $0.trigger == .stream }.count, c.filter { $0.trigger == .timer }.count,
                c.filter { $0.trigger == .appWake }.count)
    }
}
