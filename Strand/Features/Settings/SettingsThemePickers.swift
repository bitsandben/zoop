#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign

/// The Design choice (Classic / Pastel & Nature) as two preview tiles. Read by the iOS root's
/// `.zoopTheme`, so the whole app re-skins on tap.
struct SettingsDesignPicker: View {
    @AppStorage(ZoopTheme.storageKey) private var themeRaw = ZoopTheme.classic.rawValue
    /// The tile shown as selected. Held as view state as well, because after a light/dark switch the
    /// in-place theme change did not always re-render this view from the `@AppStorage` write alone.
    @State private var shown: ZoopTheme?

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text("Design").font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: ZoopSpacing.m) {
                ForEach(ZoopTheme.allCases) { theme in tile(theme) }
            }
        }
    }

    private func tile(_ theme: ZoopTheme) -> some View {
        let selected = (shown ?? ZoopTheme.resolve(themeRaw)) == theme
        let shape = RoundedRectangle(cornerRadius: ZoopRadius.button, style: .continuous)
        return Button {
            shown = theme
            withAnimation(.easeInOut(duration: 0.2)) { themeRaw = theme.rawValue }
        } label: {
            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                HStack(spacing: -6) {
                    ForEach(Array(theme.swatches.enumerated()), id: \.offset) { _, color in
                        Circle().fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    }
                }
                Text(theme.label)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(ZoopSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(StrandPalette.surfaceInset))
            .overlay(shape.strokeBorder(selected ? StrandPalette.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(theme.label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The alternate app icon as a row of thumbnails.
struct SettingsAppIconPicker: View {
    /// The alternate-icon set name, "" for the primary icon. Mirrors what iOS shows; the switch itself
    /// goes through `setAlternateIconName`.
    @AppStorage("appIcon.name") private var appIconName = ""
    @State private var notice: SettingsNotice?

    private struct Option: Identifiable {
        let iconName: String?
        let thumbnail: String
        let label: LocalizedStringKey
        var id: String { iconName ?? "" }
    }

    /// The light icon keeps its old "AppIcon-Navy" asset name so a saved choice still resolves.
    private static let options: [Option] = [
        Option(iconName: nil, thumbnail: "ZoopDefault", label: "Default"),
        Option(iconName: "AppIcon-Navy", thumbnail: "ZoopLight", label: "appIcon.light"),
        Option(iconName: "AppIcon-PastelLight", thumbnail: "PastelLight", label: "Pastel light"),
        Option(iconName: "AppIcon-PastelDark", thumbnail: "PastelDark", label: "Pastel dark"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            Text("App icon").font(ZoopType.body).foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .top, spacing: ZoopSpacing.s) {
                ForEach(Self.options) { option in thumbnail(option) }
            }
        }
        // Also migrates the old on/off "appIcon.alt" preference to the real current icon.
        .onAppear { appIconName = UIApplication.shared.alternateIconName ?? "" }
        .settingsNoticeAlert($notice)
    }

    private func thumbnail(_ option: Option) -> some View {
        let selected = appIconName == option.id
        let inner = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return Button { select(option.iconName) } label: {
            VStack(spacing: ZoopSpacing.xs) {
                Group {
                    if let image = UIImage(named: option.thumbnail) {
                        Image(uiImage: image).resizable()
                    } else {
                        StrandPalette.surfaceInset
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(inner)
                .overlay(inner.strokeBorder(StrandPalette.hairline, lineWidth: 1))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? StrandPalette.accent : .clear, lineWidth: 2))
                Text(option.label)
                    .font(ZoopType.caption)
                    .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(option.label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// On failure the choice reverts, so the picker never disagrees with the Home Screen.
    private func select(_ target: String?) {
        let previous = appIconName
        appIconName = target ?? ""
        Task { @MainActor in
            // Skipping a no-op avoids a needless system prompt.
            guard UIApplication.shared.supportsAlternateIcons,
                  UIApplication.shared.alternateIconName != target else { return }
            do {
                try await UIApplication.shared.setAlternateIconName(target)
            } catch {
                appIconName = previous
                notice = SettingsNotice(title: String(localized: "Couldn't change the app icon"),
                                        message: error.localizedDescription)
            }
        }
    }
}
#endif
