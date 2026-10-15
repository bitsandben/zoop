import SwiftUI

// MARK: - The locked component system
//
// Screens compose ONLY these: fixed dimensions plus one spacing scale. Do not invent ad-hoc cards.

public enum ZoopMetrics {
    public static let cardRadius: CGFloat = ZoopVisualStyle.cardRadius
    public static let cardPadding: CGFloat = ZoopVisualStyle.cardPadding
    public static let gap: CGFloat = ZoopVisualStyle.itemGap
    public static let sectionGap: CGFloat = ZoopVisualStyle.sectionGap
    public static let screenPadding: CGFloat = ZoopVisualStyle.pagePadding
    public static let tileHeight: CGFloat = 96   // Design Reset: tighter metric tile
    // Key Metrics grid: one fixed height every tile snaps to (clears value + inline sparkline + caption);
    // `maxHeight: .infinity` can't equalise them inside a LazyVGrid, which only offers content height.
    public static let keyMetricTileHeight: CGFloat = 122
    public static let chartHeight: CGFloat = 220
    /// Minimum macOS detail-sheet footprint for a scrollable editor/history surface.
    public static let detailSheetMinWidth: CGFloat = 520
    public static let detailSheetMinHeight: CGFloat = 620
    /// Compact provenance-chip height; shared with overlays that align the chip to a border.
    public static let sourceBadgeHeight: CGFloat = 18
    public static let hypnogramBandMinThickness: CGFloat = 14  // floor so short stages read as bars, not ticks
    public static let tabBarClearance: CGFloat = 76  // iOS: extra bottom scroll room so the last card clears the floating tab bar
    /// Diameter for compact circular controls in dense header chrome.
    public static let compactControlSize: CGFloat = 36
    /// Expanded width of the compact charge-to-sync status capsule.
    public static let syncIndicatorExpandedWidth: CGFloat = 108
    /// Optical space between the sync ring and its transient label.
    public static let syncIndicatorLabelSpacing: CGFloat = 5
    /// Smallest readable scale for long localized labels inside the sync capsule.
    public static let syncIndicatorMinimumLabelScale: CGFloat = 0.72
    /// Even inset around the sync control before exact-bounds Liquid Glass, matching the system's `.small` glass chrome.
    public static let syncIndicatorGlassPadding: CGFloat = 5
    /// Inset for the indicator's ring in BOTH states: battery arc and spinner share one radius so the morph does not resize.
    public static let syncIndicatorArcInset: CGFloat = 2.5
    /// Width of the soft fade where long header text passes beneath trailing controls.
    public static let headerTextFadeWidth: CGFloat = 48
    /// Starting guess for the trailing header-control footprint, used ONLY until the host measures its own
    /// cluster (see `headerTrailingControlFadeMask(reserving:)`); deliberately not a fixed budget.
    public static let headerControlReserveWidth: CGFloat = 168

    // MARK: Standardised spacing scale (the ONE source of truth for margins)
    //
    // A 4pt-based ramp; `cardPadding` (16) is an alias of `space4`.
    public static let space1:  CGFloat = 4
    /// Optical separation for paired labels; structural layout still follows the 4-point ramp.
    public static let spaceHalf: CGFloat = 2
    public static let space2:  CGFloat = 8
    public static let space3:  CGFloat = 12
    public static let space4:  CGFloat = 16
    public static let space5:  CGFloat = 20
    public static let space6:  CGFloat = 24
    public static let space8:  CGFloat = 32
    public static let space10: CGFloat = 40

