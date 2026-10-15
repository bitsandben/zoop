import SwiftUI

// MARK: - ZoopEmptyState (CONCEPT §1 principle 3: "a dash is never a valid state")
//
// What a screen or card shows instead of a number when there is nothing to show yet: a quiet icon,
// one headline, one sentence of why plus what to do, and at most one secondary action. Calm by
// default: no colour, no alert styling.

public struct ZoopEmptyState: View {
    /// `.card` draws its own `ContentCard`; `.plain` sits inside a card the caller already has.
    public enum Style: Sendable { case card, plain }

    private let systemImage: String
    private let title: Text
    private let message: Text
    private let actionTitle: Text?
    private let action: (() -> Void)?
    private let style: Style

    public init(
        systemImage: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        actionTitle: LocalizedStringKey? = nil,
        style: Style = .card,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = Text(title)
        self.message = Text(message)
        self.actionTitle = actionTitle.map { Text($0) }
        self.style = style
        self.action = action
    }

    /// For catalogue resources built in a feature's `Strings` enum.
    @_disfavoredOverload
    public init(
        systemImage: String,
        title: LocalizedStringResource,
        message: LocalizedStringResource,
        actionTitle: LocalizedStringResource? = nil,
        style: Style = .card,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.title = Text(title)
        self.message = Text(message)
        self.actionTitle = actionTitle.map { Text($0) }
        self.style = style
        self.action = action
    }

    public var body: some View {
        switch style {
        case .card: ContentCard { content }
        case .plain: content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            Image(systemName: systemImage)
                .font(ZoopType.metric)
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                title
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                message
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            if let actionTitle, let action {
                Button(action: action) { actionTitle }
                    .buttonStyle(ZoopButtonStyle(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Empty state") {
    VStack(spacing: ZoopSpacing.cardGap) {
        ZoopEmptyState(systemImage: "moon.zzz", title: "No sleep recorded",
                       message: "Wear the strap tonight and your sleep appears here in the morning.")
        ZoopEmptyState(systemImage: "figure.run", title: "No workouts this week",
                       message: "Log a session or let the strap detect one.", actionTitle: "Log workout") {}
    }
    .padding(ZoopSpacing.gutter)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
