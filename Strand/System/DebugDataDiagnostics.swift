import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Strap, data-state and analytics-funnel lines appended to the iOS debug export. Best-effort and
/// self-reporting: sections are guarded so a header build never throws, and funnels print the sample
/// counts they read and say plainly when they can't compute.
///
/// - `strapStateLines()`: sync, offline-safe (persisted defaults + timezone); usable from the
///   scheduled background export, which has no `Repository`.
/// - `dynamicLines(repo:)`: async, the full block, for the interactive Save/Share buttons.
enum DebugDataDiagnostics {

    /// Aux rows read for one night's SpO₂-candidate line (a night is ~30k rows at 1 Hz, so this is slack).
    static let spo2CandidateAuxLimit = 200_000



    /// What the active strap actually delivered over the window: which scores can exist at all.
    ///
    /// A 5/MG that never completes its handshake streams only live HR and R-R; motion and steps arrive
    /// only with the proprietary offload, so sleep staging and workout detection have nothing to work on.
    ///
    /// The window is in the label so "motion NO" isn't read as a capability claim for a strap simply not
    /// worn. The label is padded to 13 like the rest of the block and the window rides the value.
    static func strapProvidesLine(hr: Bool, rr: Bool, motion: Bool, steps: Bool,
                                  deviceId: String) -> String {
        func mark(_ b: Bool) -> String { b ? "yes" : "NO" }
        // The device rides the value: this asks ONE id (the active one) while scorers read the union of
        // active, canonical and computed ids, so a re-added strap or import can read as "no heart rate".
        return "Provides:    HR \(mark(hr)) · R-R \(mark(rr)) · motion \(mark(motion)) · steps \(mark(steps))"
            + " (\(deviceId), last 48h)"
    }

    /// The note saying the funnel did NOT analyse the newest night. The funnel walks back to the latest
    /// night carrying skin temperature, so printing that under "latest night" would mislead. Empty when
    /// it took the newest session.
    static func funnelFallbackNote(chosenDay: String, newestDay: String) -> String {
        chosenDay == newestDay ? "" : " (NOT the latest night: \(newestDay) carried no skin temperature)"
    }

    static func strapStateLines() -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Strap & data")
        let d = UserDefaults.standard
        // Parse through `WhoopModel(rawValue:)`: the pref stores the raw value ("WHOOP 4.0"), not the case name.
        let model = WhoopModel(rawValue: d.string(forKey: "selectedWhoopModel") ?? "")?.displayName
            ?? "unknown (never paired)"
        lines.append("Model:       \(model)")
        // Legacy GLOBAL key: the last strap to connect, not this device's firmware. This function is sync
        // and prefs-only by contract (no registry); the Devices block below is resolved per device.
        lines.append("Firmware:    \(d.string(forKey: "zoop.lastFirmware") ?? "unknown (connect to record)")")
        // Legacy GLOBAL key for the same reason; the BLE layer keeps writing it alongside the per-device
        // one. On a multi-strap install it can name the other strap's sync.
        let syncSec = d.double(forKey: "lastSyncedAt")
        lines.append("Last sync:   \(syncSec > 0 ? relTime(Date().timeIntervalSince1970 - syncSec) : "never")")
        // Write health: "Last sync" fires even on an empty/failed offload, so distinguish rows landing from

