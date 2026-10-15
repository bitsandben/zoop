import SwiftUI
import StrandDesign

// The settings building blocks. Every page is groups of rows in a `ListCard`, so a toggle, a picker and a
// link read the same on every page and the copy stays at one sentence per setting (Zoop 2.0 §3.9).

/// A settings page: inline navigation title, flat canvas, 24-pt rhythm between groups.
struct SettingsPageScaffold<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScreenScaffold(title: title) {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) { content() }
        }
    }
}

/// A titled group of rows. The optional footer is the one sentence that explains the whole group.
struct SettingsGroup<Rows: View>: View {
    var title: LocalizedStringKey?
    var footer: Text?
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            if let title {
                Text(title)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, ZoopSpacing.xs)
                    .accessibilityAddTraits(.isHeader)
            }
            ListCard { rows() }
            if let footer {
                SettingsNote(footer).padding(.horizontal, ZoopSpacing.xs)
            }
        }
    }
}

/// Secondary copy under a row or group.
struct SettingsNote: View {
    private let text: Text
    init(_ key: LocalizedStringKey) { text = Text(key) }
    init(_ text: Text) { self.text = text }

    var body: some View {
        text
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label left, control right, optional note underneath.
struct SettingsRow<Control: View>: View {
    let label: LocalizedStringKey
    var note: LocalizedStringKey?
    var isFirst = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
            HStack(alignment: .center, spacing: ZoopSpacing.l) {
                Text(label)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                control().layoutPriority(1)
            }
            if let note { SettingsNote(note) }
        }
        .listCardRow(isFirst: isFirst)
    }
}

/// A switch row. The label doubles as the accessibility label.
struct SettingsToggleRow: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool
    var note: LocalizedStringKey?
    var isFirst = false

    var body: some View {
        SettingsRow(label: label, note: note, isFirst: isFirst) {
            Toggle(isOn: $isOn) { Text(label) }
                .labelsHidden()
                .tint(StrandPalette.accent)
        }
    }
}

/// A menu picker row over a raw-value preference.
struct SettingsMenuRow<Value: Hashable, Options: View>: View {
    let label: LocalizedStringKey
    @Binding var selection: Value
    var note: LocalizedStringKey?
    var isFirst = false
    @ViewBuilder var options: () -> Options

    var body: some View {
        SettingsRow(label: label, note: note, isFirst: isFirst) {
            Picker(selection: $selection, content: options) { Text(label) }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(StrandPalette.accent)
        }
    }
}

/// A row that pushes another screen.
struct SettingsLinkRow<Destination: View>: View {
    let label: LocalizedStringKey
    var icon: String?
    var value: String?
    var isFirst = false
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            SettingsChevronLabel(label: label, icon: icon, value: value)
        }
        .buttonStyle(.plain)
        .listCardRow(isFirst: isFirst)
    }
}

/// A row that runs an action (opens a sheet, exports a file) and reads like a link.
struct SettingsActionRow: View {
    let label: LocalizedStringKey
    var icon: String?
    var value: String?
    var isFirst = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsChevronLabel(label: label, icon: icon, value: value)
        }
        .buttonStyle(.plain)
        .listCardRow(isFirst: isFirst)
    }
}

/// Shared label for link and action rows: optional glyph, title, trailing value, chevron.
struct SettingsChevronLabel: View {
    let label: LocalizedStringKey
    var icon: String?
    var value: String?

    var body: some View {
        HStack(spacing: ZoopSpacing.m) {
            if let icon {
                Image(systemName: icon)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: ZoopSpacing.s)
            if let value {
                Text(verbatim: value)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(ZoopType.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

/// One alert shape for every page's outcome messages (backup, export, app icon).
struct SettingsNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension View {
    func settingsNoticeAlert(_ notice: Binding<SettingsNotice?>) -> some View {
        alert(notice.wrappedValue?.title ?? "", isPresented: Binding(
            get: { notice.wrappedValue != nil },
            set: { if !$0 { notice.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(notice.wrappedValue?.message ?? "")
        }
    }
}
