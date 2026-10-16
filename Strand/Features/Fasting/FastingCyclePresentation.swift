#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - View data for the cycle: the hero ring, Today's card, the week strip and the stats grid
//
// All built from one `FastingCycleState` (`FastingLog.state`) and one clock passed in, so the hero,
// Today and the Shortcut dialog can't name different phases or countdowns.

/// The two-phase ring: the fasting arc (goal) and the eating arc (window), each filled as it runs.
struct FastingRingModel: Equatable {
    /// Share of the circle the fasting arc takes; the eating arc is the rest.
    let fastingShare: Double
    let fastingFill: Double
    let eatingFill: Double
    let markers: [Marker]

    struct Marker: Equatable, Hashable {
        /// Fraction of the whole circle.
        let fraction: Double
        let label: String
    }

    static let empty = FastingRingModel(fastingShare: 1, fastingFill: 0, eatingFill: 0, markers: [])

    static func fasting(_ status: FastingStatus, schedule: FastingSchedule) -> FastingRingModel {
        let share = FastingCycle.ringFastingShare(goal: status.goal, eatingWindow: schedule.eatingWindowLength)
        let markers = FastingEngine.markerFractions(goal: status.goal).map {
            Marker(fraction: $0.fraction * share, label: FastingFormat.duration($0.hours * 3600))
        }
        return FastingRingModel(fastingShare: share, fastingFill: status.progress, eatingFill: 0, markers: markers)
    }

    static func eating(_ window: EatingWindow, schedule: FastingSchedule, now: Date) -> FastingRingModel {
        let share = FastingCycle.ringFastingShare(goal: schedule.plan.goal, eatingWindow: window.length)
        return FastingRingModel(fastingShare: share, fastingFill: 1, eatingFill: window.progress(now: now), markers: [])
    }
}

/// What the Fasting hero shows at one instant.
enum FastingTimerState: Equatable {
    case fasting(Fasting)
    case eating(Eating)
    /// Not fasting: the next fast is due (`title` "Time to fast") or not yet planned.
    case idle(Idle)

    struct Fasting: Equatable {
        let ring: FastingRingModel
        let clock: String
        let ofGoal: LocalizedStringResource
        let status: LocalizedStringResource
        let goalReached: Bool
        let phase: LocalizedStringResource
        let since: LocalizedStringResource
        let goal: LocalizedStringResource
    }

    struct Eating: Equatable {
        let ring: FastingRingModel
        /// Time left in the window, "3:12:05".
        let clock: String
        /// "Eating window closes in 3h 12min".
        let closesIn: LocalizedStringResource
        let opened: LocalizedStringResource
        let closes: LocalizedStringResource
    }

    struct Idle: Equatable {
        let title: LocalizedStringResource
        let detail: LocalizedStringResource?
    }

    static func make(_ state: FastingCycleState, schedule: FastingSchedule, lastEnd: Date?, now: Date) -> FastingTimerState {
        switch state {
        case .fasting(let interval, let s):
            return .fasting(Fasting(
                ring: .fasting(s, schedule: schedule),
                clock: FastingFormat.clock(s.elapsed),
                ofGoal: FastingStrings.ofGoal(FastingFormat.duration(s.goal)),
                status: s.goalReached ? FastingStrings.goalReached
                    : FastingStrings.remaining(FastingFormat.duration(s.remaining)),
                goalReached: s.goalReached,
                phase: FastingStrings.phase(s.phase),
                since: FastingStrings.since(FastingFormat.time(interval.start)),
                goal: FastingStrings.goalAt(FastingFormat.time(s.goalDate))))
        case .eating(let w):
            return .eating(Eating(
                ring: .eating(w, schedule: schedule, now: now),
                clock: FastingFormat.clock(w.remaining(now: now)),
                closesIn: FastingStrings.windowClosesIn(FastingFormat.duration(w.remaining(now: now))),
                opened: FastingStrings.windowOpened(FastingFormat.time(w.opens)),
                closes: FastingStrings.windowClosesAt(FastingFormat.time(w.closes))))
        case .due(let since):
            return .idle(Idle(title: FastingStrings.timeToFast,
                              detail: FastingStrings.windowClosedAt(FastingFormat.time(since))))
        case .waiting(let next):
            if let next {
                return .idle(Idle(title: FastingStrings.nextFastAt(FastingFormat.dayAndTime(next)),
                                  detail: lastEnd.map { FastingStrings.lastEnded(FastingFormat.dayAndTime($0)) }))
            }
            return .idle(Idle(title: FastingStrings.notFasting,
                              detail: lastEnd.map { FastingStrings.lastEnded(FastingFormat.dayAndTime($0)) }))
        }
    }
}

/// Today's compact card. Hidden only for people who never turned fasting on.
enum FastingTodayState: Equatable {
    case hidden
    case shown(Card)