    // MARK: Named layout constants
    /// Horizontal page margin (screen gutter). Use via `.screenPadding()`.
    public static let screenHPadding: CGFloat = ZoopVisualStyle.pagePadding
    /// Vertical gap between top-level page sections.
    public static let sectionSpacing: CGFloat = ZoopVisualStyle.sectionGap
    /// Interior padding inside a card's content (matches `cardPadding`).
    public static let cardInnerPadding: CGFloat = 16
    /// Vertical gap between stacked elements INSIDE a card.
    public static let cardInnerSpacing: CGFloat = 12
    /// Vertical gap between rows in a list-style card.
    public static let rowSpacing: CGFloat = 10
    /// Standard interactive-control height (buttons, fields, segmented controls).
    public static let controlHeight: CGFloat = 48
    /// One-pixel edge used by cards and compact controls.
    public static let hairlineWidth: CGFloat = 1
    /// Profile form dimensions shared by avatar and numeric controls.
    public static let profileAvatarDiameter: CGFloat = 44
    public static let formValueColumnWidth: CGFloat = 48
    public static let formWideValueColumnWidth: CGFloat = 64
    /// Compact metadata and explanatory-footer heights.
    public static let compactMetadataMinHeight: CGFloat = 24
    public static let compactHintMinHeight: CGFloat = 18
    /// Thickness for compact horizontal indicator tracks.
    public static let indicatorTrackHeight: CGFloat = 8
    /// Fully-rounded corner radius — pills, chips, capsule buttons.
    public static let pillRadius: CGFloat = ZoopVisualStyle.pillRadius
    /// Minimum desktop size for a navigation-based customization sheet.
    public static let editorSheetMinWidth: CGFloat = 440
    public static let editorSheetMinHeight: CGFloat = 600
}

// MARK: - Screen padding

public extension View {
    /// Applies the canonical horizontal page gutter (`ZoopMetrics.screenHPadding`).
    func screenPadding() -> some View {
        self.padding(.horizontal, ZoopMetrics.screenHPadding)
    }
}

// MARK: - iOS sheet presentation idiom

#if os(iOS)
public extension View {
    /// The house iOS sheet idiom: drag indicator plus detents (iOS only; macOS sheets are windows).
    /// `largeFirst == false` opens at .medium with .large reachable; `true` opens full-height.
    @ViewBuilder
    func noopSheetPresentation(largeFirst: Bool) -> some View {
        // Zoop: sheets stop at about three quarters of the screen; long ones can be pulled to full height.
        let sized = self
            .presentationDragIndicator(.visible)
            .presentationDetents(largeFirst ? [.fraction(0.75), .large] : [.medium, .fraction(0.75)])
        sized.opaqueSheetBackground()
    }
}
#endif

public extension View {
    /// An opaque sheet background in the base surface instead of the iOS 26 glass default, which
    /// re-refracts the screen on every frame while resizing (stutter). No-op on macOS.
    @ViewBuilder func opaqueSheetBackground() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationBackground(StrandPalette.surfaceBase) } else { self }
        #else
        self
        #endif
    }

    /// Keeps a small explainer a popover on iPhone instead of growing into a full-screen sheet. No-op on macOS.
    @ViewBuilder func compactPopover() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }
}

// MARK: - Surface

/// The one card surface: the frosted card with optional per-domain accent `tint`.
public struct ZoopCard<Content: View>: View {
    private let padding: CGFloat
    private let tint: Color?
    @ViewBuilder private let content: () -> Content
    #if os(macOS)
    @State private var hover = false
    #endif
    public init(padding: CGFloat = ZoopMetrics.cardPadding, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.tint = tint; self.content = content
    }
    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover chrome lives in the background so its animation is scoped to the surface and never re-animates a chart inside (#104).
            .background { cardSurface }
        #if os(macOS)
            .onHover { hover = $0 }
        #endif
    }

    // Touch can't hover, so iOS renders only the static frosted surface (no hover @State/.onHover/.animation); macOS adds the hover border.
    @ViewBuilder private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: ZoopMetrics.cardRadius, style: .continuous)
        #if os(macOS)
        FrostedCardSurface(tint: tint, cornerRadius: ZoopMetrics.cardRadius)
            .overlay(
                shape.strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1).opacity(hover ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.16), value: hover)
        #else
        FrostedCardSurface(tint: tint, cornerRadius: ZoopMetrics.cardRadius)
        #endif
    }
}

