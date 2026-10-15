import SwiftUI
import StrandDesign

// The one wording table for the strap sync. Every surface that names a sync state takes its words and
// tone from here.

extension SyncStatus {
    /// The short line a surface shows for this state.
    func title(now: TimeInterval = Date().timeIntervalSince1970) -> String {
        switch self {
        case .bluetoothUnavailable: return String(localized: "Bluetooth unavailable")
        case .noStrap: return String(localized: "Strap not connected")
        case .pairing: return String(localized: "Pairing…")
        case .syncing(let chunks):
            return chunks > 0 ? String(localized: "Syncing strap · \(chunks)") : String(localized: "Syncing strap…")
        case .stalled: return String(localized: "Sync interrupted")
        case .completeWithNote(let at, _), .complete(let at): return Self.lastSyncTitle(at: at, now: now)
        case .neverSynced: return String(localized: "Not synced yet")
        }
    }

    /// The last completed sync, or that there is none, regardless of the current state.
    static func lastSyncTitle(at: TimeInterval?, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        guard let at else { return String(localized: "Not synced yet") }
        return String(localized: "Last sync \(relativeAgo(at, now: now))")
    }

    /// The sync line for a surface that already shows the connection state beside it: without a ready
    /// link it falls back to the last completed sync instead of repeating "not connected".
    func syncLine(lastSyncedAt: TimeInterval?, now: TimeInterval = Date().timeIntervalSince1970) -> String {
        switch self {
        case .noStrap, .pairing: return Self.lastSyncTitle(at: lastSyncedAt, now: now)
        default: return title(now: now)
        }
    }

    /// The explanation the user can act on, when the state carries one.
    var detail: String? {
        switch self {
        case .bluetoothUnavailable(let message), .stalled(let message), .completeWithNote(_, let message):
            return message
        default:
            return nil
        }
    }

    var tone: StrandTone {
        switch self {
        case .bluetoothUnavailable, .stalled, .completeWithNote: return .warning
        case .syncing, .pairing: return .accent
        case .complete: return .positive
        case .noStrap, .neverSynced: return .neutral
        }
    }
}

extension PullSyncOutcome {
    var title: String {
        switch self {
        case .upToDate: return String(localized: "Up to date")
        case .stillSyncing: return String(localized: "Still syncing")
        case .didNotStart: return String(localized: "Sync didn't start")
        case .status(let status): return status.title()
        }
    }

    var symbol: String {
        switch self {
        case .upToDate: return "checkmark.circle.fill"
        case .stillSyncing: return "arrow.triangle.2.circlepath"
        case .didNotStart: return "exclamationmark.circle"
        case .status(.noStrap), .status(.bluetoothUnavailable):
            return "antenna.radiowaves.left.and.right.slash"
        case .status: return "exclamationmark.circle"
        }
    }
}

/// Plain sync-status line: title, with the actionable explanation beneath it when there is one.
struct SyncStatusLine: View {
    let status: SyncStatus
    var now: TimeInterval = Date().timeIntervalSince1970

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if case .syncing = status { ConnectionDot(tone: .accent, pulsing: true, size: 6) }
                Text(status.title(now: now))
                    .font(StrandFont.footnote.weight(.medium))
                    .foregroundStyle(status.tone == .warning ? status.tone.color : StrandPalette.textSecondary)
            }
            if let detail = status.detail {
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
