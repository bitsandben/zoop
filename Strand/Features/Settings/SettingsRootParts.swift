import SwiftUI
import StrandDesign

/// The two blocks that open the Settings root: who you are (profile + paired strap) and how the app
/// looks (design, light/dark, icon). Both sit above the page list so the most personal choices need no
/// drill-down.

/// Profile card: photo, name, a one-line body summary and the strap status. Tapping it opens the
/// profile page.
struct SettingsProfileHeader: View {
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var live: LiveState
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    var body: some View {
        NavigationLink(value: SettingsPage.profile) {
            HStack(spacing: ZoopSpacing.m) {
                ProfileAvatarView(imageData: profile.avatarImageData, size: ZoopMetrics.profileAvatarDiameter)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ZoopSpacing.xs) {
                    displayName
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: summary)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: ZoopSpacing.xs) {
                        Circle().fill(statusColor).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(verbatim: live.connectionStatusLabel)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: ZoopSpacing.s)
                Image(systemName: "chevron.right")
                    .font(ZoopType.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(ZoopSpacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ZoopRadius.card, style: .continuous)
                .fill(StrandPalette.surfaceRaised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("zoop.settings.profile.header.hint"))
    }

    private var displayName: Text {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Text("zoop.settings.profile.unnamed") : Text(verbatim: trimmed)
    }

    /// "34 · Male · 180 cm · 75 kg", in the unit system the user picked.
    private var summary: String {
        let imperial = UnitSystem(rawValue: unitSystemRaw) == .imperial
        let sex: String
        switch profile.sex {
        case "female": sex = String(localized: "Female")
        case "nonbinary": sex = String(localized: "Non-binary")
        default: sex = String(localized: "Male")
        }
        let height: String
        let weight: String
        if imperial {
            let inches = Int((profile.heightCm / 2.54).rounded())
            height = "\(inches / 12)′\(inches % 12)″"
            weight = "\(Int((profile.weightKg * 2.20462).rounded())) lb"
        } else {
            height = "\(Int(profile.heightCm.rounded())) cm"
            weight = "\(Int(profile.weightKg.rounded())) kg"
        }
        return [String(profile.age), sex, height, weight].joined(separator: " · ")
    }

    private var statusColor: Color {
        if live.connectionStatusIsActive { return StrandPalette.statusPositive }
        if live.connectionStatusIsIdle { return StrandPalette.statusWarning }
        return StrandPalette.statusCritical
    }
}

/// Appearance block: Design tiles, light/dark and (iOS) the app icon, directly in the root.
struct SettingsLookBlock: View {
    /// Light / Dark / System, read by both app roots' `.preferredColorScheme`.
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        SettingsGroup(title: "zoop.settings.look.title") {
            #if os(iOS)
            SettingsDesignPicker().listCardRow(isFirst: true)
            #endif
            // "Theme" reads as "Design" in German, which the picker above owns; this is only light/dark.
            SettingsMenuRow(label: "appearance.mode", selection: $appearanceRaw, isFirst: !Self.hasDesignPicker) {
                ForEach(AppearanceMode.allCases) { mode in Text(mode.label).tag(mode.rawValue) }
            }
            #if os(iOS)
            SettingsAppIconPicker().listCardRow()
            #endif
        }
    }

    private static var hasDesignPicker: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}
