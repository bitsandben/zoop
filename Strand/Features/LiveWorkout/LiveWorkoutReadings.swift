import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol

// MARK: - Live workout readings
//
// Every value the live workout screen draws, resolved once per tick from one snapshot: one clock, one
// heart rate, one route series. Views lay these out and never format numbers themselves. A field with
// nothing to show carries the reason (no signal, searching GPS, not moving) instead of a dash.

/// The live route's state for this session.
enum LiveGPSState: Equatable {
    /// The sport records no route.
    case off
    case waiting
    case live
    case denied
    case askPending
    case unavailable
}

struct LiveFieldReading: Equatable {
    /// The number, or nil when `reason` says why there is none.
    var value: String?
    var unit: String?
    var caption: String?
    var reason: String?
    var tint: Color?
}

struct LiveWorkoutReadings {
    let elapsed: TimeInterval
    let bpm: Int?
    let workout: AppModel.ActiveWorkout
    let zoneSet: HRZoneSet
    let effortScale: EffortScale
    let calories: Double?
    let samples: [WorkoutSplits.Sample]
    let elevationGainM: Double?
    let distanceSystem: UnitSystem
    let gps: LiveGPSState

    var unitMeters: Double { distanceSystem == .imperial ? WorkoutSplits.mile : WorkoutSplits.kilometer }
    private var distanceUnit: String { UnitFormatter.distanceUnit(distanceSystem) }
    private var paceUnit: String { "/" + distanceUnit }
    var distanceM: Double { samples.last?.meters ?? 0 }

    var splits: [WorkoutSplits.Split] { WorkoutSplits.splits(samples, splitMeters: unitMeters) }
    var currentSplit: (meters: Double, seconds: Double)? { WorkoutSplits.currentSplit(samples, splitMeters: unitMeters) }

    var zone: Int { bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }
    var zoneTint: Color { zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.textPrimary }

    func reading(_ field: LiveWorkoutField) -> LiveFieldReading {
        switch field {
        case .time:
            return LiveFieldReading(value: ActiveWorkoutClock.clock(Int(elapsed)))
        case .heartRate:
            guard let bpm else { return LiveFieldReading(reason: LiveWorkoutStrings.noSignal) }
            return LiveFieldReading(value: "\(bpm)", unit: "bpm", tint: zoneTint)
        case .zone:
            guard bpm != nil else { return LiveFieldReading(reason: LiveWorkoutStrings.noSignal) }
            guard zone >= 1 else { return LiveFieldReading(value: LiveWorkoutStrings.belowZone1) }
            return LiveFieldReading(value: LiveWorkoutStrings.zone(zone), caption: Self.zoneName(zone), tint: zoneTint)
        case .averageHeartRate:
            guard workout.avgHr > 0 else { return LiveFieldReading(reason: LiveWorkoutStrings.noSignal) }
            return LiveFieldReading(value: "\(workout.avgHr)", unit: "bpm")
        case .calories:
            guard let calories, calories > 0 else { return LiveFieldReading(reason: LiveWorkoutStrings.needsHeartRate) }
            return LiveFieldReading(value: ZoopNumber.decimal(calories, digits: 0), unit: "kcal")
        case .effort:
            let stored = workout.liveStrain
            let fraction = min(max(stored / 100, 0), 1)
            return LiveFieldReading(value: UnitFormatter.effortDisplay(stored, scale: effortScale),
                                    caption: StrainGauge.stateLabel(forFraction: fraction),
                                    tint: StrandPalette.effortColor)
        case .distance:
            if let reason = routeReason { return LiveFieldReading(reason: reason) }
            let units = distanceM / unitMeters
            return LiveFieldReading(value: ZoopNumber.decimal(units, digits: 2), unit: distanceUnit)
        case .currentPace:
            if let reason = routeReason { return LiveFieldReading(reason: reason) }
            guard let pace = WorkoutSplits.currentPace(samples, now: elapsed, unitMeters: unitMeters),
                  let text = WorkoutSplits.clock(pace) else { return LiveFieldReading(reason: LiveWorkoutStrings.notMoving) }
            return LiveFieldReading(value: text, unit: paceUnit)
        case .averagePace:
            if let reason = routeReason { return LiveFieldReading(reason: reason) }
            guard let pace = WorkoutSplits.averagePace(meters: distanceM, seconds: elapsed, unitMeters: unitMeters),
                  let text = WorkoutSplits.clock(pace) else { return LiveFieldReading(reason: LiveWorkoutStrings.needsDistance) }
            return LiveFieldReading(value: text, unit: paceUnit)
        case .elevation:
            if let reason = routeReason { return LiveFieldReading(reason: reason) }
            guard let gain = elevationGainM else { return LiveFieldReading(reason: LiveWorkoutStrings.waitingAltitude) }
            let value = distanceSystem == .imperial ? gain * 3.28084 : gain
            return LiveFieldReading(value: ZoopNumber.decimal(value, digits: 0), unit: distanceSystem == .imperial ? "ft" : "m")
        case .splits:
            return LiveFieldReading(value: "\(splits.count)")
        }
    }

    /// Why a route field has no number yet, or nil when the route is live and has a fix.
    private var routeReason: String? {
        switch gps {
        case .live: return samples.isEmpty ? LiveWorkoutStrings.searchingGPS : nil
        case .waiting, .askPending: return LiveWorkoutStrings.searchingGPS
        case .denied, .unavailable, .off: return LiveWorkoutStrings.gpsUnavailableShort
        }
    }

    /// One split's pace as text, in the split unit.
    func paceText(_ seconds: Double) -> String { (WorkoutSplits.clock(seconds) ?? "") + " " + paceUnit }

    func splitTitle(_ index: Int) -> String {
        distanceSystem == .imperial ? LiveWorkoutStrings.mile(index) : LiveWorkoutStrings.kilometer(index)
    }

    static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
    }
}

// MARK: - Live calories

extension AppModel {
    /// Calories so far from the captured heart-rate window, the same model the saved row uses on End.
    /// Nil until there are two samples. Display-only: the saved row is still estimated once, on End.
    func liveWorkoutCalories(_ w: ActiveWorkout) -> Double? {
        guard w.samples.count >= 2 else { return nil }
        let restingHR = repo.today?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let user = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                               age: Double(profile.age), sex: profile.sex)
        let kcal = Calories.estimateBoutCalories(w.samples, profile: user, hrmax: Double(profile.hrMax),
                                                 restingHR: restingHR).0
        return kcal.isFinite ? kcal : nil
    }

    /// The GPS state the live screen explains, from the recorder's permission and fixes.
    var liveGPSState: LiveGPSState {
        guard activeWorkoutIsGps else { return .off }
        switch gpsRecorder.access {
        case .denied: return .denied
        case .unavailable: return .unavailable
        case .notDetermined: return .askPending
        case .authorized: return gpsRecorder.pointCount > 0 ? .live : .waiting
        }
    }
}
