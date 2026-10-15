import Foundation
import StrandAnalytics

/// Drives the in-app "Share" action: saves the redacted .zip and hands it to the share sheet. The
/// decision logic lives in `Plan` (pure, unit-tested); `run` performs the side effects. The bundle
/// arrives already redacted and capped (meta.redaction="v2"); this flow never re-scrubs. The app
/// takes nothing off the device and names no destination; filing an issue is the reporter's step.
enum TestReportFlow {

    /// Pure decisions, no side effects.
    enum Plan {
        /// zoop-<profile>-<platform>-v<version>-<yyMMdd-HHmm>.zip, via FileExport.bundleName.
        static func bundleName(profile: TestDomain, platform: String, version: String,
                               date: Date = Date()) -> String {
            FileExport.bundleName(profile: profile.id, platform: platform, version: version, date: date)
        }

        /// The toast shown after the share sheet, naming the exact saved file.
        static func attachToast(savedName: String) -> String {
            "Saved as \(savedName). Attach it to your bug report."
        }

        /// iOS also offers "Copy report.txt" because mobile share sheets make a .zip awkward to paste into a
        /// web form; macOS drag-drop works, so the fallback is mobile-only.
        static func offersCopyFallback(platform: String) -> Bool {
            platform.lowercased() == "ios"
        }
    }

    /// The review gate is mandatory: the flow only proceeds once the user has confirmed.
    static func shouldProceed(gate: ReportReviewGate) -> Bool { gate.isCleared }

    /// Saves/shares the already-redacted bundle, then toasts. `showToast` and `copyToPasteboard` are
    /// injected platform presenters. Nothing is shared and no toast shown until the review gate is
    /// cleared. Async because `FileExport.exportBundle` stages its zip off the main actor.
    @MainActor
    static func run(profile: TestDomain, title: String,
                    version: String, platform: String, osVersion: String,
                    gate: ReportReviewGate,
                    entries: [FileExport.BundleEntry],
                    showToast: @escaping (String) -> Void,
                    copyToPasteboard: @escaping (String) -> Void) async {
        // Review-before-share is mandatory.
        guard shouldProceed(gate: gate) else { return }
        let name = Plan.bundleName(profile: profile, platform: platform, version: version)
        // Share the .zip and stop; the destination is whatever the user picks in the sheet.
        _ = await FileExport.exportBundle(entries: entries, suggestedName: name)
        showToast(Plan.attachToast(savedName: name))
        if Plan.offersCopyFallback(platform: platform),
           let report = entries.first(where: { $0.name == "report.txt" }),
           let text = String(data: report.data, encoding: .utf8) {
            // Prime the pasteboard closure; the UI exposes a "Copy report.txt" button bound to the same text.
            copyToPasteboard(text)
        }
    }
}
