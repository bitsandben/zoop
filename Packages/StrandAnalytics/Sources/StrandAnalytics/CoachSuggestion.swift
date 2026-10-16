import Foundation

// CoachSuggestion.swift - the proactive coach's suggestion object and its pure bookkeeping.
//
// A suggestion is something the coach proposes for today ("bed by 22:40", "Upper A today") that the
// user can take, postpone or turn down. The outcome is kept so later briefs can stop repeating advice
// the user already declined. Pure and Codable: the app persists the list as one small JSON file.

/// One proposal from the coach, with what it is based on and what accepting it does.
public struct CoachSuggestion: Codable, Equatable, Identifiable, Sendable {

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case trainingToday, routine, sleepTiming, recovery, fasting, habit, general
    }

    public enum Status: String, Codable, Sendable {
        /// Waiting for an answer.
        case new
        /// The user agreed; the advice is theirs to follow (no app action behind it).
        case accepted
        /// Turned down. Feeds `CoachSuggestionLog.suppressed` so the advice is not repeated soon.
        case dismissed
        /// Accepted and the app carried the action out (reminder set, routine planned).
        case done
    }

    /// What accepting does. Kept as data so the store survives an app update that changes the copy.
    public enum Action: Codable, Equatable, Sendable {
        /// Advice only; accepting just records it.
        case none
        /// Aim for this Day Strain band (0-21 axis).
        case strainTarget(low: Int, high: Int)
        /// Plan this Lift Log program for today.
        case routine(programId: String, name: String)
        /// Be in bed by this minute of the day (0..<1440); accepting arms a wind-down reminder.
        case bedtime(minuteOfDay: Int)
        /// Start the next fast at this minute of the day. No longer proposed (the coach does not send
        /// generic fasting reminders); kept so suggestions stored by an earlier build still decode.
        case fastingStart(minuteOfDay: Int, planId: String)
        /// A short breathing break at this minute of the day; accepting arms a reminder.
        case breathe(minuteOfDay: Int)

        /// Stable name of the case, the contract a cloud reply has to echo back (`CoachBriefReply`).
        public var kindName: String {
            switch self {
            case .none: return "none"
            case .strainTarget: return "strainTarget"
            case .routine: return "routine"
            case .bedtime: return "bedtime"
            case .fastingStart: return "fastingStart"
            case .breathe: return "breathe"
            }
        }
    }

    public let id: String
    public let createdAt: Date
    public let kind: Kind
    /// Stable machine reason (`CoachMorningRules.Reason.rawValue`, or "ai"), the key the feedback loop
    /// matches on: copy can change between versions, the reason does not.
    public let reason: String
    public var title: String
    /// One sentence.
    public var body: String
    /// Why, grounded in the user's numbers, as one sentence ("Because your recovery is 28 % and …").
    public var rationale: String
    public let action: Action
    public var status: Status
    public let expiresAt: Date
    /// "Later" hides a suggestion until this moment without answering it.
    public var snoozedUntil: Date?
    /// When the status last changed from `.new`.
    public var answeredAt: Date?

    public init(id: String = UUID().uuidString, createdAt: Date, kind: Kind, reason: String,
                title: String, body: String, rationale: String, action: Action,
                status: Status = .new, expiresAt: Date, snoozedUntil: Date? = nil, answeredAt: Date? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.reason = reason
        self.title = title
        self.body = body
        self.rationale = rationale
        self.action = action
        self.status = status
        self.expiresAt = expiresAt
        self.snoozedUntil = snoozedUntil
        self.answeredAt = answeredAt
    }

    public func isExpired(at now: Date) -> Bool { now >= expiresAt }

    /// Shown on Today: unanswered, not expired, not snoozed.
    public func isActive(at now: Date) -> Bool {
        status == .new && !isExpired(at: now) && (snoozedUntil.map { now >= $0 } ?? true)
    }
}

