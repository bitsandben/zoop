#if DEBUG
import Foundation

// MARK: - DEBUG-only sync-indicator harness
//
// Companion to DemoDayHarness for the Today header's charge-to-sync control, which reads LiveState
// (battery, backfill) that the synthetic dataset cannot supply.
// `--demo-sync` supplies a synthetic battery reading so the control takes the `.charge` path, and cycles
// the syncing signal so the morph loops without a real offload.
// The whole file is `#if DEBUG`; without the flag `active` stays false and the shipped control is
// untouched. Synthetic only.

enum DemoSyncHarness {

    /// True only when `--demo-sync` was passed.
    static private(set) var active = false

    /// Synthetic battery: mid-range and not charging, so the ring shows a partial arc and the
    /// arc-to-spinner morph stays visible.
    static let batteryPercent: Double = 72
    static let charging = false

    /// Idle stretch between sync bursts. Must exceed `StrandMotion.syncIndicatorSignalDebounceNanoseconds`
    /// (3s): LiquidBatteryButton debounces the falling edge, so a shorter idle never collapses the capsule.
    static let idleSeconds: Double = 5.0

    /// Chunks per burst, so the read-out ticks 1, 2, 3 like a real offload.
    static let chunkTicks = 3
    static let chunkIntervalSeconds: Double = 1.2

    /// Scans launch args for `--demo-sync`. Call once at launch beside DemoDayHarness; idempotent.
    static func applyLaunchArgsIfNeeded() {
        active = CommandLine.arguments.contains("--demo-sync")
    }
}
#endif