// MARK: - Section header

public struct SectionHeader: View {
    let overline: LocalizedStringKey?; let title: LocalizedStringKey; let trailing: String?
    public init(_ title: LocalizedStringKey, overline: LocalizedStringKey? = nil, trailing: String? = nil) {
        self.title = title; self.overline = overline; self.trailing = trailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                if let overline { Text(overline).strandOverline() }
                Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer()
            if let trailing {
                Text(trailing).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

// MARK: - Metric tile (UNIFORM fixed height)

public struct StatTile<Accessory: View>: View {
    let label: LocalizedStringKey, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent
    /// Optional trailing accessory INLINE in the header row (e.g. an ⓘ), so it can never sit on top of the value or sparkline on a narrow tile (#495).
    @ViewBuilder var accessory: () -> Accessory

    public init(label: LocalizedStringKey, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
        self.accessory = accessory
    }

    public var body: some View {
        // The tile borrows its accent as a faint card wash.
        ZoopCard(padding: 14, tint: accent) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row: label plus the optional accessory, in flow so it reserves its own space.
                HStack(alignment: .top, spacing: 4) {
                    Text(label).strandOverline()
                    Spacer(minLength: 0)
                    accessory()
                }
                Spacer(minLength: 4)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    #if os(iOS)
                    Text(value).font(.system(size: 24, weight: .bold)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6)
                    #else
                    Text(value).font(StrandFont.number(26)).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.6)
                    #endif
                    Spacer(minLength: 0)
                    if let delta { TrendChip(text: delta, color: deltaColor) }
                }
                // Sparkline needs chart-hover helpers, unavailable on watchOS.
                #if !os(watchOS)
                if let sparkline, sparkline.count > 1 {
                    Sparkline(values: sparkline, gradient: Gradient(colors: [sparkColor.opacity(0.5), sparkColor]))
                        .frame(height: 22).padding(.top, 4)
                        .accessibilityHidden(true)
                }
                #endif
                if let caption {
                    Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
                        .padding(.top, 2)
                }
            }
        }
        // A FLOOR, not a fixed height: sparkline tiles must grow rather than clip. `maxHeight: .infinity` lets a
        // caller that hands a bounded height (Key Metrics grid) stretch it; in a LazyVGrid equal heights come from the caller.
        .frame(minHeight: ZoopMetrics.tileHeight, maxHeight: .infinity)
        // One VoiceOver stop per tile; the decorative sparkline is hidden.
        .accessibilityElement(children: .combine)
    }
}

// Convenience: a StatTile with NO accessory (`Accessory` defaults to `EmptyView`).
public extension StatTile where Accessory == EmptyView {
    init(label: LocalizedStringKey, value: String, caption: String? = nil,
         accent: Color = StrandPalette.textPrimary, delta: String? = nil,
         deltaColor: Color = StrandPalette.textTertiary,
         sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent) {
        self.init(label: label, value: value, caption: caption, accent: accent, delta: delta,
                  deltaColor: deltaColor, sparkline: sparkline, sparkColor: sparkColor,
                  accessory: { EmptyView() })
    }
}

// MARK: - Trend chip

/// A compact trend pill: up/down/flat arrow plus delta text, tinted to `color`. Direction comes from a leading +/− (else flat).
public struct TrendChip: View {
    let text: String
    var color: Color = StrandPalette.textTertiary
    public init(text: String, color: Color = StrandPalette.textTertiary) {
        self.text = text; self.color = color
    }
    private var symbol: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") || t.hasPrefix("▲") || t.lowercased().hasPrefix("up") { return "arrow.up.right" }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasPrefix("▼") || t.lowercased().hasPrefix("down") { return "arrow.down.right" }
        // No sign means a plain magnitude (e.g. "874 kcal"), not a trend: show NO direction glyph (#41).
        return nil
    }
    public var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            // One line: a long chip truncates rather than wraps, so it never grows a tile past its floor (#934).
            Text(text).font(StrandFont.captionNumber).lineLimit(1)
        }
        // Plain tinted text, no pill.
        .foregroundStyle(color)
        .accessibilityHidden(true)
    }
}