    enum Phase: Equatable { case fasting, eating, idle }

    struct Card: Equatable {
        let phase: Phase
        let progress: Double
        /// "Fasting · Fasted", "Eating window", "Eating window closed".
        let caption: LocalizedStringResource
        /// Elapsed fast, "Closes in 3h 12min", "Time to fast".
        let headline: String
        /// Goal time while fasting; nil otherwise.
        let detail: LocalizedStringResource?
        let goalReached: Bool
    }

    /// Fasts started within this window keep the card for people from before the explicit setting.
    static let recentWindow: TimeInterval = 7 * 86_400

    static func make(rows: [FastingSessionRow], state: FastingCycleState, showOnToday: Bool, now: Date) -> FastingTodayState {
        let recent = rows.contains { TimeInterval($0.startTs) >= now.addingTimeInterval(-recentWindow).timeIntervalSince1970 }
        guard showOnToday || recent || state.isFasting else { return .hidden }
        switch state {
        case .fasting(_, let s):
            return .shown(Card(phase: .fasting, progress: s.progress,
                               caption: FastingTodayStrings.fastingCaption(String(localized: FastingStrings.phase(s.phase))),
                               headline: FastingFormat.duration(s.elapsed),
                               detail: s.goalReached ? FastingTodayStrings.goalReached
                                   : FastingTodayStrings.goalAt(FastingFormat.time(s.goalDate)),
                               goalReached: s.goalReached))
        case .eating(let w):
            return .shown(Card(phase: .eating, progress: w.progress(now: now), caption: FastingTodayStrings.eatingCaption,
                               headline: String(localized: FastingTodayStrings.closesIn(FastingFormat.duration(w.remaining(now: now)))),
                               detail: nil, goalReached: false))
        case .due(let since):
            return .shown(Card(phase: .idle, progress: 0,
                               caption: FastingTodayStrings.closedCaption(FastingFormat.time(since)),
                               headline: String(localized: FastingStrings.timeToFast), detail: nil, goalReached: false))
        case .waiting(let next):
            return .shown(Card(phase: .idle, progress: 0, caption: FastingTodayStrings.idleCaption,
                               headline: String(localized: next.map { FastingTodayStrings.plannedAt(FastingFormat.time($0)) }
                                   ?? FastingStrings.notFasting),
                               detail: nil, goalReached: false))
        }
    }
}

/// The week strip: one 24-hour bar per day with fasting and eating pieces.
struct FastingTimelineWeek: Equatable {
    struct Row: Identifiable, Equatable {
        var id: Date { day }
        let day: Date
        let label: String
        let segments: [FastingTimelineSegment]
    }

    let rows: [Row]
    let takeaway: LocalizedStringResource
    let isEmpty: Bool

    static func make(_ days: [FastingTimelineDay], week: [FastingDay]) -> FastingTimelineWeek {
        let rows = days.map {
            Row(day: $0.dayStart,
                label: $0.dayStart.formatted(.dateTime.weekday(.abbreviated).locale(FastingFormat.locale)),
                segments: $0.segments)
        }
        let empty = days.allSatisfy(\.segments.isEmpty)
        return FastingTimelineWeek(rows: rows,
                                   takeaway: empty ? FastingStrings.weekEmpty
                                       : FastingStrings.weekTakeaway(met: week.filter(\.met).count, days: week.count),
                                   isEmpty: empty)
    }
}

/// The stats grid: four tiles, or one line before the first finished fast.
enum FastingStatsModel: Equatable {
    case empty
    case tiles([Tile])

    struct Tile: Identifiable, Equatable {
        var id: String { key }
        let key: String
        let label: LocalizedStringResource
        let value: String
        let note: LocalizedStringResource?
    }

    static func make(_ stats: FastingStats, streak: Int, consistency: FastingConsistency) -> FastingStatsModel {
        guard stats.fastsCounted > 0, let avg = stats.averageFast, let longest = stats.longestFast else { return .empty }
        let adherence = stats.adherence.map { ZoopNumber.percent($0 * 100, locale: FastingFormat.locale) }
        var tiles = [
            Tile(key: "avg", label: FastingStrings.statAverage, value: FastingFormat.duration(avg),
                 note: stats.averageEatingWindow.map { FastingStrings.statAverageWindow(FastingFormat.duration($0)) }),
            Tile(key: "longest", label: FastingStrings.statLongest, value: FastingFormat.duration(longest), note: nil),
            Tile(key: "streak", label: FastingStrings.streakLabel,
                 value: String(localized: FastingStrings.streakValue(streak)), note: nil),
        ]
        if let adherence {
            tiles.append(Tile(key: "adherence", label: FastingStrings.statAdherence, value: adherence,
                              note: FastingStrings.consistencyValue(met: consistency.metDays, of: consistency.consideredDays)))
        }
        return .tiles(tiles)
    }
}
#endif
