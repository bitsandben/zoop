import Foundation
import StrandAnalytics
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
import CoreVideo
#endif

// Frame-time / hitch / memory monitor for the Display & Performance test mode (Test Centre).
//
// Contract: this is a performance tool that must not cost performance. It runs ONLY while the mode is
// active (start() on toggle-on, stop() on toggle-off); with the mode off no display link exists, no
// frame callback fires and no `.display` line is emitted (pinned by DisplayPerformanceMonitorTests).
// Frames are summarised once per window, not per frame, through LiveState.append(log:domain:.display),
// the single redacting sink.

/// Owns the live frame monitor for the Display mode. `@MainActor`: it touches the display link, key
/// window and LiveState sink.
@MainActor
final class DisplayPerformanceMonitor {

    static let shared = DisplayPerformanceMonitor()
    private init() {}

    /// A frame is a hitch when its duration exceeds this (ms); 33 ms is a dropped frame at 60 Hz.
    static let hitchThresholdMs: Double = 33

    /// Frames per rolling summary (~1 s at 60 Hz); per-window emission keeps the log from flooding.
    static let windowFrames = 60

    /// Sink for tagged `.display` lines (LiveState.append(log:domain:)); nil leaves the monitor inert.
    var emit: ((String) -> Void)?

    /// Reads the on-device data volume straight from the store (not the view-models) so import-driven lag
    /// shows its read-set. nil leaves the dataVolume line unemitted. Async because the store is an actor.
    var dataVolumeProvider: (() async -> DataVolume?)?

    private var running = false

    // Frame-time accumulation for the current window.
    private var lastFrameTimestamp: CFTimeInterval = 0
    private var windowDurationsMs: [Double] = []
    private var windowHitches = 0
    private var windowWorstMs: Double = 0

    /// Peak resident footprint (MB) since start().
    private var memoryPeakMB: Double = 0

    #if os(iOS)
    private var displayLink: CADisplayLink?
    #endif
    #if os(macOS)
    private var cvLink: CVDisplayLink?
    #endif

    /// True only while a display link is live.
    var isRunning: Bool { running }

    // MARK: - Lifecycle (the only place a display link is created / destroyed)

    /// Starts sampling (idempotent) and emits one device-metrics line immediately.
    func start() {
        guard !running else { return }
        running = true
        resetWindow()
        lastFrameTimestamp = 0
        memoryPeakMB = 0
        sampleMemory()
        emitDeviceMetrics()
        emitDataVolume()

        #if os(iOS)
        let link = CADisplayLink(target: self, selector: #selector(onFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #endif
        #if os(macOS)
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        if let link {
            // The CVDisplayLink callback fires on a private thread; hop to the main actor.
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, inNow, _, _, _ in
                let nowSeconds = Double(inNow.pointee.hostTime) / Double(machTimebaseHz())
                Task { @MainActor in self?.foldFrame(timestamp: nowSeconds) }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            cvLink = link
        }
        #endif
    }

    /// Tears the display link down, flushes a final partial window and emits the memory high-water.
    /// Idempotent.
    func stop() {
        guard running else { return }
        running = false

        #if os(iOS)
        displayLink?.invalidate()
        displayLink = nil
        #endif
        #if os(macOS)
        if let link = cvLink {
            CVDisplayLinkStop(link)
        }
        cvLink = nil
        #endif

        // Flush the last partial window, then the high-water mark.
        flushWindow()
        emit?(DisplayTrace.memoryHighWaterLine(peakMB: memoryPeakMB))
    }

    // MARK: - Frame sampling

    #if os(iOS)
    @objc private func onFrame(_ link: CADisplayLink) {
        foldFrame(timestamp: link.timestamp)
    }
    #endif

    /// Folds one frame timestamp into the window; the first frame only seeds the previous timestamp.
    /// A full window flushes a summary and resets.
    private func foldFrame(timestamp: CFTimeInterval) {
        guard running else { return }
        defer { lastFrameTimestamp = timestamp }
        guard lastFrameTimestamp > 0 else { return }   // seed frame, no duration yet
        let durationMs = (timestamp - lastFrameTimestamp) * 1000.0
        guard durationMs > 0, durationMs < 5_000 else { return }  // ignore a backgrounding gap
        windowDurationsMs.append(durationMs)
        if durationMs > Self.hitchThresholdMs { windowHitches += 1 }
        if durationMs > windowWorstMs { windowWorstMs = durationMs }
        if windowDurationsMs.count >= Self.windowFrames {
            sampleMemory()
            flushWindow()
        }
    }

    /// Emits the rolling summary for the completed window and resets; no-op when empty.
    private func flushWindow() {
        guard !windowDurationsMs.isEmpty else { return }
        let stats = DisplayPerformanceMonitor.windowStats(durationsMs: windowDurationsMs)
        emit?(DisplayTrace.frameSummaryLine(
            frames: windowDurationsMs.count,
            meanMs: stats.mean, p95Ms: stats.p95,
            hitches: windowHitches, worstMs: windowWorstMs,
            hitchThresholdMs: Self.hitchThresholdMs))
        resetWindow()
    }

    private func resetWindow() {
        windowDurationsMs.removeAll(keepingCapacity: true)
        windowHitches = 0
        windowWorstMs = 0
    }

    /// Mean and p95 of the frame durations; pure so fixtures can pin the numbers.
    static func windowStats(durationsMs: [Double]) -> (mean: Double, p95: Double) {
        guard !durationsMs.isEmpty else { return (0, 0) }
        let mean = durationsMs.reduce(0, +) / Double(durationsMs.count)
        let sorted = durationsMs.sorted()
        // Nearest-rank p95 (idx = ceil(0.95 * n), clamped): a window of 20 with one hitch lands p95 on the
        // hitch rather than hiding it under the healthy frames.
        let idx = Int((0.95 * Double(sorted.count)).rounded(.up))
        let p95 = sorted[min(idx, sorted.count - 1)]
        return (mean, p95)
    }

    // MARK: - Memory high-water

    /// Samples the resident footprint and raises the high-water mark; a read failure leaves it unchanged.
    private func sampleMemory() {
        if let mb = Self.residentFootprintMB(), mb > memoryPeakMB { memoryPeakMB = mb }
    }

    /// Resident footprint in MB via `task_info(TASK_VM_INFO).phys_footprint`, or nil on failure.
    static func residentFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }

    // MARK: - Device metrics

    /// Reads the live display metrics and emits the device-metrics line (re-emit on trait/orientation change).
    func emitDeviceMetrics() {
        emit?(DisplayTrace.deviceMetricsLine(Self.readMetrics()))
    }

    /// Reads the on-device data volume via `dataVolumeProvider` and emits one `dataVolume` line on the
    /// main actor; no provider means no line.
    private func emitDataVolume() {
        guard let dataVolumeProvider, emit != nil else { return }
        Task { [weak self] in
            let volume = await dataVolumeProvider()
            await MainActor.run {
                guard let self, let volume else { return }
                self.emit?(DisplayTrace.dataVolumeLine(volume))
            }
        }
    }

    /// Reads the current display environment into `DisplayMetrics`; macOS degrades iOS-only metrics to nil.
    static func readMetrics() -> DisplayMetrics {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.keyWindow ?? scene?.windows.first
        let traits = window?.traitCollection ?? UITraitCollection.current
        let insets = window?.safeAreaInsets ?? .zero
        let bounds = window?.bounds.size ?? scene?.screen.bounds.size ?? .zero
        let scale = scene?.screen.scale ?? UIScreen.main.scale
        let portrait = (scene?.interfaceOrientation.isPortrait) ?? (bounds.height >= bounds.width)
        return DisplayMetrics(
            horizontalSizeClass: sizeClassName(traits.horizontalSizeClass),
            verticalSizeClass: sizeClassName(traits.verticalSizeClass),
            widthPt: Double(bounds.width), heightPt: Double(bounds.height), scale: Double(scale),
            safeTop: Double(insets.top), safeBottom: Double(insets.bottom),
            safeLeading: Double(insets.left), safeTrailing: Double(insets.right),
            dynamicType: contentSizeName(traits.preferredContentSizeCategory),
            orientation: portrait ? "portrait" : "landscape",
            theme: traits.userInterfaceStyle == .dark ? "dark" : "light")
        #elseif os(macOS)
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
        let screen = window?.screen ?? NSScreen.main
        let size = window?.frame.size ?? screen?.frame.size ?? .zero
        let scale = screen?.backingScaleFactor ?? 0
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return DisplayMetrics(
            horizontalSizeClass: nil, verticalSizeClass: nil,   // macOS has no size class
            widthPt: Double(size.width), heightPt: Double(size.height), scale: Double(scale),
            safeTop: 0, safeBottom: 0, safeLeading: 0, safeTrailing: 0,   // no notch insets on macOS
            dynamicType: nil,                                  // no Dynamic Type on macOS
            orientation: size.height >= size.width ? "portrait" : "landscape",
            theme: dark ? "dark" : "light")
        #else
        return DisplayMetrics(
            horizontalSizeClass: nil, verticalSizeClass: nil,
            widthPt: 0, heightPt: 0, scale: 0,
            safeTop: 0, safeBottom: 0, safeLeading: 0, safeTrailing: 0,
            dynamicType: nil, orientation: "unknown", theme: "light")
        #endif
    }

    #if os(iOS)
    private static func sizeClassName(_ c: UIUserInterfaceSizeClass) -> String? {
        switch c {
        case .compact: return "compact"
        case .regular: return "regular"
        default: return nil
        }
    }

    /// Short Dynamic Type label ("L" / "XXL" / "AX3").
    private static func contentSizeName(_ c: UIContentSizeCategory) -> String {
        switch c {
        case .extraSmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .extraLarge: return "XL"
        case .extraExtraLarge: return "XXL"
        case .extraExtraExtraLarge: return "XXXL"
        case .accessibilityMedium: return "AX1"
        case .accessibilityLarge: return "AX2"
        case .accessibilityExtraLarge: return "AX3"
        case .accessibilityExtraExtraLarge: return "AX4"
        case .accessibilityExtraExtraExtraLarge: return "AX5"
        default: return "L"
        }
    }
    #endif
}

#if os(macOS)
/// Mach timebase ticks-per-second, so CVDisplayLink host time converts to seconds.
private func machTimebaseHz() -> UInt64 {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    // ticks * (numer/denom) = ns, so ticks-per-second = 1e9 * denom/numer.
    guard info.numer != 0 else { return 1_000_000_000 }
    return UInt64(1_000_000_000) * UInt64(info.denom) / UInt64(info.numer)
}
#endif
