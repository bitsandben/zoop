#if !os(watchOS)
// Excluded on watchOS (no DatePicker(.graphical) / .popover there).
import SwiftUI

// MARK: - DayNavBar: chevron + date-jump day selector
//
// The Today day navigator: ◀ older / ▶ newer chevrons (▶ disabled at today), and a centre block showing
// the selected day that opens a graphical DatePicker capped at today. Offset is days-back-from-today (0 = today).

public struct DayNavBar: View {
    /// `standard` is the full-width navigator with a date block; `pill` is the compact capsule for the iPhone Home header.
    public enum Style: Sendable { case standard, pill }

    private let selectedOffset: Int
    private let today: Date
    private let style: Style
    private let onSelect: (Int) -> Void

    @State private var showingPicker = false
    @Environment(\.locale) private var locale

    /// `today` is the caller's LOGICAL day (rolls at 04:00); passed in rather than read from `Date()`, which
    /// already reads the next calendar day in the 00:00-04:00 window (#14).
    public init(selectedOffset: Int, today: Date, style: Style = .standard, onSelect: @escaping (Int) -> Void) {
        self.selectedOffset = selectedOffset
        self.today = today
        self.style = style
        self.onSelect = onSelect
    }

    /// The calendar day the current offset resolves to, counting back from the logical day.
    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: -selectedOffset, to: today) ?? today
    }

    private var canGoNewer: Bool { selectedOffset > 0 }

    private var label: LocalizedStringKey {
        switch selectedOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let formattedDay = selectedDay.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)
            )
            return LocalizedStringKey(formattedDay)
        }
    }

    public var body: some View {
        switch style {
        case .standard: standardBody
        case .pill: pillBody
        }
    }

    private var pillBody: some View {
        HStack(spacing: 0) {
            Button { onSelect(selectedOffset + 1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 34, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Previous day", bundle: .module))

            Button { showingPicker = true } label: {
                Text(label, bundle: .module)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 20)
                    .frame(minWidth: 104, minHeight: 36)
                    .background(Capsule().fill(StrandPalette.surfaceBase))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Pick a date", bundle: .module))
            .popover(isPresented: $showingPicker) {
                datePickerPopover
            }

            Button { if canGoNewer { onSelect(selectedOffset - 1) } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canGoNewer ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                    .frame(width: 34, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNewer)
            .accessibilityLabel(Text("Next day", bundle: .module))
        }
        .padding(4)
        .background(Capsule().fill(StrandPalette.surfaceRaised))
    }

    private var standardBody: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button { onSelect(selectedOffset + 1) } label: {
                Image(systemName: "chevron.left")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 44, height: 44)        // ≥44pt hit target (HIG); glyph stays 17pt
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Previous day", bundle: .module))

            // Centre block: the selected day's label + date, tappable to jump.
            Button { showingPicker = true } label: {
                VStack(spacing: 2) {
                    Text(label, bundle: .module)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    // On today the label already reads "Today", so the full date shows only on other days.
                    if selectedOffset > 0 {
                        Text(selectedDay.formatted(
                            .dateTime.day().month(.abbreviated).year().locale(locale)
                        ))
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.accent)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 20)
                // Flat card fill, not a black bar: the full-width pill sits over the bright day-scene on macOS.
                .background(blockFill, in: blockShape)
                .overlay(blockShape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Pick a date", bundle: .module))
            .popover(isPresented: $showingPicker) {
                datePickerPopover
            }

            Button { if canGoNewer { onSelect(selectedOffset - 1) } } label: {
                Image(systemName: "chevron.right")
                    .font(StrandFont.headline)
                    .foregroundStyle(canGoNewer ? StrandPalette.accent : StrandPalette.textTertiary)
                    .frame(width: 44, height: 44)        // ≥44pt hit target (HIG); glyph stays 17pt
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoNewer)
            .accessibilityLabel(Text("Next day", bundle: .module))
            Spacer(minLength: 0)
        }
    }

    /// Graphical date jump capped at today; the chosen date converts back to a whole-day offset.
    private var datePickerPopover: some View {
        let pickedBinding = Binding<Date>(
            get: { selectedDay },
            set: { newValue in
                let cal = Calendar.current
                let start = cal.startOfDay(for: newValue)
                // Offset is measured from the LOGICAL day, so a date picked in 00:00-04:00 maps to the offset the labels count from (#14).
                let anchor = cal.startOfDay(for: today)
                let days = cal.dateComponents([.day], from: start, to: anchor).day ?? 0
                onSelect(max(0, days))
                showingPicker = false
            }
        )
        return DatePicker("", selection: pickedBinding, in: ...today, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
            // iPad popover needs an explicit size or the graphical picker clips (#840).
            .frame(minWidth: 320, minHeight: 360)
            #if os(iOS)
            // iPhone: compact popover under the day pill instead of a full-height sheet.
            .tint(StrandPalette.accent)
            .modifier(CompactPopoverOnPhone())
            #endif
    }

    private var blockShape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    /// Fill for the centre day block: raised card fill on macOS (the bar spans the bright day-scene); iOS keeps the inset well.
    private var blockFill: Color {
        #if os(macOS)
        // Translucent pill so the scene shows through; white label stays legible at 0.72.
        StrandPalette.surfaceBase.opacity(0.72)
        #else
        StrandPalette.surfaceInset
        #endif
    }

}
#endif

#if os(iOS)
/// Keeps a popover a popover on iPhone (iOS 16.4+), where it otherwise adapts to a sheet.
private struct CompactPopoverOnPhone: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationCompactAdaptation(.popover)
                .presentationBackground(StrandPalette.surfaceRaised)
        } else {
            content
        }
    }
}
#endif