        // an offload stalled on a persist failure (e.g. backup restored without an app restart).
        let now = Date().timeIntervalSince1970
        let okAt = d.double(forKey: "sync.lastWriteOkAt")
        let stalledAt = d.double(forKey: "sync.lastWriteStalledAt")
        let restoreAt = d.double(forKey: "backup.lastRestoreAt")
        // "Offload:" not "Data write:": the stamp is written only when a backfill persists rows, so it says
        // nothing about live streaming.
        lines.append("Offload:     " + (okAt > 0
            ? "rows last landed \(relTime(now - okAt))"
            : "no history rows ever persisted (live HR/R-R are not counted here)"))
        if stalledAt > 0, stalledAt >= okAt {
            lines.append("             ⚠ history NOT persisting — last offload STALLED \(relTime(now - stalledAt)) "
                + "(if you restored a backup, fully restart the app — #57)")
        }
        if restoreAt > 0 { lines.append("Last restore: \(relTime(now - restoreAt))") }
        #if os(iOS)
        // Widget cost, reported even with no publishes (absence is itself the answer to a drain report).
        // iOS only: `WidgetTelemetry` lives in StrandiOSShared, outside the macOS module.
        lines.append(WidgetTelemetry.snapshot().render())
        #endif
        #if os(iOS)
        // Backup folder-picker health: pins the failure stage ("closed without a folder" means no URL came
        // back; "picked" + FAILED means the bookmark failed here). UIKit calls the same delegate for Cancel
        // and for an Open iOS declines, so the open duration and start location tell them apart.
        let pickEvent = d.string(forKey: "backupPicker.lastEvent") ?? "never used"
        let pickAt = d.double(forKey: "backupPicker.lastEventAt")
        lines.append("Folder picker: \(pickEvent)\(pickAt > 0 ? " (\(relTime(now - pickAt)))" : "")")
        let openFor = d.double(forKey: "backupPicker.lastOpenSeconds")
        if openFor > 0 {
            let startedIn = d.string(forKey: "backupPicker.lastStart") ?? ""
            lines.append("             open for \(String(format: "%.1f", openFor))s"
                + (startedIn.isEmpty ? "" : ", opened on \(startedIn)"))
        }
        if pickEvent == "picked" {
            let scoped = d.bool(forKey: "backupPicker.lastScopedOpen")
            let bmOk = d.bool(forKey: "backupPicker.lastBookmarkOk")
            lines.append("             scoped-access \(scoped ? "ok" : "FAILED"), bookmark \(bmOk ? "ok" : "FAILED")")
        }
        lines.append("Backup mode:  \(FolderBackup.useInternalFolder ? "Zoop's own folder (#52 fallback)" : (FolderBackup.hasFolder ? "external folder" : "none chosen"))")
        #endif
        #if os(macOS)
        // Backup restore-list health: whether a folder is configured and its raw entries are recognized as
        // backups (an undownloaded iCloud placeholder differs from an empty folder).
        if let health = FolderBackup.restoreListHealth() {
            lines.append("Backup folder: \(health.isICloud ? "iCloud Drive" : "local")")
            lines.append("Restore list: \(health.snapshots) snapshot(s) recognized of \(health.rawEntries) folder entries")
        } else {
            lines.append("Backup folder: none chosen")
        }
        #endif
        lines.append("Timezone:    \(tzLine())")
        return lines
    }

