import SwiftUI

// MARK: - ZoopStaleNote (CONCEPT §1.1 "Data state")
//
// One quiet line that dates a value which is not current: "As of 12 Oct", or "No data since 12 Oct".
// Plain caption text with a clock glyph, never a tinted capsule. Put it directly under the thing it
// dates; a screen-wide sync problem belongs to the sync status view instead (§6).

public struct ZoopStaleNote: View {
    public enum Kind: Equatable, Sendable {
        /// The value shown is old; `since` is its timestamp.
        case stale(since: Date)
        /// Nothing in the window; nil when there never was any data.
        case noData(since: Date?)
    }

    private let kind: Kind
    private let message: Text?

    public init(_ kind: Kind, message: LocalizedStringKey? = nil) {
        self.kind = kind
        self.message = message.map { Text($0) }
    }

    @_disfavoredOverload
    public init(_ kind: Kind, message: LocalizedStringResource?) {
        self.kind = kind
        self.message = message.map { Text($0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.xs) {
                Image(systemName: "clock").imageScale(.small).accessibilityHidden(true)
                Text(headline)
            }
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            if let message {
                message
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var headline: LocalizedStringResource {
        switch kind {
        case .stale(let since): return MetricStrings.asOf(since)
        case .noData(let since?): return MetricStrings.noDataSince(since)
        case .noData(nil): return MetricStrings.noDataYet
        }
    }
}

#if DEBUG
#Preview("Stale note") {
    VStack(spacing: ZoopSpacing.l) {
        ZoopStaleNote(.stale(since: MetricSamples.lastWeek), message: "Sync the strap to update.")
        ZoopStaleNote(.noData(since: MetricSamples.lastWeek))
        ZoopStaleNote(.noData(since: nil))
    }
    .padding(ZoopSpacing.gutter)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