// MARK: - Chart card (header + fixed chart body + footer)

public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = ZoopMetrics.chartHeight
    var tint: Color? = nil
    /// Draws a small chevron after the title, for a card that opens a page.
    var showsChevron: Bool = false
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: LocalizedStringKey, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = ZoopMetrics.chartHeight, tint: Color? = nil, showsChevron: Bool = false,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.tint = tint; self.showsChevron = showsChevron
        self.chart = chart; self.footer = footer
    }

    public var body: some View {
        ZoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(title).strandOverline()
                            if showsChevron {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .accessibilityHidden(true)
                            }
                        }
                        if let subtitle { Text(subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    Spacer()
                    if let trailing { Text(trailing).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary) }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    Divider().overlay(StrandPalette.hairline)
                    f
                }
            }
        }
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(LocalizedStringKey, String)]
    public init(_ items: [(LocalizedStringKey, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).textCase(.uppercase).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey
    var statusColor: Color = StrandPalette.accent
    var tint: Color? = nil
    /// Extra trailing inset on the overline + status rows so a caller's top-trailing overlay doesn't run over the title (#69). Defaults to 0.
    var titleTrailingInset: CGFloat = 0
    public init(category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey, statusColor: Color = StrandPalette.accent, tint: Color? = nil, titleTrailingInset: CGFloat = 0) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor; self.tint = tint; self.titleTrailingInset = titleTrailingInset
    }
    public var body: some View {
        // Card wash defaults to the status colour so the coaching card sits in the score's colour world.
        let hue = tint ?? statusColor
        // Flat card; identity comes from the coloured status headline alone.
        return ZoopCard(padding: 18, tint: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text(category).strandOverline()
                    .padding(.trailing, titleTrailingInset)
                Text(status).font(StrandFont.rounded(28, weight: .bold)).foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, titleTrailingInset)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Range control (the ONE segmented pill control)

public struct SegmentedPillControl<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    /// When requested, keeps the intrinsic control where it fits and falls back to equal-width segments on
    /// compact screens, so long option sets cannot widen a page beyond the viewport.
    let adaptsToAvailableWidth: Bool
    /// Per-segment availability (#943): a disabled segment stays visible but renders extra-dim and ignores taps. Defaults to all enabled.
    let isEnabled: (T) -> Bool
    let fillsAvailableWidth: Bool
    @Binding var selection: T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                label: @escaping (T) -> String) {
        self.init(items, selection: selection, adaptsToAvailableWidth: adaptsToAvailableWidth,
                  fillsAvailableWidth: fillsAvailableWidth,
                  isEnabled: { _ in true }, label: label)
    }
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                isEnabled: @escaping (T) -> Bool,
                label: @escaping (T) -> String) {
        self.items = items
        self._selection = selection
        self.adaptsToAvailableWidth = adaptsToAvailableWidth
        self.fillsAvailableWidth = fillsAvailableWidth
        self.isEnabled = isEnabled
        self.label = label
    }
    @ViewBuilder
    public var body: some View {
        if fillsAvailableWidth {
            track(equalWidth: true)
        } else if adaptsToAvailableWidth {
            if dynamicTypeSize > .large {
                ScrollView(.horizontal, showsIndicators: false) {
                    track(equalWidth: false)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    track(equalWidth: false)
                    track(equalWidth: true)
                }
            }
        } else {
            track(equalWidth: false)
        }
    }

    private func track(equalWidth: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let sel = item == selection
                let enabled = isEnabled(item)
                Button {
                    guard selection != item else { return }   // re-tapping the active segment stays silent
                    StrandHaptic.selection.play()
                    withAnimation(StrandMotion.interactive) { selection = item }
                } label: {
                    Text(label(item))
                        .font(StrandFont.captionNumber)
                        .lineLimit(equalWidth ? 1 : nil)
                        // Neutral selection so the control works over every metric colour world; disabled segments drop to fainter tertiary.
                        .foregroundStyle(sel ? StrandPalette.textPrimary
                                             : StrandPalette.textTertiary.opacity(enabled ? 1 : 0.35))
                        // Fill the segment height so the selected pill has equal margins to the track on every side.
                        .frame(minWidth: equalWidth ? nil : 26,
                               maxWidth: equalWidth ? .infinity : nil,
                               maxHeight: .infinity)
                        .padding(.horizontal, equalWidth ? ZoopMetrics.space1 : 9)
                        .background {
                            if sel {
                                let selectedShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                                selectedShape
                                    .fill(
                                        LinearGradient(
                                            colors: [ZoopVisualStyle.surfaceTop, ZoopVisualStyle.surface],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .overlay(
                                        selectedShape.strokeBorder(
                                            ZoopVisualStyle.borderHighlight.opacity(0.62),
                                            lineWidth: 0.75
                                        )
                                    )
                                    .shadow(color: StrandPalette.shadow(0.20), radius: 4, x: 0, y: 2)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: equalWidth ? .infinity : nil)
                .frame(height: 32)   // segment height; the pill fills it for an even inset
                .disabled(!enabled)
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(maxWidth: equalWidth ? .infinity : nil)
        .background {
            let trackShape = RoundedRectangle(cornerRadius: 13, style: .continuous)
            trackShape
                .fill(
                    LinearGradient(
                        colors: [ZoopVisualStyle.inset, ZoopVisualStyle.canvas.opacity(0.78)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    trackShape.strokeBorder(
                        LinearGradient(
                            colors: [ZoopVisualStyle.borderHighlight.opacity(0.48), ZoopVisualStyle.border],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                )
        }
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: LocalizedStringKey; var tint: Color = StrandPalette.accent
    public init(_ text: LocalizedStringKey, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        // `.frame(height:)` centres its content, so the label sits mid-capsule for free.
        #if os(iOS)
        // Provenance is a quiet caption, no capsule.
        Text(text).font(.system(size: 12, weight: .medium))
            .frame(height: ZoopMetrics.sourceBadgeHeight)
            .foregroundStyle(StrandPalette.textTertiary)
        #else
        Text(text).textCase(.uppercase).font(.system(size: 10, weight: .semibold, design: .default)).tracking(0.5)
            .padding(.horizontal, 9).frame(height: ZoopMetrics.sourceBadgeHeight)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
            .foregroundStyle(tint)
            .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.34), lineWidth: 1))
        #endif
    }
}

// MARK: - Numeric field helpers (iOS soft-keyboard)

public extension View {
    /// Configures a TextField for number/decimal entry on iOS (decimal pad; no-op on macOS). Pair with
    /// `.keyboardDoneToolbar(...)`, since the decimal pad has no return key.
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad).textContentType(nil)
        #else
        self
        #endif
    }

    /// Adds a trailing "Done" button to the software-keyboard accessory bar that resigns the given focus binding. iOS-only.
    func keyboardDoneToolbar<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = nil }
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - Buttons (Titanium & Gold)
//
// Primary, secondary and ghost button styles reading off the gold tokens; pressed = subtle dim + scale.

/// Primary call-to-action: gold-gradient fill, dark gold-deep ink (700), rounded 13.
public struct ZoopPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(StrandFont.body.weight(.bold))
            .foregroundStyle(ZoopTheme.isPastel ? StrandPalette.primaryButtonText : StrandPalette.goldDeepText)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(ZoopTheme.isPastel
                          ? AnyShapeStyle(StrandPalette.primaryButtonFill)
                          : AnyShapeStyle(LinearGradient(gradient: StrandPalette.goldGradient, startPoint: .topLeading, endPoint: .bottomTrailing)))
            )
            // Subtle neutral elevation, no bloom.
            .shadow(color: StrandPalette.shadow(pressed ? 0.08 : 0.16), radius: 6, x: 0, y: 3)
            .opacity(pressed ? 0.9 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Secondary: inset well + 1px white-12 border + primary text. Quieter than gold.
public struct ZoopSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.surfaceInset))
            .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .opacity(pressed ? 0.82 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Ghost / gold: transparent + 1px gold@.3 hairline + gold text. Tertiary CTA.
public struct ZoopGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return configuration.label
            .font(StrandFont.body.weight(.semibold))
            .foregroundStyle(StrandPalette.gold)
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.gold.opacity(pressed ? 0.10 : 0)))
            .overlay(shape.strokeBorder(StrandPalette.gold.opacity(0.3), lineWidth: 1))
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == ZoopPrimaryButtonStyle {
    /// Gold-gradient primary CTA.
    static var noopPrimary: ZoopPrimaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == ZoopSecondaryButtonStyle {
    /// Inset secondary button.
    static var noopSecondary: ZoopSecondaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == ZoopGhostButtonStyle {
    /// Transparent gold-outline ghost button.
    static var noopGhost: ZoopGhostButtonStyle { .init() }
}

// MARK: - Score state pill (SOLID / BUILDING / CALIBRATING / LIVE)
//
// The score-lifecycle chip: SOLID = gold fill, BUILDING = blue, CALIBRATING = slate, LIVE = gold dot with a pulsing halo.

public enum ScoreState: Sendable, Equatable {
    case solid        // a settled, trustworthy score
    case building     // accruing nights, not yet settled
    case calibrating  // baseline still forming
    case live         // streaming right now

    /// The chip's hue (gold / blue / slate).
    public var color: Color {
        switch self {
        case .solid:        return StrandPalette.statusPositive // settled / trustworthy — WHOOP green
        case .live:         return StrandPalette.accent          // streaming now — WHOOP blue
        case .building:     return StrandPalette.sleepLight   // #4A90E2 blue
        case .calibrating:  return StrandPalette.textTertiary // #8A94A4 slate
        }
    }
    public var label: LocalizedStringKey {
        switch self {
        case .solid:       return "Solid"
        case .building:    return "Building"
        case .calibrating: return "Calibrating"
        case .live:        return "Live"
        }
    }
    var pulsing: Bool { self == .live }
}

/// The score-lifecycle chip: dot, tinted fill and border, hue text. LIVE pulses its dot. `text` overrides the default label.
public struct ScoreStatePill: View {
    public var state: ScoreState
    public var text: LocalizedStringKey?
    public init(_ state: ScoreState, text: LocalizedStringKey? = nil) {
        self.state = state; self.text = text
    }
    public var body: some View {
        #if os(iOS)
        // No lifecycle badges ("Solid", "Building"): they read as decoration, not information.
        EmptyView()
        #else
        pill
        #endif
    }

    private var pill: some View {
        let hue = state.color
        return HStack(spacing: 6) {
            PulseDot(color: hue, pulsing: state.pulsing, size: 7)
            Text(text ?? state.label)
                .font(StrandFont.overline)
                .tracking(0.4)
                .foregroundStyle(hue)
        }
        // Dot and tinted label only, no capsule.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? state.label)
    }
}

/// A small dot with an optional breathing halo (LIVE). Honours Reduce Motion.
private struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in Zoop". The halo is a `repeatForever` loop on screen for long stretches, so it sits behind the same gate as the liquid surfaces.
    @ObservedObject private var motion = ZoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            // Dark mode only: gated explicitly so light mode stays ring-free (the resting dot and shadow carry LIVE there).
            if pulsing && scheme == .dark {
                Circle().fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
                    // No .additiveBloom(): the .plusLighter blend forced an offscreen pass every frame of the pulse.
            }
            Circle().fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.8), radius: pulsing ? 4 : 2)
        }
        .frame(width: size, height: size)
        .onAppear { if pulsing && !poseStill { animate = true } }
        .animation(pulsing && !poseStill ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}
