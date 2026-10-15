import Foundation
import Combine
import SwiftUI
import StrandDesign

// MARK: - Custom background image (#custom-background)
// A user-picked photo drawn full-bleed behind every screen, replacing the day-cycle sky when enabled
// (precedence: image > sky > flat canvas). Pref keys and `BackgroundFillMode` raw values are shared with
// Android. The bytes live in a file under Application Support (a full-screen photo is far larger than
// the avatar blob); the file and its toggles are device-local and deliberately not in the `.zoopbak` whitelist.
// A single shared @MainActor ObservableObject: the decoded `Image` is cached once so every scaffold
// backdrop and Today's inline sky draw the identical picture with no per-tab re-decode.

@MainActor
final class BackgroundImageStore: ObservableObject {
    static let shared = BackgroundImageStore()

    /// One recent background: its app-private filename and the fill mode it was last shown with.
    struct Recent: Equatable {
        let id: String
        let fillMode: BackgroundFillMode
    }

    /// The recent images, most recent (active) first, up to ``maxRecents``.
    @Published private(set) var recents: [Recent] = []

    /// The active image (recents[0]) decoded for the backdrop; nil = none stored.
    @Published private(set) var image: Image?

    /// Small previews, index-aligned to ``recents`` (nil for a decode miss).
    @Published private(set) var thumbnails: [Image?] = []

    /// Master enable toggle (``BackgroundImagePrefs/enabledKey``); with an image present it overrides the sky.
    @Published var enabled: Bool {
        didSet { d.set(enabled, forKey: BackgroundImagePrefs.enabledKey) }
    }

    private let d = UserDefaults.standard

    /// How the active image is scaled: the fill mode of the most recent entry.
    var fillMode: BackgroundFillMode { recents.first?.fillMode ?? .fill }

    /// Enabled and actually decoded.
    var isActive: Bool { enabled && image != nil }

    /// Whether a photo is stored; drives the Remove affordance.
    var hasImage: Bool { image != nil }

    private init() {
        enabled = d.bool(forKey: BackgroundImagePrefs.enabledKey)                       // default false
        var list = Self.parse(d.string(forKey: BackgroundImagePrefs.recentsKey) ?? "")
            .filter { Self.fileExists($0.id) }
        // Migration: adopt the pre-recents single `background.jpg` as the sole recent.
        if list.isEmpty, d.bool(forKey: BackgroundImagePrefs.presentKey), Self.fileExists("background.jpg") {
            list = [Recent(id: "background.jpg",
                           fillMode: BackgroundFillMode.resolve(d.string(forKey: BackgroundImagePrefs.fillModeKey) ?? ""))]
        }
        let capped = Array(list.prefix(Self.maxRecents))
        recents = capped
        // GC orphan files not in the list (a crash between writing a pick and persisting the list). Writes are atomic.
        Self.gcOrphans(keeping: Set(capped.map(\.id)))
        image = capped.first.flatMap { Self.fullImage(id: $0.id) }
        thumbnails = capped.map { Self.thumbnail(id: $0.id) }
        persist()
    }

    /// Store a picked image: downscale and re-encode to an app-private JPEG, push it to the front of the
    /// recents (deleting any beyond ``maxRecents``) and refresh. Silently no-ops if the bytes cannot be decoded or written.
    func setImage(from data: Data) {
        let jpeg = AvatarImage.downscaledJPEG(from: data, maxDimension: Self.maxDimension, quality: 0.9) ?? data
        guard PlatformImage(data: jpeg) != nil else { return }
        let id = "bg-\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
        guard let url = try? Self.fileURL(id: id, create: true) else { return }
        do { try jpeg.write(to: url, options: .atomic) } catch { return }
        // A fresh pick inherits the current fill mode.
        let next = Array(([Recent(id: id, fillMode: fillMode)] + recents).prefix(Self.maxRecents))
        for r in recents where !next.contains(r) {
            if let u = try? Self.fileURL(id: r.id, create: false) { try? FileManager.default.removeItem(at: u) }
        }
        recents = next
        refresh()
        // Picking an image means the user wants to see it; turn the background on.
        if !enabled { enabled = true }
        persist()
    }

    /// Re-apply a recent: move it to the front so it becomes the active image and fill mode.
    func applyRecent(_ index: Int) {
        guard recents.indices.contains(index), index != 0 else { return }
        let chosen = recents[index]
        recents = [chosen] + recents.enumerated().filter { $0.offset != index }.map { $0.element }
        refresh()
        if !enabled { enabled = true }
        persist()
    }

