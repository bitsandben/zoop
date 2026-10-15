import SwiftUI
import StrandDesign

// MARK: - Design Gallery (Test Centre › Design gallery)
//
// Every StrandDesign token, component and page template in all of its states, on one screen, with a
// local theme (Classic / Pastel) and appearance (System / Light / Dark) switch. The reference for
// docs/zoop2/DESIGN-SYSTEM.md: when a component changes, it should look right here in all four looks.
//
// The theme switch is a TEMPORARY override of `ZoopTheme.current` (the token providers read that
// global), re-keyed locally so the gallery re-resolves; the saved app theme is restored on leave.
// Screens pushed from here (templates) render in the overridden theme but the system appearance.
// Debug tool: English copy, verbatim (not in the catalogue).

struct DesignGalleryScreen: View {
    static let title = "Design gallery"

    enum Page: String, CaseIterable, Identifiable {
        case foundations = "Tokens", components = "Components", metrics = "Metrics", templates = "Templates"
        var id: String { rawValue }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system = "System", light = "Light", dark = "Dark"
        var id: String { rawValue }
        var scheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    @Environment(\.colorScheme) private var systemScheme
    @State private var theme: ZoopTheme = ZoopTheme.current
    @State private var appearance: Appearance = .system
    @State private var page: Page = .foundations
    @State private var renderToken = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
                controls
                switch page {
                case .foundations: DesignGalleryFoundations()
                case .components: DesignGalleryComponents()
                case .metrics: DesignGalleryMetrics()
                case .templates: DesignGalleryTemplates()
                }
            }
            .padding(.horizontal, ZoopSpacing.gutter)
            .padding(.top, ZoopSpacing.s)
            .padding(.bottom, ZoopSpacing.xxl + ZoopMetrics.tabBarClearance)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .environment(\.colorScheme, appearance.scheme ?? systemScheme)
        // Sets `ZoopTheme.current` during body evaluation (before anything draws) and re-keys on it.
        .zoopTheme(theme.rawValue)
        .id(renderToken)
        .zoopPushedScreen(title: .gallery(Self.title))
        #if os(iOS)
        .toolbarColorScheme(appearance.scheme, for: .navigationBar)
        #endif
        .onAppear {
            ZoopTheme.current = theme
            renderToken &+= 1
        }
        .onDisappear {
            ZoopTheme.current = ZoopTheme.resolve(UserDefaults.standard.string(forKey: ZoopTheme.storageKey) ?? "")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.m) {
            Picker(selection: themeBinding) {
                ForEach(ZoopTheme.allCases) { Text(verbatim: $0.label).tag($0) }
            } label: { Text.gallery("Theme") }
            Picker(selection: $appearance) {
                ForEach(Appearance.allCases) { Text(verbatim: $0.rawValue).tag($0) }
            } label: { Text.gallery("Appearance") }
            Picker(selection: $page) {
                ForEach(Page.allCases) { Text(verbatim: $0.rawValue).tag($0) }
            } label: { Text.gallery("Page") }
        }
        .pickerStyle(.segmented)
    }

    /// Writes the global before the state change re-renders, so no view resolves the old theme.
    private var themeBinding: Binding<ZoopTheme> {
        Binding(get: { theme }, set: { ZoopTheme.current = $0; theme = $0 })
    }
}

// MARK: - Debug copy
//
// The gallery is a developer tool reached from Test Centre: its copy is English on purpose and stays
// out of the catalogue. These helpers make that explicit, so the i18n gate does not read the sample
// copy as product copy.

extension Text {
    static func gallery(_ text: String) -> Text { Text(verbatim: text) }
}

extension LocalizedStringKey {
    static func gallery(_ text: String) -> LocalizedStringKey { LocalizedStringKey(text) }
}

/// Sample copy that would otherwise sit inside a copy-carrying call (button titles, card titles).
enum GalleryCopy {
    static let primary = "Primary · Start fast"
    static let secondary = "Secondary · Log workout"
    static let tertiary = "Tertiary · Not now"
    static let destructive = "Destructive · Delete night"
    static let disabled = "Disabled"
    static let fullWidth = "Full width"
    static let hrvChart = "HRV · 30 days"
    static let strainChart = "Strain · 7 days"
    static let hrvChartA11y = "HRV, last 30 days"
    static let insideCard = "Inside an existing card"
    static let settingsTitle = "Settings template"
    static let clock24 = "24-hour clock"
    static let version = "Version"
    static let limitations = "Limitations"
}

// MARK: - Shared gallery pieces

/// A gallery section: header plus content, 8 pt between them.
struct GallerySection<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            ZoopSectionHeader(LocalizedStringKey(title), subtitle: note.map { LocalizedStringKey($0) })
            content()
        }
    }
}

/// A caption naming the token or state shown above or beside it.
struct GalleryCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(ZoopType.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Rows in a `ListCard`, separated by hairlines. For views that already carry their own row padding
/// (`MetricRow`), where `listCardRow()` would double it.
struct GalleryRows<Item, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        ListCard {
            ForEach(items.indices, id: \.self) { index in
                if index > 0 { Rectangle().fill(StrandPalette.hairline).frame(height: ZoopMetrics.hairlineWidth) }
                row(items[index])
            }
        }
    }
}
