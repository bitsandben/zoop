import Foundation
import SwiftUI
import StrandAnalytics

/// The Report action behind every Test Centre Report button: assembles the redacted, capped bundle,
/// presents the mandatory review sheet bound to the exact report.txt, and only on explicit confirm
/// hands the bundle to TestReportFlow.run. An ObservableObject so the screen presents the sheet off
/// `pending`.
@MainActor
final class TestCentreReport: ObservableObject {

    /// A report pending the user's review; the screen shows a sheet bound to `gate.previewText`.
    struct Pending: Identifiable {
        let id = UUID()
        let profile: TestDomain
        let title: String
        var gate: ReportReviewGate
        /// True when the profile's test mode is NOT on at report time, so the bundle carries no capture for
        /// what is being reported; the review sheet warns (capture_check only grades ACTIVE domains). Always
        /// false for the master profile.
        var modeInactive: Bool = false
    }

    /// Non-nil while a report is awaiting review; drive a `.sheet(item:)` off this.
    @Published var pending: Pending?

    /// A one-line status banner shown after a share fires.
    @Published var lastStatus: String?

    /// The redacted report.txt for the iOS "Copy report.txt" fallback, set after a confirmed share on the
    /// mobile path; nil on macOS or when there is nothing to copy.
    @Published var copyableReport: String?

    /// Builds the redacted bundle for `mode` and stages it for review; nothing leaves the device. Async
    /// because the storage probe reads the store actor. `repo` nil (tests/previews) skips the store read
    /// and meta keeps the zeroed block.
    func start(mode: TestMode, live: LiveState, repo: Repository? = nil) {
        Task { @MainActor [weak self] in
            let storage = await TestCentreReport.storageProbe(repo: repo, live: live)
            // The model BLEManager persisted on the last connect; nil before any strap linked. Read, never guessed.
            let model = UserDefaults.standard.string(forKey: "selectedWhoopModel")
            let entries = TestBundleAssembler.assemble(profile: mode.domain, live: live,
                                                       storage: storage, strapModel: model)
            self?.pending = Pending(profile: mode.domain, title: mode.title,
                                    gate: ReportReviewGate(entries: entries),
                                    modeInactive: mode.domain != .master && !TestCentre.active(mode.domain))
        }
    }

    /// The real storage probe behind meta.json's storage block.
    /// - db_bytes: on-disk footprint (whoop.sqlite + -wal/-shm).
    /// - rows: per-table row counts via the store.
    /// - raw_capture_bytes: banked rawBatch bytes plus the raw-capture .jsonl when the recorder is on.
    /// Returns nil when nothing was readable, so the zeroed fallback stays an honest "unreadable".
    static func storageProbe(repo: Repository?, live: LiveState) async -> TestBundleMeta.Storage? {
        let fm = FileManager.default
        var dbBytes = 0
        if let path = try? StorePaths.defaultDatabasePath() {
            for suffix in ["", "-wal", "-shm"] {
                dbBytes += (try? fm.attributesOfItem(atPath: path + suffix))?[.size] as? Int ?? 0
            }
        }
        var rows: [String: Int] = [:]
        var rowBytes: [String: Int] = [:]
        var rawBytes = 0
        if let store = await repo?.storeHandle() {
            // Every accumulating table, including the blob tables (ppgHr, sleepState, ppgWaveform, v18Aux) that
            // a footprint must not omit.
            if let counts = try? await store.storageRowCounts() { rows = counts }
            // Bytes beside the counts (sampled payload estimate, lower bound vs db_bytes).
            if let bytes = try? await store.storageByteEstimates(rowCounts: rows) { rowBytes = bytes }
            // `rawOutboxStats`, not `storageStats`: the latter full-scans every decoded table for a total unused here.
            rawBytes = (try? await store.rawOutboxStats().bytes) ?? 0
        }
        if let url = live.puffinCaptureURL {
            rawBytes += (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        }
        guard dbBytes > 0 || !rows.isEmpty || rawBytes > 0 else { return nil }
        return TestBundleMeta.Storage(dbBytes: dbBytes, rows: rows, rawCaptureBytes: rawBytes,
                                      rowBytes: rowBytes)
    }

    /// The user confirmed the review: clears the gate and runs the share flow.
    func confirm() {
        guard var p = pending else { return }
        p.gate.confirm()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        // Launched as a Task: TestReportFlow.run awaits the off-main zip build.
        Task {
            await TestReportFlow.run(
                profile: p.profile, title: p.title,
                version: version, platform: platform, osVersion: osVersion,
                gate: p.gate,
                entries: p.gate.entries,
                showToast: { [weak self] msg in self?.lastStatus = msg },
                // Prime the clipboard and surface the report for a visible "Copy report.txt" button.
                copyToPasteboard: { [weak self] text in PlatformPasteboard.copy(text); self?.copyableReport = text })
        }
        pending = nil
    }

    /// The user cancelled the review: nothing is shared.
    func cancel() { pending = nil }
}
