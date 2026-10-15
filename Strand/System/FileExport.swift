import Foundation
import ZIPFoundation

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Cross-platform "save / share a file" helper: `NSSavePanel` on macOS, the system share sheet on iOS.
enum FileExport {

    /// A `yyMMdd-HHmm` wall-clock stamp (POSIX locale) for sortable, non-colliding export filenames.
    static func timestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd-HHmm"
        return f.string(from: date)
    }

    /// A timestamped suggested filename: `<prefix>-<yyMMdd-HHmm>.<ext>`.
    static func timestampedName(_ prefix: String, ext: String) -> String {
        "\(prefix)-\(timestamp()).\(ext)"
    }

    /// Profile-tagged bundle filename: `zoop-<profile>-<platform>-v<version>-<yyMMdd-HHmm>.zip`.
    static func bundleName(profile: String, platform: String, version: String, date: Date = Date()) -> String {
        "noop-\(profile)-\(platform)-v\(version)-\(timestamp(date)).zip"
    }

    /// Write `text` to a file and let the user choose where it goes.
    @MainActor
    static func exportText(_ text: String, suggestedName: String) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        #else
        // Write to a temp file first and present the share sheet only if it exists; the temp file is
        // cleaned up when the sheet closes.
        let url = ZoopScratch.file(suggestedName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        present(activityItems: [url], cleanup: [url])
        #endif
    }

    /// Lets the user save / share an existing file. `src` is owned by the caller and is NOT deleted by
    /// the share-sheet completion; only files we staged ourselves are cleaned up.
    @MainActor
    static func exportFile(at src: URL, suggestedName: String? = nil) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? src.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        } catch { /* best-effort */ }
        #else
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        present(activityItems: [src], cleanup: [])
        #endif
    }

    #if os(iOS)
    /// Presents `UIActivityViewController`, then best-effort removes `cleanup` URLs once it closes.
    @MainActor
    private static func present(activityItems: [Any], cleanup: [URL], completion: (() -> Void)? = nil) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) ?? UIApplication.shared
                .connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else { completion?(); return }
        // Present from the top-most controller: when the caller is inside a SwiftUI sheet, `root.present`
        // is a no-op (#455).
        var presenter = root
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        if !cleanup.isEmpty || completion != nil {
            // Fires after the sheet is dismissed (saved or cancelled): clean up staged files, then run `completion`.
            vc.completionWithItemsHandler = { _, _, _, _ in
                let fm = FileManager.default
                for url in cleanup where fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
                completion?()
            }
        }
        // iPad: anchor the popover to the screen centre to avoid a crash.
        if let pop = vc.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(vc, animated: true)
    }
    #endif

    // MARK: - Bundle export (Test Centre)

    /// A file destined for the zip bundle: in-zip name plus bytes. Every entry must already be redacted
    /// by the caller.
    struct BundleEntry: Equatable { let name: String; let data: Data }

    /// Zips `entries` into one staged `.zip` under the temp directory and returns its URL (nil if no
    /// entries). Pure file IO, unit-testable; the caller presents and cleans up the URL.
    static func zipData(entries: [BundleEntry], baseName: String) -> URL? {
        guard !entries.isEmpty else { return nil }
        let url = ZoopScratch.file("\(baseName).zip")
        try? FileManager.default.removeItem(at: url)
        guard let archive = try? Archive(url: url, accessMode: .create) else { return nil }
        for entry in entries {
            try? archive.addEntry(with: entry.name, type: .file, uncompressedSize: Int64(entry.data.count)) { position, size in
                let start = Int(position)
                let end = min(start + size, entry.data.count)
                return entry.data.subdata(in: start..<end)
            }
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Zips `entries` and hands the result to the user. Every entry must already be redacted and within
    /// the assembler's size cap. Zipping runs off the main actor (#646/#651); only presentation hops
    /// back. Returns the staged / saved URL, nil on cancel or failure.
    @MainActor @discardableResult
    static func exportBundle(entries: [BundleEntry], suggestedName: String,
                             completion: (() -> Void)? = nil) async -> URL? {
        let base = suggestedName.hasSuffix(".zip") ? String(suggestedName.dropLast(4)) : suggestedName
        let stagingTask = Task.detached(priority: .userInitiated) {
            zipData(entries: entries, baseName: base)
        }
        guard let staged = await stagingTask.value else { completion?(); return nil }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else {
            try? FileManager.default.removeItem(at: staged)
            return nil
        }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: staged, to: dest)
        } catch {
            try? fm.removeItem(at: staged)
            return nil
        }
        try? fm.removeItem(at: staged)
        return dest
        #else
        present(activityItems: [staged], cleanup: [staged], completion: completion)
        return staged
        #endif
    }
}
