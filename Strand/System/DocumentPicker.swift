#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Async wrappers around `UIDocumentPickerViewController` for database backup import/export on iOS.
/// Each call presents the picker and resumes with the chosen URL (nil if cancelled).
enum DocumentPicker {

    /// Presents the picker to export `url`; returns the destination URL, or nil if cancelled.
    @MainActor
    static func export(_ url: URL) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = coordinator
            return picker
        }
    }

    /// Presents the picker for a file of one of `types`; `asCopy` yields a readable sandbox copy.
    @MainActor
    static func importFile(_ types: [UTType]) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            return picker
        }
    }

    /// Presents a folder picker (Backup & Sync); returns the chosen folder, or nil.
    ///
    /// Built for opening `.folder` with `asCopy: false` so the directory itself is selectable (the bare
    /// form left "Open" greyed out on some iOS builds, #859). The URL is security-scoped; the caller
    /// bookmarks it (`FolderBackup.saveFolder`). `startingAt` is a hint (last-used folder, else Documents)
    /// that may not fully fix the dead button, so `BackupSyncView` also surfaces an empty result.
    @MainActor
    static func pickFolder(startingAt root: URL? = nil) async -> URL? {
        await present { coordinator in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            picker.directoryURL = root
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            return picker
        }
    }

    // MARK: - Presentation plumbing

    @MainActor
    private static func present(_ make: (Coordinator) -> UIDocumentPickerViewController) async -> URL? {
        guard let root = topViewController() else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let coordinator = Coordinator(continuation: continuation)
            let picker = make(coordinator)
            // Keep the coordinator alive for the lifetime of the picker.
            objc_setAssociatedObject(picker, &Coordinator.assocKey, coordinator, .OBJC_ASSOCIATION_RETAIN)
            // The continuation resumes only from a delegate callback, but UIKit can silently decline a
            // presentation mid-transition, which would hang `BackupSyncView.busy`. Detect a picker that never
            // reached a window and resume nil; `finish` is resume-once.
            root.present(picker, animated: true) {
                if picker.view.window == nil && picker.presentingViewController == nil {
                    DocumentPicker.recordEvent("not-presented", url: nil)
                    coordinator.finish(nil)
                }
            }
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        static var assocKey = 0
        private let continuation: CheckedContinuation<URL?, Never>
        private var resumed = false
        /// When the sheet went up, to report how long it was open.
        private let presentedAt = Date()

        init(continuation: CheckedContinuation<URL?, Never>) {
            self.continuation = continuation
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            DocumentPicker.recordEvent(urls.isEmpty ? "picked-empty" : "picked", url: urls.first,
                                       openSeconds: Date().timeIntervalSince(presentedAt),
                                       startedIn: BackupPickerStart.category(controller.directoryURL))
            finish(urls.first)
        }

        /// UIKit calls this for Cancel AND for an Open that iOS declines, so don't report "cancelled". Record
        /// that the sheet closed with no URL, plus how long it was open and which directory it opened on.
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentPicker.recordEvent("closed without a folder", url: nil,
                                       openSeconds: Date().timeIntervalSince(presentedAt),
                                       startedIn: BackupPickerStart.category(controller.directoryURL))
            finish(nil)
        }

        /// Resumes the caller exactly once; also called by `present` when UIKit never showed the picker.
        func finish(_ url: URL?) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: url)
        }
    }

    /// Persists the last picker outcome for the debug export, to tell "no URL came back" from "a URL we
    /// failed to bookmark" (`FolderBackup.saveFolder`). `startedIn` is a category, never a path: the
    /// export is attached to public issues and is not redacted, so a folder name never leaves the device.
    static func recordEvent(_ kind: String, url: URL?, openSeconds: Double? = nil, startedIn: String? = nil) {
        let d = UserDefaults.standard
        d.set(kind, forKey: "backupPicker.lastEvent")
        d.set(Date().timeIntervalSince1970, forKey: "backupPicker.lastEventAt")
        d.set(url?.lastPathComponent ?? "", forKey: "backupPicker.lastName")
        // Written unconditionally so duration/start folder never come from an earlier pick.
        d.set(openSeconds ?? 0, forKey: "backupPicker.lastOpenSeconds")
        d.set(startedIn ?? "", forKey: "backupPicker.lastStart")
    }
}

#endif

import Foundation

/// Which KIND of directory the backup folder picker opened on, with no name attached (the name must
/// not reach the debug export, #2337).
///
/// Outside the `#if os(iOS)` above because it is pure, so the macOS test bundle can run it.
enum BackupPickerStart {
    static func category(_ directory: URL?) -> String {
        guard let directory else { return "the picker default" }
        let ourDocuments = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return directory.standardizedFileURL == ourDocuments?.standardizedFileURL
            ? "Zoop's own folder" : "a folder you chose"
    }
}