    /// Change the active image's fill mode.
    func setFillMode(_ mode: BackgroundFillMode) {
        guard !recents.isEmpty else {
            d.set(mode.rawValue, forKey: BackgroundImagePrefs.fillModeKey)
            return
        }
        recents = recents.enumerated().map { $0.offset == 0 ? Recent(id: $0.element.id, fillMode: mode) : $0.element }
        persist()
    }

    /// Remove the active image; the next recent becomes active, or the background clears.
    func clearImage() {
        guard let removed = recents.first else { return }
        if let u = try? Self.fileURL(id: removed.id, create: false) { try? FileManager.default.removeItem(at: u) }
        recents = Array(recents.dropFirst())
        refresh()
        persist()
    }

    /// Decode the active image and every recent's thumbnail.
    private func refresh() {
        image = recents.first.flatMap { Self.fullImage(id: $0.id) }
        thumbnails = recents.map { Self.thumbnail(id: $0.id) }
    }

    private func persist() {
        d.set(Self.serialize(recents), forKey: BackgroundImagePrefs.recentsKey)
        d.set(fillMode.rawValue, forKey: BackgroundImagePrefs.fillModeKey)
        d.set(!recents.isEmpty, forKey: BackgroundImagePrefs.presentKey)
    }

    /// How many recents the presets strip keeps (MRU).
    static let maxRecents = 3

    /// Longest edge (px) the stored image is downscaled to.
    private static let maxDimension: CGFloat = 2560

    /// `"<file>,<mode>;<file>,<mode>"`. Filenames never contain `,`/`;`.
    static func serialize(_ list: [Recent]) -> String {
        list.map { "\($0.id),\($0.fillMode.rawValue)" }.joined(separator: ";")
    }

    static func parse(_ s: String) -> [Recent] {
        s.split(separator: ";").compactMap { entry -> Recent? in
            let parts = entry.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return Recent(id: String(parts[0]), fillMode: BackgroundFillMode.resolve(String(parts[1])))
        }
    }

    private static func fullImage(id: String) -> Image? {
        guard let url = try? fileURL(id: id, create: false),
              let data = try? Data(contentsOf: url),
              let platform = PlatformImage(data: data) else { return nil }
        return Image(platformImage: platform)
    }

    private static func thumbnail(id: String) -> Image? {
        guard let url = try? fileURL(id: id, create: false),
              let data = try? Data(contentsOf: url),
              let jpeg = AvatarImage.downscaledJPEG(from: data, maxDimension: 256, quality: 0.85),
              let platform = PlatformImage(data: jpeg) else { return nil }
        return Image(platformImage: platform)
    }

    private static func fileExists(_ id: String) -> Bool {
        guard let url = try? fileURL(id: id, create: false) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// `<AppSupport>/OpenWhoop/<id>` (the same base folder the capture recorder uses).
    private static func fileURL(id: String, create: Bool) throws -> URL {
        let dir = try dirURL(create: create)
        return dir.appendingPathComponent(id, isDirectory: false)
    }

    private static func dirURL(create: Bool = false) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: create)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        if create { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir
    }

    /// Delete background files (`bg-*.jpg`, legacy `background.jpg`) not in `keeping`; avatar and capture files are untouched.
    private static func gcOrphans(keeping kept: Set<String>) {
        guard let dir = try? dirURL(create: false),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where (name.hasPrefix("bg-") || name == "background.jpg") && !kept.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

// MARK: - BackgroundImageBackdrop
// Draws the cached custom image full-bleed under the whole screen per the store's fill mode. Decorative,
// accessibility-hidden.

struct BackgroundImageBackdrop: View {
    @ObservedObject private var store = BackgroundImageStore.shared

    var body: some View {
        if let image = store.image {
            scaled(image)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func scaled(_ image: Image) -> some View {
        switch store.fillMode {
        case .fill:
            image.resizable().scaledToFill()
        case .fit:
            // Aspect-fit letterboxes onto the canvas beneath.
            image.resizable().scaledToFit()
        case .stretch:
            // Stretches to fill the frame.
            image.resizable()
        case .tile:
            // Tiles the source across the viewport.
            image.resizable(resizingMode: .tile)
        }
    }
}