/// The day's brief: the short text plus the suggestions generated with it.
public struct CoachDailyBrief: Codable, Equatable, Sendable {
    /// yyyy-MM-dd local day the brief is for.
    public let day: String
    public let createdAt: Date
    /// Two or three sentences.
    public let text: String
    /// True when a cloud provider wrote the text, false for the on-device rules.
    public let byAI: Bool
    /// The one-line takeaway for the compact Today card; nil on briefs stored before it existed.
    public let headline: String?
    /// Whether something stood out this morning (`MorningBriefDrivers`); nil on older briefs.
    public let notable: Bool?

    public init(day: String, createdAt: Date, text: String, byAI: Bool, headline: String? = nil,
                notable: Bool? = nil) {
        self.day = day
        self.createdAt = createdAt
        self.text = text
        self.byAI = byAI
        self.headline = headline
        self.notable = notable
    }
}

/// Pure operations over the stored suggestion list.
public enum CoachSuggestionLog {

    /// How long answered and expired suggestions are kept: long enough for the feedback window and a
    /// month of history, short enough that the JSON file stays tiny.
    public static let retentionDays = 45
    /// A reason turned down within this many days is not suggested again.
    public static let reasonCooldownDays = 4
    /// A kind turned down this many times within `kindWindowDays` is paused for that window.
    public static let kindDismissLimit = 3
    public static let kindWindowDays = 10

    /// Drops entries older than `retentionDays`, newest first. Stable: suggestions from one brief share
    /// a timestamp and keep the order the brief listed them in.
    public static func pruned(_ items: [CoachSuggestion], now: Date) -> [CoachSuggestion] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        return items.enumerated()
            .filter { $0.element.createdAt >= cutoff }
            .sorted { $0.element.createdAt != $1.element.createdAt
                ? $0.element.createdAt > $1.element.createdAt : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Adds a new brief's suggestions in front. Unanswered ones from an earlier brief the same day are
    /// replaced rather than kept, so a regenerated brief never shows the same advice twice; answered
    /// ones stay for the history and the feedback.
    public static func recording(_ new: [CoachSuggestion], into items: [CoachSuggestion], now: Date,
                                 calendar: Calendar = .current) -> [CoachSuggestion] {
        let kept = items.filter { !($0.status == .new && calendar.isDate($0.createdAt, inSameDayAs: now)) }
        return pruned(new + kept, now: now)
    }

    /// Records an answer. Snoozing keeps the status `.new`; every other answer stamps `answeredAt`.
    public static func answering(_ items: [CoachSuggestion], id: String, status: CoachSuggestion.Status,
                                 snoozeUntil: Date? = nil, now: Date) -> [CoachSuggestion] {
        items.map { item in
            guard item.id == id else { return item }
            var next = item
            if let snoozeUntil {
                next.snoozedUntil = snoozeUntil
            } else {
                next.status = status
                next.answeredAt = now
            }
            return next
        }
    }

    /// Reasons and kinds the next brief should leave out: recently turned down, or already answered
    /// today (a regenerated brief must not ask again what the user just took or declined).
    public static func suppressed(_ items: [CoachSuggestion], now: Date, calendar: Calendar = .current)
        -> (reasons: Set<String>, kinds: Set<CoachSuggestion.Kind>) {
        let dismissed = items.filter { $0.status == .dismissed }
        let reasonCutoff = now.addingTimeInterval(-Double(reasonCooldownDays) * 86_400)
        let answeredToday = items.filter { $0.answeredAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        let reasons = Set(dismissed.filter { ($0.answeredAt ?? $0.createdAt) >= reasonCutoff }.map(\.reason))
            .union(answeredToday.map(\.reason))
        let kindCutoff = now.addingTimeInterval(-Double(kindWindowDays) * 86_400)
        let counts = Dictionary(grouping: dismissed.filter { ($0.answeredAt ?? $0.createdAt) >= kindCutoff },
                                by: \.kind).mapValues(\.count)
        let kinds = Set(counts.filter { $0.value >= kindDismissLimit }.keys)
        return (reasons, kinds)
    }
}