    /// The full dynamic block: strap state, data spine, and the REM/skin-temp funnels for the latest
    /// night. Async (reads the on-device store); never throws.
    @MainActor static func dynamicLines(repo: Repository) async -> [String] {
        var lines = strapStateLines()

        // Streams the ACTIVE strap delivered over the last 48 h: EXISTS seeks, not counts (~190k motion
        // rows a night). Here rather than in `strapStateLines()` because that is sync and has no store.
        if let presenceStore = await repo.storeHandle(),
           let present = try? await presenceStore.streamPresence(
               deviceId: repo.deviceId,
               from: Int(Date().timeIntervalSince1970) - 48 * 3600,
               to: Int(Date().timeIntervalSince1970)) {
            lines.append(strapProvidesLine(hr: present.hr, rr: present.rr,
                                           motion: present.gravity, steps: present.steps,
                                           deviceId: repo.deviceId))
        }

        // Data state from the preloaded day spine.
        let days = repo.days
        lines.append("History:     \(days.count) day rows")
        if let s = days.last(where: { ($0.totalSleepMin ?? 0) > 0 }) {
            lines.append("Last sleep:  \(s.day) · \(Int(s.totalSleepMin ?? 0)) min")
        } else { lines.append("Last sleep:  none") }
        if let r = days.last(where: { $0.recovery != nil }) {
            lines.append("Last recov.: \(r.day) · \(Int(r.recovery ?? 0))%")
        } else { lines.append("Last recov.: none") }
        // Name the whole registry set (the header reads last-connected prefs, so a two-strap install never
        // mentioned the second strap). The store handle is hoisted for the clock verdict below, which needs
        // the active strap's identity; a single paired strap is the safe default.
        var clockPeripheralId: String?
        var clockPairedCount = 1
        if let invStore = await repo.storeHandle() {
            let invRegistry = DeviceRegistryStore(dbQueue: invStore.registryWriter)
            // Bound first so the rule below has a count to test.
            let invDevices = (try? invRegistry.all()) ?? []
            let invRows = invDevices.map {
                // Firmware by the Devices-card rule: the device's own value, or the legacy global key only when a
                // single device is paired. Otherwise "unknown" rather than another strap's number.
                InventoryRow(id: $0.id, brand: $0.brand, model: $0.model,
                             status: $0.status.rawValue, lastSeenAt: $0.lastSeenAt,
                             firmware: FirmwareAttribution.resolve(
                                 live: nil,
                                 perDevice: FirmwareAttribution.prefKey(peripheralId: $0.peripheralId)
                                     .flatMap { UserDefaults.standard.string(forKey: $0) },
                                 legacyGlobal: UserDefaults.standard.string(forKey: "zoop.lastFirmware"),
                                 pairedCount: invDevices.count))
            }
            let invActive = (try? invRegistry.activeDeviceId()) ?? nil
            clockPeripheralId = invDevices.first { $0.id == invActive }?.peripheralId
            clockPairedCount = max(1, invDevices.count)
            lines.append(contentsOf: deviceInventoryLines(rows: invRows,
                                                          activeId: invActive,
                                                          nowSec: Int(Date().timeIntervalSince1970),
                                                          relTime: { relTime($0) }))
        }

        // Workout and activity source breakdown; runs before the funnels, which can early-return.
        lines += await workoutSourceLines(repo: repo)
        lines += await dailyDataLines(repo: repo)
        lines += alarmLines(activePeripheralId: clockPeripheralId, pairedCount: clockPairedCount)

        // Funnels for the latest night.
        lines.append(String(repeating: "─", count: 40))
        lines.append("Analytics funnels (latest night, best-effort)")
        let nowSec = Int(Date().timeIntervalSince1970)
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        let did = repo.deviceId
        // Most recent night that carries skin-temp (walk newest to oldest); `.limit(1).last` was the oldest.
        var recent = await repo.sleepSessions(from: nowSec - 14 * 86400, to: nowSec, limit: 200)
        if recent.isEmpty {
            // A Bluetooth-only strap banks nights under the computed "-zoop" source, so fall back to those
            // when the imported read is empty.
            recent = await repo.computedSleepSessions(from: nowSec - 14 * 86400, to: nowSec, limit: 200)
        }
        // `.last`/`.reversed()` below need ASC-by-onset order; the multi-id imported union isn't sorted.
        recent.sort { $0.startTs < $1.startTs }
        guard let newest = recent.last else {
            lines.append("(no sleep session in the last 14 days to analyze)")
            return lines
        }
        var cs = newest
        var skin: [SkinTempSample] = []
        for s in recent.reversed() {
            let sk = (try? await store.skinTempSamples(deviceId: did, from: s.startTs, to: s.endTs, limit: 200_000)) ?? []
            if !sk.isEmpty { cs = s; skin = sk; break }
        }
        let grav = (try? await store.gravitySamples(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        let hr = await repo.hrSamples(from: cs.startTs, to: cs.endTs, limit: 200_000)
        // Beats banked, not scored: the raw read keeps `rr=` comparable with earlier logs (see
        // `rawRrIntervals`).
        let rr = (try? await store.rawRrIntervals(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        let resp = (try? await store.respSamples(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        lines.append("Night \(dayStamp(cs.startTs))"
                     + funnelFallbackNote(chosenDay: dayStamp(cs.startTs),
                                          newestDay: dayStamp(newest.startTs))
                     + ": grav=\(grav.count) hr=\(hr.count) rr=\(rr.count) resp=\(resp.count) skin=\(skin.count)")
        if grav.isEmpty && hr.isEmpty {
            // Don't assert "freshly re-added" untested: several ids can hold one strap's data, so ask the
            // SAMPLE TABLES (not the registry, which is blind to forgotten devices). Only runs when the active
            // id came back empty.
            let elsewhere = ((try? await store.rawSampleCountsByDevice(from: cs.startTs, to: cs.endTs)) ?? [])
                .filter { $0.0 != did }
            // Registry lookup so a second strap's night isn't reported as a read failure.
            let otherStraps = Set(
                ((try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? [])
                    .filter { $0.status != .archived && $0.id != did }
                    .map(\.id))
            lines.append(orphanedSamplesLine(activeId: did, othersWithSamples: elsewhere,
                                             otherLiveStrapIds: otherStraps))
            return lines
        }
        if let rem = SleepStager.remFunnelDiagnostic(start: cs.startTs, end: cs.endTs, grav: grav, hr: hr, rr: rr, resp: resp) {
            // The funnel replays V1 but the shipped hypnogram may be staged by V2: name both so the totals
            // don't read as a disagreement (on a 5/MG V1 lacks the raw resp channel V2 recovers from R-R).
            let screenStager = PuffinExperiment.experimentalSleepV2Enabled ? "V2" : "V1"
            var summary = rem.summary + " · funnel replays V1; screen staged by \(screenStager)"
            if screenStager != "V1" {
                summary += " — totals can differ"
            }
            lines.append(summary)
        } else {
            lines.append("REM funnel: insufficient motion data (<2 gravity samples)")
        }
        let det = SleepSession(start: cs.startTs, end: cs.endTs, efficiency: cs.efficiency ?? 0,
                               stages: [], restingHR: cs.restingHr, avgHRV: cs.avgHrv)
        // Parse through the enum (the pref stores the raw value); unknown resolves to `.whoop4` as an analysis default.
        let family: DeviceFamily =
            WhoopModel(rawValue: UserDefaults.standard.string(forKey: "selectedWhoopModel") ?? "") == .whoop5mg
            ? .whoop5 : .whoop4
        // Learn the device anchor from the whole window's raws so one sparse night can't misreport.
        let windowSkin = (try? await store.skinTempSamples(deviceId: did, from: nowSec - 14 * 86400, to: nowSec, limit: 200_000)) ?? []
        let devAnchor = family == .whoop4 ? Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { $0.raw }) : nil
        lines.append(AnalyticsEngine.skinTempFunnel([det], hr: hr, skinTemp: skin,
                                                    family: family, anchorRaw: devAnchor).summary)

        // The 5/MG SpO2 CANDIDATE (@82) as one number to check against the WHOOP app. Diagnostic only, NOT
        // a blood-oxygen reading. A failed read is not collapsed to `[]`: it is not the same fact as
        // "no candidate".
        let auxRead = try? await store.v18AuxSamples(deviceId: did, from: cs.startTs, to: cs.endTs,
                                                     limit: spo2CandidateAuxLimit)
        if auxRead == nil {
            lines.append("SpO₂ candidate @82: could not read the aux stream for this night — "
                         + "a read failure, NOT an absence of readings.")
        } else if let cand = AnalyticsEngine.nightlySpo2CandidateMean([det], aux: auxRead ?? []) {
            lines.append("SpO₂ candidate @82 (5/MG): mean \(cand.mean) over \(cand.samples) in-band readings "
                         + "— UNVERIFIED, compare against the WHOOP app's figure for this night (#103).")
        } else if family == .whoop5 {
            lines.append("SpO₂ candidate @82 (5/MG): no in-band readings inside this night's span.")
        } else {
            lines.append("SpO₂ candidate @82: not carried by a WHOOP 4.0 (raw red/IR ADC only).")
        }
        return lines
    }

    /// Per-source stored workout counts plus the latest workout, to show where workouts live. Best-effort.
    @MainActor static func workoutSourceLines(repo: Repository) async -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Workouts by source")
        let did = repo.deviceId
        lines.append("Active deviceId: \(did)\(did == "my-whoop" ? "" : "  (imports + spine under my-whoop)")")
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        let nowSec = Int(Date().timeIntervalSince1970)
        var seen = Set<String>()
        let ids = [did, "my-whoop", "\(did)-zoop", "my-whoop-zoop",
                   "activity-file", "lifting", "apple-health", "health-connect"].filter { seen.insert($0).inserted }
        var parts: [String] = []
        var latestTs = -1
        var latestDesc = ""
        for id in ids {
            let rows = (try? await store.workouts(deviceId: id, from: 0, to: nowSec, limit: 100_000)) ?? []
            parts.append("\(id)=\(rows.count)")
            if let m = rows.max(by: { $0.startTs < $1.startTs }), m.startTs > latestTs {
                latestTs = m.startTs
                latestDesc = "\(dayStamp(m.startTs)) · \(m.sport) (\(m.source))"
            }
        }
        lines.append("Stored: " + parts.joined(separator: "  "))
        lines.append(latestTs >= 0 ? "Latest: \(latestDesc)" : "Latest: none")
        return lines
    }

    /// Per-source day counts, populated metrics over the recent week, and the raw-row footprint.
    /// Best-effort.
    @MainActor static func dailyDataLines(repo: Repository) async -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Daily data by source")
        let did = repo.deviceId
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        var seen = Set<String>()
        let ids = [did, "my-whoop", "\(did)-zoop", "my-whoop-zoop",
                   "apple-health", "health-connect"].filter { seen.insert($0).inserted }
        var parts: [String] = []
        var spine: [DailyMetric] = []
        var activeRows: [DailyMetric] = []
        var computedActive: [DailyMetric] = []
        var computedSpine: [DailyMetric] = []
        for id in ids {
            let rows = (try? await store.dailyMetrics(deviceId: id, from: "0000-01-01", to: "9999-12-31")) ?? []
            parts.append("\(id)=\(rows.count)")
            if id == "my-whoop" { spine = rows }
            if id == did { activeRows = rows }
            if id == "\(did)-zoop" { computedActive = rows }
            if id == "my-whoop-zoop" { computedSpine = rows }
        }
        lines.append("Days: " + parts.joined(separator: "  "))
        // Report the active id (where live data lands) AND the import spine when they differ, each stamped
        // with the day range it covers so staleness is visible.
        func recentLine(_ rows: [DailyMetric], id: String) -> String? {
            let recent = Array(rows.suffix(7))
            guard !recent.isEmpty else { return nil }
            let n = recent.count
            let span = (recent.first?.day ?? "?") + "…" + (recent.last?.day ?? "?")
            return "Recent \(n) rows (\(id), \(span)): "
                + "sleep=\(recent.filter { ($0.totalSleepMin ?? 0) > 0 }.count)/\(n)  "
                + "recovery=\(recent.filter { $0.recovery != nil }.count)/\(n)  "
                + "steps=\(recent.filter { $0.steps != nil }.count)/\(n)  "
                + "kcal=\(recent.filter { $0.activeKcalEst != nil }.count)/\(n)"
        }
        var emitted = false
        if let l = recentLine(activeRows, id: did) { lines.append(l); emitted = true }
        if did != "my-whoop", let l = recentLine(spine, id: "my-whoop") { lines.append(l); emitted = true }
        // The COMPUTED "-zoop" spine, where steps/kcal are written: populated here but 0 above means the
        // raw merge drops them; 0 on both means genuinely not computed.
        if let l = recentLine(computedActive, id: "\(did)-zoop") { lines.append(l); emitted = true }
        if did != "my-whoop", let l = recentLine(computedSpine, id: "my-whoop-zoop") { lines.append(l); emitted = true }
        if !emitted {
            lines.append("Recent: no day rows")
        }
        if let dv = await repo.dataVolumeSnapshot() {
            lines.append("Volume: rawRows=\(dv.dbRows)  importedDays=\(dv.importedDays)  workouts=\(dv.workouts)")
        }
        return lines
    }

    /// Alarm state: configured wake plus the last arm's sent-vs-strap-reports. `activePeripheralId` and
    /// `pairedCount` attribute the strap-clock verdict to the active strap; with no identity the legacy
    /// shared reading is trusted only at a single paired strap.
    static func alarmLines(activePeripheralId: String? = nil, pairedCount: Int = 1) -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Alarm")
        let d = UserDefaults.standard
        let on = d.bool(forKey: "behavior.smartAlarmEnabled")
        let mins = (d.object(forKey: "behavior.smartAlarmMinutes") as? Int) ?? 7 * 60
        lines.append("Enabled: \(on ? "yes" : "no") · set \(String(format: "%02d:%02d", mins / 60, mins % 60))")
        // Model and the 5/MG gate: parse through the enum and abstain when nothing is known.
        switch WhoopModel(rawValue: d.string(forKey: "selectedWhoopModel") ?? "") {
        case .whoop5mg:
            // Name the switch a reader can actually find.
            lines.append("Model: \(WhoopModel.whoop5mg.displayName) · Protocol probes (Test Centre): "
                         + (PuffinExperiment.isEnabled ? "on" : "off → firmware alarm NOT armed"))
        case .whoop4:
            lines.append("Model: \(WhoopModel.whoop4.displayName)")
        case nil:
            lines.append("Model: unknown (family not yet detected)")
        }
        // Strap clock health: a stale or future-dated clock breaks the alarm and misdates offloaded sleep.
        // Attributed to THIS strap: the global key holds whichever strap last answered a range reply.
        let attributedNewest = LastSyncAttribution.resolveStrapClockTs(
            perDevice: LastSyncAttribution.strapClockPrefKey(peripheralId: activePeripheralId)
                .flatMap { d.object(forKey: $0) as? Int },
            legacyGlobal: d.object(forKey: "strap.newestRecordTs") as? Int,
            pairedCount: pairedCount)
        if attributedNewest == nil, pairedCount > 1 {
            // Say why there is no verdict rather than imply the clock was checked.
            lines.append("Strap clock: not known for this strap (no range reply recorded against it; the "
                         + "legacy shared reading is not attributable with \(pairedCount) straps paired)")
        }
        if let newest = attributedNewest, newest > 0 {
            let behind = Int(Date().timeIntervalSince1970) - newest
            if behind > 3 * 86400 {
                lines.append("Strap clock: \(behind / 86400)d behind wall (reset/stale — alarm unreliable; recent sleep may be filed ~\(behind / 86400)d in the past, #67)")
            } else if behind < -3 * 86400 {
                lines.append("Strap clock: \(-behind / 86400)d AHEAD of wall (future-dated — alarm unreliable; recent sleep may be misdated, #67)")
            } else {
                // Reads RECORD timestamps, which can look like a contradiction beside an alarm readback.
                lines.append("Strap clock: OK (from record timestamps, not the alarm readback)")
            }
        }
        if let sent = d.object(forKey: "alarm.lastArmSentEpoch") as? Int {
            // "for <alarm time> · sent <ago>": the stamp is the future instant armed, the relative time is when it was sent.
            var line = "Last arm: for \(alarmStamp(sent))"
            let armedAt = d.object(forKey: "alarm.lastArmAt") as? Double
            if let armedAt {
                line += " · sent \(relTime(Date().timeIntervalSince1970 - armedAt))"
            }
            if !d.bool(forKey: "alarm.lastArmConnected") { line += " · strap NOT connected (queued)" }
            // Strap-clock skew at arm: skew ~0 but still rejected points at a corrupted alarm register.
            if let skew = d.object(forKey: "alarm.lastArmClockSkew") as? Int, abs(skew) > 3600 {
                let mag = abs(skew) >= 86400 ? "\(skew / 86400)d" : "\(skew / 3600)h"
                line += " · strap clock at arm \(skew > 0 ? "+" : "")\(mag)"
            }
            // Live HR at arm, to test whether the strap's own sleep detection gates the haptic (see `recordAlarmArm`).
            if let hr = d.object(forKey: "alarm.lastArmHeartRate") as? Int {
                line += " · HR \(hr) bpm at arm"
            }
            lines.append(line)
            if let reported = d.object(forKey: "alarm.lastReportedEpoch") as? Int {
                // Judge only when both halves are the same strap and the readback answered this arm (a failed
                // decode leaves the previous readback standing).
                let readAt = d.object(forKey: "alarm.lastReportedAt") as? Double
                let verdict = AlarmReadback.verdict(
                    sentEpoch: sent,
                    reportedEpoch: reported,
                    sentDeviceId: d.string(forKey: "alarm.lastArmDeviceId"),
                    reportedDeviceId: d.string(forKey: "alarm.lastReportedDeviceId"),
                    sentAt: armedAt,
                    reportedAt: readAt)
                var rline = "Strap reports: \(alarmStamp(reported))" + AlarmReadback.suffix(verdict)
                // When the readback landed, for provenance.
                if let readAt { rline += " · read \(relTime(Date().timeIntervalSince1970 - readAt))" }
                // Consecutive rejections point at an alarm register needing a reset (SmartAlarmView warns at 2+).
                let streak = d.integer(forKey: "alarm.rejectStreak")
                if streak >= 2 { rline += " · \(streak) in a row (register likely needs a reset, #34)" }
                lines.append(rline)
                // The bytes the epoch was decoded from; older readbacks have no frame, so say which case it is.
                // Blank counts as not stored.
                let reportedRaw = d.string(forKey: "alarm.lastReportedRaw")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let reportedRaw, !reportedRaw.isEmpty {
                    lines.append("Readback frame: \(reportedRaw)")
                } else {
                    lines.append("Readback frame: not stored (this readback predates the frame capture, or "
                        + "the write failed), so a genuinely-stored stale alarm cannot be told from a "
                        + "misdecode of a fixed response field here")
                }
            } else {
                lines.append("Strap reports: (no readback)")
            }
        } else {
            lines.append("Last arm: never")
        }
        // Did the strap actually fire?
        if let firedAt = d.object(forKey: "alarm.lastFiredAt") as? Double {
            lines.append("Last fired: \(relTime(Date().timeIntervalSince1970 - firedAt))")
        } else {
            lines.append("Last fired: never observed")
        }
        return lines
    }

    private static func alarmStamp(_ epochSec: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }

    // MARK: - Formatting helpers

    private static func relTime(_ deltaSec: Double) -> String {
        if deltaSec < 60 { return "just now" }
        let min = Int(deltaSec / 60)
        switch true {
        case min < 60:   return "\(min)m ago"
        case min < 1440: return "\(min / 60)h \(min % 60)m ago"
        default:         return "\(min / 1440)d ago"
        }
    }

    private static func tzLine() -> String {
        let tz = TimeZone.current
        let offMin = tz.secondsFromGMT() / 60
        let a = abs(offMin)
        return "\(tz.identifier) (UTC\(offMin >= 0 ? "+" : "-")\(a / 60):\(String(format: "%02d", a % 60)))"
    }

    private static func dayStamp(_ epochSec: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }

    /// The line the night funnel prints when the ACTIVE device id carries no raw samples.
    ///
    /// `othersWithSamples` is (deviceId, sampleCount) for other registry ids holding samples in the
    /// window; empty means the samples genuinely aren't there. `otherLiveStrapIds` are the registered,
    /// non-archived ids other than the active one: samples under those are normal for a two-strap wearer
    /// (`DayOwnerResolver`), so the line states the fork instead of picking a side. Pure and unit-tested.
    static func orphanedSamplesLine(activeId: String, othersWithSamples: [(String, Int)],
                                    otherLiveStrapIds: Set<String> = []) -> String {
        if othersWithSamples.isEmpty {
            return "(no raw biometric samples under '\(activeId)' for this night — expected on a freshly "
                + "re-added strap; reconnect + let a history sync run, then re-export)"
        }
        let ownedByAnotherStrap = othersWithSamples.filter { otherLiveStrapIds.contains($0.0) }
        if !ownedByAnotherStrap.isEmpty {
            let who = ownedByAnotherStrap.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .map { "'\($0.0)' (\($0.1) rows)" }
                .joined(separator: ", ")
            return "(no raw biometric samples under the ACTIVE id '\(activeId)' for this night — they are "
                + "under \(who), another registered strap. If you wore THAT strap this night, this is expected "
                + "and the dayOwner line for this date names the owner. If you wore BOTH, the active strap "
                + "banked nothing for this night and its sync is what to check, not this line.)"
        }
        // Tie-break on id: Swift's `sorted` isn't stable, so equal counts could order differently from Kotlin.
        let named = othersWithSamples.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map { "'\($0.0)' (\($0.1) rows)" }
            .joined(separator: ", ")
        return "(no raw biometric samples under the ACTIVE id '\(activeId)' for this night — they are under "
            + "\(named) instead. The history spine and the raw stream are on different device ids (#1193); this "
            + "is NOT a fresh re-add, the samples exist and are not being read.)"
    }
}
