import SwiftUI

// MARK: - Settings page template (CONCEPT §3.9)
//
// Every settings-style page is groups of rows in a `ListCard`: a label on the left, one control on the
// right, at most one sentence of note. Push-only (inline title), flat canvas, 24 pt between groups.
//
//     ZoopSettingsPage("Units") {
//         ZoopSettingsGroup("Display", footer: "Applies to every screen.") {
//             ZoopSettingsToggleRow("24-hour clock", isOn: $use24h, isFirst: true)
//             ZoopSettingsRow("Temperature", value: "°C")
//         }
//     }

public struct ZoopSettingsPage<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    public init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) { content }
                .padding(.horizontal, ZoopSpacing.gutter)
                .padding(.top, ZoopSpacing.s)
                .padding(.bottom, ZoopSpacing.xxl)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// A titled group of rows. The footer is the one sentence that explains the whole group.
public struct ZoopSettingsGroup<Rows: View>: View {
    private let title: LocalizedStringKey?
    private let footer: LocalizedStringKey?
    private let rows: Rows

    public init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
                @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.footer = footer
        self.rows = rows()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            if let title {
                Text(title)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, ZoopSpacing.xs)
                    .accessibilityAddTraits(.isHeader)
            }
            ListCard { rows }
            if let footer {
                Text(footer)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ZoopSpacing.xs)
            }
        }
    }
}

/// Label left, control right, optional note underneath. Pass `isFirst: true` on the first row of a
/// group so no hairline is drawn above it.
public struct ZoopSettingsRow<Control: View>: View {
    private let label: LocalizedStringKey
    private let systemImage: String?
    private let note: LocalizedStringKey?
    private let isFirst: Bool
    private let control: Control

    public init(_ label: LocalizedStringKey, systemImage: String? = nil, note: LocalizedStringKey? = nil,
                isFirst: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.systemImage = systemImage
        self.note = note
        self.isFirst = isFirst
        self.control = control()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            HStack(alignment: .center, spacing: ZoopSpacing.m) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: ZoopSpacing.xl)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                control.layoutPriority(1)
            }
            if let note {
                Text(note)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: ZoopButtonMetrics.minHitTarget - 2 * ZoopSpacing.m)
        .contentShape(Rectangle())
        .listCardRow(isFirst: isFirst)
    }
}

/// Trailing value plus `›` for a row that navigates or shows a read-only value.
public struct ZoopSettingsDisclosure: View {
    private let value: String?
    private let showsChevron: Bool

    public init(value: String? = nil, showsChevron: Bool = true) {
        self.value = value
        self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: ZoopSpacing.s) {
            if let value {
                Text(verbatim: value)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

public extension ZoopSettingsRow where Control == ZoopSettingsDisclosure {
    /// A value row (`value` already formatted, e.g. via `MetricUnit.format`) with an optional `›`.
    init(_ label: LocalizedStringKey, systemImage: String? = nil, value: String? = nil,
         showsChevron: Bool = true, note: LocalizedStringKey? = nil, isFirst: Bool = false) {
        self.init(label, systemImage: systemImage, note: note, isFirst: isFirst) {
            ZoopSettingsDisclosure(value: value, showsChevron: showsChevron)
        }
    }
}

/// A switch row. The label doubles as the switch's VoiceOver label.
public struct ZoopSettingsToggleRow: View {
    private let label: LocalizedStringKey
    private let systemImage: String?
    private let note: LocalizedStringKey?
    private let isFirst: Bool
    @Binding private var isOn: Bool

    public init(_ label: LocalizedStringKey, systemImage: String? = nil, isOn: Binding<Bool>,
                note: LocalizedStringKey? = nil, isFirst: Bool = false) {
        self.label = label
        self.systemImage = systemImage
        self._isOn = isOn
        self.note = note
        self.isFirst = isFirst
    }

    public var body: some View {
        ZoopSettingsRow(label, systemImage: systemImage, note: note, isFirst: isFirst) {
            Toggle(isOn: $isOn) { Text(label) }
                .labelsHidden()
                .tint(StrandPalette.accent)
        }
    }
}

#if DEBUG
private struct SettingsPagePreview: View {
    @State private var on = true
    var body: some View {
        NavigationStack {
            ZoopSettingsPage("Units") {
                ZoopSettingsGroup("Display", footer: "Applies to every screen.") {
                    ZoopSettingsToggleRow("24-hour clock", systemImage: "clock", isOn: $on, isFirst: true)
                    ZoopSettingsRow("Temperature", systemImage: "thermometer.medium", value: "°C")
                    ZoopSettingsRow("Weight", value: "kg", showsChevron: false,
                                    note: "Stored in kilograms, shown in your unit.")
                }
                ZoopSettingsGroup {
                    ZoopSettingsRow("About Zoop", isFirst: true)
                }
            }
        }
    }
}

#Preview("Settings page") { SettingsPagePreview().preferredColorScheme(.dark) }
#Preview("Settings page · pastel") {
    SettingsPagePreview().zoopTheme(ZoopTheme.pastel.rawValue).preferredColorScheme(.light)
}
#endif
