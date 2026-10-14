import Foundation

/// Something the last offload, or the Bluetooth radio, left for the user to know about. The kind keeps
/// apart facts that used to share one free-text field: a sync that stopped, a sync that completed but
/// carries a caveat, and a radio that cannot be used at all.
public struct SyncIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The offload ended before it finished and banked nothing.
        case stalled
        /// The offload completed; the message is a caveat about what it handed over.
        case completedWithNote
        /// Bluetooth is off, unsupported, or not permitted, so no sync can start.
        case bluetooth
    }

    public let kind: Kind
    public let message: String

    public static func stalled(_ message: String) -> SyncIssue { SyncIssue(kind: .stalled, message: message) }
    public static func completedWithNote(_ message: String) -> SyncIssue {
        SyncIssue(kind: .completedWithNote, message: message)
    }
    public static func bluetooth(_ message: String) -> SyncIssue { SyncIssue(kind: .bluetooth, message: message) }
}

/// The live fields the sync status is derived from, copied out so the resolver stays a pure function.
struct SyncStatusInput: Equatable {
    var connected: Bool
    var historyReady: Bool
    var backfilling: Bool
    var chunks: Int
    var lastSyncedAt: TimeInterval?
    var issue: SyncIssue?
}

/// The one answer to "where is the strap sync at". Every sync surface renders from this, so two screens
/// cannot describe the same moment differently.
enum SyncStatus: Equatable {
    case bluetoothUnavailable(message: String)
    case noStrap(lastSyncedAt: TimeInterval?)
    /// Connected, but the link is not ready to offload yet.
    case pairing
    case syncing(chunks: Int)
    case stalled(message: String)
    case completeWithNote(at: TimeInterval, message: String)
    case complete(at: TimeInterval)
    /// Connected and ready, with no completed offload this launch or remembered for this strap.
    case neverSynced

    static func resolve(_ input: SyncStatusInput) -> SyncStatus {
        if let issue = input.issue, issue.kind == .bluetooth {
            return .bluetoothUnavailable(message: issue.message)
        }
        if input.backfilling { return .syncing(chunks: input.chunks) }
        guard input.connected else { return .noStrap(lastSyncedAt: input.lastSyncedAt) }
        guard input.historyReady else { return .pairing }
        switch (input.issue, input.lastSyncedAt) {
        case let (issue?, _) where issue.kind == .stalled:
            return .stalled(message: issue.message)
        // A completion caveat always has a stamp: BLEManager stamps `lastSyncedAt` before it classifies
        // the completed offload.
        case let (issue?, at?) where issue.kind == .completedWithNote:
            return .completeWithNote(at: at, message: issue.message)
        case let (_, at?):
            return .complete(at: at)
        default:
            return .neverSynced
        }
    }

    /// When the last offload completed, in any state that knows it.
    var lastSyncedAt: TimeInterval? {
        switch self {
        case .complete(let at), .completeWithNote(let at, _): return at
        case .noStrap(let at): return at
        default: return nil
        }
    }

    var isStalled: Bool {
        if case .stalled = self { return true }
        return false
    }
}

/// How a pull-to-sync ended, judged only from what the pull could observe.
enum PullSyncOutcome: Equatable {
    case upToDate
    case stillSyncing
    case didNotStart
    /// A state that explains itself (no strap, pairing, Bluetooth, a stopped sync).
    case status(SyncStatus)

    /// - Parameters:
    ///   - status: the sync status sampled once the pull stopped following the offload.
    ///   - sawOffload: whether an offload was seen running during the pull.
    ///   - pullStartedAt: when the pull was released, so an older completion is not claimed as this one.
    static func resolve(status: SyncStatus, sawOffload: Bool, pullStartedAt: TimeInterval) -> PullSyncOutcome {
        switch status {
        case .syncing:
            return .stillSyncing
        case .noStrap, .pairing, .bluetoothUnavailable:
            return .status(status)
        default:
            break
        }
        if let at = status.lastSyncedAt, at >= pullStartedAt { return .upToDate }
        guard sawOffload else { return .didNotStart }
        // An offload ran and ended without a completion stamp: a stop it reported, else a session that
        // ended on the idle timeout after banking rows, which is a normal finish for this strap.
        return status.isStalled ? .status(status) : .upToDate
    }
}
