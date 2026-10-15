import Foundation

/// What a pull-to-sync on Today is doing, as far as the pull itself can observe it.
enum PullSyncPhase: Equatable {
    case idle
    /// The pull asked the strap for its history and is waiting to see an offload start.
    case requesting
    /// The offload ended (or never applied); the app is reloading and scoring what is stored.
    case computing
    /// How the pull ended, shown briefly before the capsule returns to the live status.
    case finished(PullSyncOutcome)

    var isBusy: Bool { self == .requesting || self == .computing }
}

/// The one answer to "what does the sync capsule say right now". Built from the shared `SyncStatus`
/// resolver plus the pull's own phase, so the capsule and every other sync surface agree. A percentage
/// never appears: the strap protocol cannot say how much history is pending, so progress is a count of
/// received chunks or an indeterminate ring with the phase name.
struct SyncCapsuleState: Equatable {
    enum Ring: Equatable {
        /// A closed ring: the strap is caught up.
        case full
        /// An indeterminate arc: something is in flight whose length is unknown.
        case spinning
        /// No ring: a resting or blocked state.
        case none
    }

    /// What a tap on the capsule should do.
    enum Tap: Equatable {
        /// Open the strap screen.
        case devices
        /// Explain the state, and offer the fix when there is one.
        case explain(SyncExplanation)
    }

    let symbol: String
    let title: String
    let ring: Ring
    /// The brief "up to date" moment after a pull, drawn a touch stronger.
    let celebrates: Bool
    let tap: Tap

    static func resolve(status: SyncStatus, pull: PullSyncPhase,
                        now: TimeInterval = Date().timeIntervalSince1970) -> SyncCapsuleState {
        // A running offload is the most concrete fact there is, whoever started it.
        if case .syncing(let chunks) = status {
            return SyncCapsuleState(symbol: "arrow.triangle.2.circlepath", title: SyncCapsuleCopy.loading(chunks),
                                    ring: .spinning, celebrates: false, tap: .devices)
        }
        switch pull {
        case .requesting:
            return SyncCapsuleState(symbol: "arrow.triangle.2.circlepath", title: SyncCapsuleCopy.starting,
                                    ring: .spinning, celebrates: false, tap: .devices)
        case .computing:
            return SyncCapsuleState(symbol: "waveform.path.ecg", title: SyncCapsuleCopy.computing,
                                    ring: .spinning, celebrates: false, tap: .devices)
        case .finished(.upToDate):
            let at = status.lastSyncedAt ?? now
            return SyncCapsuleState(symbol: "checkmark", title: SyncCapsuleCopy.upToDate(relativeAgo(at, now: now)),
                                    ring: .full, celebrates: true, tap: .devices)
        case .finished(.didNotStart):
            return SyncCapsuleState(symbol: "exclamationmark", title: PullSyncOutcome.didNotStart.title,
                                    ring: .none, celebrates: false, tap: .explain(.didNotStart))
        case .finished(.stillSyncing), .finished(.status), .idle:
            return resting(status, now: now)
        }
    }

    private static func resting(_ status: SyncStatus, now: TimeInterval) -> SyncCapsuleState {
        let title = status.title(now: now)
        switch status {
        case .bluetoothUnavailable(let message):
            return SyncCapsuleState(symbol: "antenna.radiowaves.left.and.right.slash", title: title, ring: .none,
                                    celebrates: false, tap: .explain(.bluetooth(message)))
        case .noStrap:
            return SyncCapsuleState(symbol: "antenna.radiowaves.left.and.right.slash", title: title, ring: .none,
                                    celebrates: false, tap: .devices)
        case .pairing:
            return SyncCapsuleState(symbol: "link", title: title, ring: .spinning, celebrates: false, tap: .devices)
        case .syncing:
            return SyncCapsuleState(symbol: "arrow.triangle.2.circlepath", title: title, ring: .spinning,
                                    celebrates: false, tap: .devices)
        case .stalled(let message):
            return SyncCapsuleState(symbol: "exclamationmark", title: title, ring: .none,
                                    celebrates: false, tap: .explain(.stalled(message)))
        case .completeWithNote(_, let message):
            return SyncCapsuleState(symbol: "checkmark", title: title, ring: .full,
                                    celebrates: false, tap: .explain(.note(message)))
        case .complete:
            return SyncCapsuleState(symbol: "checkmark", title: title, ring: .full, celebrates: false, tap: .devices)
        case .neverSynced:
            return SyncCapsuleState(symbol: "arrow.triangle.2.circlepath", title: title, ring: .none,
                                    celebrates: false, tap: .devices)
        }
    }
}

/// A state the capsule explains on tap instead of navigating away. `message` is the BLE layer's own
/// wording, shown verbatim beneath a localized lead line.
enum SyncExplanation: Equatable, Identifiable {
    case bluetooth(String)
    case stalled(String)
    case note(String)
    case didNotStart

    var id: String {
        switch self {
        case .bluetooth(let m): return "bt-\(m)"
        case .stalled(let m): return "stalled-\(m)"
        case .note(let m): return "note-\(m)"
        case .didNotStart: return "didNotStart"
        }
    }

    var lead: String {
        switch self {
        case .bluetooth: return SyncCapsuleCopy.bluetoothLead
        case .stalled: return SyncCapsuleCopy.stalledLead
        case .note: return SyncCapsuleCopy.noteLead
        case .didNotStart: return SyncCapsuleCopy.didNotStartLead
        }
    }

    var message: String? {
        switch self {
        case .bluetooth(let m), .stalled(let m), .note(let m): return m
        case .didNotStart: return nil
        }
    }

    /// Whether another pull could help: not while the radio itself is unusable.
    var offersRetry: Bool {
        switch self {
        case .stalled, .didNotStart: return true
        case .bluetooth, .note: return false
        }
    }

    var offersSettings: Bool {
        if case .bluetooth = self { return true }
        return false
    }
}

/// The capsule's own words. Status titles still come from `SyncStatus.title`.
enum SyncCapsuleCopy {
    static var starting: String { String(localized: "zoop.sync.starting", defaultValue: "Starting sync…") }
    static func loading(_ chunks: Int) -> String {
        chunks > 0 ? String(localized: "zoop.sync.loadingCount", defaultValue: "Loading strap data · \(chunks)")
                   : String(localized: "zoop.sync.loading", defaultValue: "Loading strap data…")
    }
    static var computing: String { String(localized: "zoop.sync.computing", defaultValue: "Calculating scores…") }
    static func upToDate(_ ago: String) -> String {
        String(localized: "zoop.sync.upToDate", defaultValue: "Up to date · \(ago)")
    }
    static var pull: String { String(localized: "zoop.sync.pull", defaultValue: "Pull to sync") }
    static var release: String { String(localized: "zoop.sync.release", defaultValue: "Release to sync") }
    static var bluetoothLead: String {
        String(localized: "zoop.sync.bluetooth.lead", defaultValue: "Zoop needs Bluetooth to reach your strap.")
    }
    static var stalledLead: String {
        String(localized: "zoop.sync.stalled.lead", defaultValue: "The last sync stopped before it finished.")
    }
    static var noteLead: String {
        String(localized: "zoop.sync.note.lead", defaultValue: "The last sync finished with a note.")
    }
    static var didNotStartLead: String {
        String(localized: "zoop.sync.didNotStart.lead",
               defaultValue: "The strap didn't start sending data. Try again in a moment.")
    }
}
