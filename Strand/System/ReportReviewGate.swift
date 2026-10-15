import Foundation

/// The mandatory review-before-share gate: nothing leaves the device until the user has seen the exact
/// redacted report they are about to share and explicitly confirmed. Not skippable; the only path to
/// cleared is `confirm()`. A value type so the logic is unit-tested; the review sheet binds to
/// `previewText`.
struct ReportReviewGate {
    /// The bundle the user is about to share, already redacted by TestBundleAssembler.
    let entries: [FileExport.BundleEntry]
    private(set) var isCleared: Bool = false

    init(entries: [FileExport.BundleEntry]) { self.entries = entries }

    /// Bundle files never shown inline by name: the screenshot and the large raw research streams
    /// (already PII-scrubbed, each up to the 25 MB `OuraActivityDump.maxBytes` / `OuraMotionDump.maxBytes`
    /// cap). Laying megabytes out as one SwiftUI `Text` pins the main thread in CoreText; they are named in
    /// the "attached" note instead.
    static let notShownInline: Set<String> = [
        "screenshot.png", "raw-capture.jsonl", "oura-raw.jsonl", "oura-ibihr.jsonl", "oura-activity.jsonl",
    ]

    /// Size guard: any entry larger than this is named, never inlined, even if not in `notShownInline`.
    /// 1 MiB sits above a normal report.txt / meta.json yet below the layout-choke point.
    static let maxInlineBytes = 1024 * 1024

    /// Every text file the user is about to share (report.txt, meta.json, last-crash.txt), each under a
    /// `=== <name> ===` header, in bundle order. Streams excluded by name or over `maxInlineBytes` are
    /// listed by name instead. Empty if nothing is text-decodable.
    var previewText: String {
        let textBlocks = entries.compactMap { entry -> String? in
            guard !Self.notShownInline.contains(entry.name), entry.data.count <= Self.maxInlineBytes,
                  let text = String(data: entry.data, encoding: .utf8) else { return nil }
            return "=== \(entry.name) ===\n\(text)"
        }.joined(separator: "\n\n")
        // Name binary / large attachments so the review is honest about everything in the bundle.
        let binaryNames = entries.compactMap { entry -> String? in
            if Self.notShownInline.contains(entry.name) || entry.data.count > Self.maxInlineBytes { return entry.name }
            return String(data: entry.data, encoding: .utf8) == nil ? entry.name : nil
        }
        guard !binaryNames.isEmpty else { return textBlocks }
        let note = "=== attached (not shown above) ===\n" + binaryNames.joined(separator: "\n")
        return textBlocks.isEmpty ? note : textBlocks + "\n\n" + note
    }

    /// Explicit confirmation: the only way the gate clears.
    mutating func confirm() { isCleared = true }
    /// Explicit cancel: leaves the gate uncleared.
    mutating func cancel() { isCleared = false }
}
