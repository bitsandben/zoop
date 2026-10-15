import Foundation

// MARK: - Live workout fields and layouts
//
// What the live workout screen shows: one large primary field and a grid of smaller ones, chosen per
// sport and remembered in UserDefaults under `zoop.workout.liveFields.<sport>`. The layout is plain
// data with a tiny text codec ("primary;field,field,…") so a stored value from an older build with an
// unknown field still decodes (unknown names are dropped).

enum LiveWorkoutField: String, CaseIterable, Identifiable {
    case time, distance, currentPace, averagePace, heartRate, zone, averageHeartRate
    case calories, effort, elevation, splits

    var id: String { rawValue }

    /// Fields that only mean something with a GPS route.
    var needsGPS: Bool {
        switch self {
        case .distance, .currentPace, .averagePace, .elevation, .splits: return true
        default: return false
        }
    }

    /// The split list is a list, not a number, so it cannot be the large field.
    var canBePrimary: Bool { self != .splits }

    var title: String {
        switch self {
        case .time: return LiveWorkoutStrings.fieldTime
        case .distance: return LiveWorkoutStrings.fieldDistance
        case .currentPace: return LiveWorkoutStrings.fieldCurrentPace
        case .averagePace: return LiveWorkoutStrings.fieldAveragePace
        case .heartRate: return LiveWorkoutStrings.fieldHeartRate
        case .zone: return LiveWorkoutStrings.fieldZone
        case .averageHeartRate: return LiveWorkoutStrings.fieldAverageHeartRate
        case .calories: return LiveWorkoutStrings.fieldCalories
        case .effort: return LiveWorkoutStrings.fieldEffort
        case .elevation: return LiveWorkoutStrings.fieldElevation
        case .splits: return LiveWorkoutStrings.fieldSplits
        }
    }

    var systemImage: String {
        switch self {
        case .time: return "stopwatch"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath"
        case .currentPace: return "speedometer"
        case .averagePace: return "gauge.with.dots.needle.33percent"
        case .heartRate: return "heart.fill"
        case .zone: return "chart.bar.fill"
        case .averageHeartRate: return "heart"
        case .calories: return "flame.fill"
        case .effort: return "bolt.fill"
        case .elevation: return "mountain.2.fill"
        case .splits: return "list.number"
        }
    }

    /// The fields a sport may offer: everything, minus the route fields for a sport without GPS.
    static func available(gps: Bool) -> [LiveWorkoutField] {
        allCases.filter { gps || !$0.needsGPS }
    }
}

struct LiveWorkoutLayout: Equatable {
    var primary: LiveWorkoutField
    /// Grid fields in display order; may contain `.splits`, which renders as the list under the grid.
    var fields: [LiveWorkoutField]

    var gridFields: [LiveWorkoutField] { fields.filter { $0 != .splits && $0 != primary } }
    var showsSplits: Bool { fields.contains(.splits) }

    static let defaultsPrefix = "zoop.workout.liveFields."

    static func key(sport: String) -> String {
        defaultsPrefix + sport.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: Defaults per sport

    private static let strengthSports: Set<String> = [
        "strength", "bodybuilding", "weightlifting", "powerlifting", "crossfit", "calisthenics",
    ]
    private static let climbingSports: Set<String> = [
        "hiking", "skiing", "snowboarding", "snowshoeing", "walking", "nordic walking",
    ]

    /// Running-style sports lead with distance and pace; strength with heart rate and effort.
    static func defaults(sport: String, gps: Bool) -> LiveWorkoutLayout {
        let name = sport.trimmingCharacters(in: .whitespaces).lowercased()
        if gps {
            var fields: [LiveWorkoutField] = [.distance, .currentPace, .averagePace, .heartRate, .zone, .calories]
            if climbingSports.contains(name) { fields.append(.elevation) }
            fields.append(.splits)
            return LiveWorkoutLayout(primary: .time, fields: fields)
        }
        if strengthSports.contains(name) {
            return LiveWorkoutLayout(primary: .time, fields: [.heartRate, .effort, .calories, .averageHeartRate])
        }
        return LiveWorkoutLayout(primary: .time, fields: [.heartRate, .zone, .effort, .calories])
    }

    // MARK: Codec

    func encoded() -> String {
        primary.rawValue + ";" + fields.map(\.rawValue).joined(separator: ",")
    }

    /// Nil for garbage. Route fields are dropped for a sport without GPS, and so are duplicates.
    static func decode(_ raw: String?, gps: Bool) -> LiveWorkoutLayout? {
        guard let raw, let split = raw.firstIndex(of: ";"),
              let primary = LiveWorkoutField(rawValue: String(raw[..<split])),
              primary.canBePrimary, gps || !primary.needsGPS else { return nil }
        var seen = Set<LiveWorkoutField>()
        let fields = raw[raw.index(after: split)...].split(separator: ",").compactMap {
            LiveWorkoutField(rawValue: String($0))
        }.filter { (gps || !$0.needsGPS) && $0 != primary && seen.insert($0).inserted }
        return LiveWorkoutLayout(primary: primary, fields: fields)
    }

    // MARK: Persistence

    static func load(sport: String, gps: Bool, from defaults: UserDefaults = .standard) -> LiveWorkoutLayout {
        decode(defaults.string(forKey: key(sport: sport)), gps: gps) ?? Self.defaults(sport: sport, gps: gps)
    }

    func save(sport: String, to defaults: UserDefaults = .standard) {
        defaults.set(encoded(), forKey: Self.key(sport: sport))
    }

    static func reset(sport: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(sport: sport))
    }

    // MARK: Editing

    /// Switch a grid field on or off, keeping the catalogue order so the grid reads the same every time.
    mutating func toggle(_ field: LiveWorkoutField) {
        guard field != primary else { return }
        if let i = fields.firstIndex(of: field) {
            fields.remove(at: i)
        } else {
            let order = LiveWorkoutField.allCases
            fields.append(field)
            fields.sort { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }
        }
    }

    /// Make `field` the large one; the old primary moves into the grid so nothing silently disappears.
    mutating func setPrimary(_ field: LiveWorkoutField) {
        guard field.canBePrimary, field != primary else { return }
        let old = primary
        primary = field
        fields.removeAll { $0 == field }
        if !fields.contains(old) { toggle(old) }
    }
}
