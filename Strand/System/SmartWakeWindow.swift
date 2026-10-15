import Foundation
import StrandAnalytics

/// Experimental smart-wake window: wake the wearer in light sleep within the last few minutes before
/// the alarm. The strap alarm stays armed at the latest time all night, so if the app is suspended
/// or nothing is detected it rings as a plain alarm. Inside the window it syncs every few minutes and
/// asks `SmartWake.lightSleepSignal`; on a yes it re-arms the same alarm a minute from now, only
/// earlier and once per alarm. Default off; unvalidated on hardware.
@MainActor
final class SmartWakeWindow {
    static let windowKey = "zoop.smartWake.windowMinutes"
    static let choices = [0, 15, 30, 45]

    /// Window length in minutes; 0 = off.
    static var windowMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: windowKey)
        return choices.contains(v) ? v : 0
    }

    /// Check interval, and how long to wait for a sync before reading.
    static let checkInterval: TimeInterval = 3 * 60
    static let syncSettle: TimeInterval = 75

    private weak var model: AppModel?
    private var timer: Timer?
    private var alarm: Date?
    /// The earlier wake already armed for `alarm`, so re-arming the plain alarm keeps it.
    private(set) var earlyWake: Date?

    init(model: AppModel) { self.model = model }

    /// Follows the next alarm: starts checking when its window opens, stops when there is none.
    func plan(nextAlarm: Date?) {
        timer?.invalidate()
        timer = nil
        if nextAlarm != alarm { earlyWake = nil }
        alarm = nextAlarm
        guard let alarm, Self.windowMinutes > 0, earlyWake == nil else { return }
        let start = alarm.addingTimeInterval(-Double(Self.windowMinutes * 60))
        let delay = max(1, start.timeIntervalSinceNow)
        guard alarm.timeIntervalSinceNow > 120 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// The alarm time to arm: the early wake once chosen, else the plain alarm.
    func effectiveAlarm(for planned: Date) -> Date {
        if let e = earlyWake, planned == alarm, e < planned, e.timeIntervalSinceNow > -60 { return e }
        return planned
    }

    private func check() {
        guard let model, let alarm, earlyWake == nil else { return }
        // Too close to the alarm for an earlier buzz to matter: let it ring.
        guard alarm.timeIntervalSinceNow > 120 else { return }
        model.ble.requestSync(.manual)
        timer = Timer.scheduledTimer(withTimeInterval: Self.syncSettle, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
    }

    private func evaluate() async {
        guard let model, let alarm, earlyWake == nil else { return }
        let now = Int(Date().timeIntervalSince1970)
        let hr = await model.repo.hrSamples(from: now - 1800, to: now, limit: 20_000)
        let gravity = await model.repo.gravitySamplesUnion(from: now - 600, to: now, limit: 20_000)
        if let signal = SmartWake.lightSleepSignal(hr: hr, gravity: gravity, now: now),
           alarm.timeIntervalSinceNow > 120 {
            let wake = Date().addingTimeInterval(30)
            earlyWake = wake
            model.live.append(log: AppModel.stamped("Smart wake: \(signal.rawValue) inside the window, alarm moved to now"))
            model.ble.armStrapAlarm(at: wake)
            return
        }
        // Nothing yet: look again, as long as the alarm is still far enough off.
        let next = Date().addingTimeInterval(Self.checkInterval - Self.syncSettle)
        guard alarm.timeIntervalSince(next) > 120 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval - Self.syncSettle, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }
}
