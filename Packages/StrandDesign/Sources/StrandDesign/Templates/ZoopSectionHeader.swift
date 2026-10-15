import SwiftUI

// MARK: - ZoopSectionHeader (CONCEPT §2.4 rule 3)
//
// The one section label inside a screen: a headline, an optional one-line subtitle and an optional
// trailing "more" action drawn as text plus `›` (no blue links, no ALL-CAPS overline). Sits ABOVE a
// card, never inside it, so a card never repeats its own title.

public struct ZoopSectionHeader: View {
    private let title: Text
    private let subtitle: Text?
    private let actionTitle: Text?
    private let action: (() -> Void)?

    public init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.actionTitle = actionTitle.map { Text($0) }
        self.action = action
    }

    /// For catalogue resources built in a feature's `Strings` enum.
    @_disfavoredOverload
    public init(
        _ title: LocalizedStringResource,
        subtitle: LocalizedStringResource? = nil,
        actionTitle: LocalizedStringResource? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = Text(title)
        self.subtitle = subtitle.map { Text($0) }
        self.actionTitle = actionTitle.map { Text($0) }
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.s) {
                title
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: ZoopSpacing.s)
                if let actionTitle, let action {
                    Button(action: action) {
                        HStack(spacing: ZoopSpacing.xs) {
                            actionTitle
                            Image(systemName: "chevron.right").imageScale(.small).accessibilityHidden(true)
                        }
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let subtitle {
                subtitle
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Section header") {
    VStack(spacing: ZoopSpacing.sectionGap) {
        ZoopSectionHeader("What shaped it")
        ZoopSectionHeader("Sessions", subtitle: "Last 7 days, newest first.", actionTitle: "All") {}
    }
    .padding(ZoopSpacing.gutter)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
