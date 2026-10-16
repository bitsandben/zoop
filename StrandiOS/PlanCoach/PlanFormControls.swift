import SwiftUI
import StrandDesign

// The small controls of the native plan / routine form: wrapping chips, single or multi select, and
// the weekday toggles. Flat surfaces and design tokens only.

/// Lays its children out left to right and wraps to the next line.
struct ChipFlow: Layout {
    var spacing: CGFloat = ZoopSpacing.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// One selectable option.
struct FormChip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ZoopType.caption.weight(.medium))
                .foregroundStyle(on ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(on ? StrandPalette.accent : StrandPalette.surfaceBase))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// A group of chips. `single` keeps exactly one selected; otherwise taps toggle.
struct FormChipGroup: View {
    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
    }

    let options: [Option]
    @Binding var selection: Set<String>
    var single = false
    /// Called after a tap with the tapped id, for exclusive options ("no equipment").
    var onToggle: ((String) -> Void)?

    var body: some View {
        ChipFlow {
            ForEach(options) { option in
                FormChip(title: option.label, on: selection.contains(option.id)) {
                    if single {
                        selection = [option.id]
                    } else if selection.contains(option.id) {
                        selection.remove(option.id)
                    } else {
                        selection.insert(option.id)
                    }
                    onToggle?(option.id)
                }
            }
        }
    }
}

/// Seven weekday circles in the locale's week order.
struct FormWeekdays: View {
    @Binding var selected: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LiftProgramPlanSheet.orderedWeekdays, id: \.self) { day in
                let on = selected.contains(day)
                Button {
                    if on { selected.remove(day) } else { selected.insert(day) }
                } label: {
                    Text(PlanFormat.shortWeekday(day).prefix(2))
                        .font(ZoopType.caption.weight(.semibold))
                        .foregroundStyle(on ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Circle().fill(on ? StrandPalette.accent : StrandPalette.surfaceBase))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PlanFormat.weekday(day))
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// A single free-text field on a raised surface.
struct FormTextField: View {
    let placeholder: String
    @Binding var text: String
    var lines = 1...3

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .font(ZoopType.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(lines)
            .padding(.vertical, 11)
            .padding(.horizontal, ZoopSpacing.l)
            .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous)
                .fill(StrandPalette.surfaceBase))
    }
}
