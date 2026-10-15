import Foundation
import StrandDesign

// MARK: - My Dashboard (the configurable tile grid on Today)
//
// Which tiles the user picked, in their order, persisted as one comma-separated string. The rings
// already show Sleep, Recovery and Strain, so none of those is offered here.

/// One kind of tile the dashboard can show. The raw value is the persisted token: never rename it.
enum TodayTileKind: String, CaseIterable, Identifiable, Sendable {
    case hrv, restingHR, respiratory, spo2, skinTemp
    case steps, calories, weight
    case stress, sleepDebt, fitnessAge, vo2max, energy, fasting

    var id: String { rawValue }

    var label: LocalizedStringResource {
        switch self {
        case .hrv: return TodayCopy.tileHRV
        case .restingHR: return TodayCopy.tileRestingHR
        case .respiratory: return TodayCopy.tileRespiratory
        case .spo2: return TodayCopy.tileSpO2
        case .skinTemp: return TodayCopy.tileSkinTemp
        case .steps: return TodayCopy.steps
        case .calories: return TodayCopy.calories
        case .weight: return TodayCopy.weight
        case .stress: return TodayCopy.tileStressDaily
        case .sleepDebt: return TodayCopy.tileSleepDebt
        case .fitnessAge: return TodayCopy.fitnessAge
        case .vo2max: return TodayCopy.tileVO2max
        case .energy: return TodayCopy.energy
        case .fasting: return TodayCopy.tileFasting
        }
    }

    var systemImage: String {
        switch self {
        case .hrv: return "waveform.path.ecg"
        case .restingHR: return "heart"
        case .respiratory: return "lungs"
        case .spo2: return "drop"
        case .skinTemp: return "thermometer.medium"
        case .steps: return "figure.walk"
        case .calories: return "flame"
        case .weight: return "scalemass"
        case .stress: return "gauge.with.dots.needle.33percent"
        case .sleepDebt: return "bed.double"
        case .fitnessAge: return "figure.run"
        case .vo2max: return "heart.text.square"
        case .energy: return "battery.75percent"
        case .fasting: return "timer"
        }
    }

    /// The screen a tap opens; nil opens the number's explainer instead.
    var route: TabRoute? {
        switch self {
        case .stress: return .stress
        case .sleepDebt: return .sleep
        case .fitnessAge, .vo2max: return .fitnessAge
        case .energy: return .energyBank
        case .fasting: return .fasting
        case .hrv, .restingHR, .respiratory, .spo2, .skinTemp, .steps, .calories, .weight: return nil
        }
    }
}

/// One filled tile: the readout and the last 30 days for its sparkline.
struct TodayDashboardTile: Identifiable, Equatable {
    let kind: TodayTileKind
    let readout: MetricReadout
    let trend: [MetricExplanation.TrendPoint]
    var id: TodayTileKind { kind }

    var isUnavailable: Bool {
        if case .unavailable = readout.verdict { return true }
        return false
    }
}

/// The persisted selection and the pure edits the "Customise" sheet makes to it.
enum TodayDashboardPrefs {
    static let storageKey = "zoop.today.dashboardTiles"
    /// Six tiles on first launch: vitals, activity and the two longer-term numbers.
    static let defaults: [TodayTileKind] = [.hrv, .restingHR, .steps, .calories, .sleepDebt, .fitnessAge]
    /// Stored for a deliberately empty dashboard, so it does not fall back to the defaults.
    private static let emptyToken = "none"

    /// Unset means the defaults; unknown tokens (a tile removed in a later version) are dropped.
    static func decode(_ raw: String) -> [TodayTileKind] {
        if raw.isEmpty { return defaults }
        if raw == emptyToken { return [] }
        var seen = Set<TodayTileKind>()
        return raw.split(separator: ",").compactMap { TodayTileKind(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
    }

    static func encode(_ kinds: [TodayTileKind]) -> String {
        kinds.isEmpty ? emptyToken : kinds.map(\.rawValue).joined(separator: ",")
    }

    /// The kinds not on the dashboard yet, in catalogue order.
    static func available(excluding kinds: [TodayTileKind]) -> [TodayTileKind] {
        TodayTileKind.allCases.filter { !kinds.contains($0) }
    }

    static func adding(_ kind: TodayTileKind, to kinds: [TodayTileKind]) -> [TodayTileKind] {
        kinds.contains(kind) ? kinds : kinds + [kind]
    }

    static func removing(_ kind: TodayTileKind, from kinds: [TodayTileKind]) -> [TodayTileKind] {
        kinds.filter { $0 != kind }
    }

    static func moving(_ kinds: [TodayTileKind], from source: IndexSet, to destination: Int) -> [TodayTileKind] {
        var out = kinds
        let moved = source.sorted().map { out[$0] }
        for index in source.sorted(by: >) { out.remove(at: index) }
        let shift = source.filter { $0 < destination }.count
        out.insert(contentsOf: moved, at: min(max(0, destination - shift), out.count))
        return out
    }

    /// The live refresh moves the Energy Bank; its tile follows with the same readout as the card.
    static func replacingEnergyTile(_ tiles: [TodayDashboardTile], with energy: MetricReadout?) -> [TodayDashboardTile] {
        guard let energy else { return tiles }
        return tiles.map { tile in
            tile.kind == .energy ? TodayDashboardTile(kind: .energy, readout: energy, trend: tile.trend) : tile
        }
    }
}
