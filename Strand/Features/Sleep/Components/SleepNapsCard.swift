import SwiftUI
import StrandDesign
import WhoopStore

/// The day's naps: every block outside the main-night group, each editable and deletable through the
/// same editor the night uses, plus a way to add one that was missed.
struct SleepNapsCard: View {
    let naps: [CachedSleepSession]
    let onEdit: (CachedSleepSession) -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.s) {
            HStack {
                SleepSectionTitle(SleepStrings.napsCard)
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(SleepStrings.addNap))
            }
            ListCard {
                ForEach(Array(naps.enumerated()), id: \.element.startTs) { index, nap in
                    row(nap).listCardRow(isFirst: index == 0)
                }
            }
        }
    }

    private func row(_ nap: CachedSleepSession) -> some View {
        Button { onEdit(nap) } label: {
            HStack(spacing: ZoopSpacing.m) {
                Image(systemName: "powersleep")
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(Night.clockString(nap.effectiveStartTs)) – \(Night.clockString(nap.endTs))")
                        .font(ZoopType.body.monospacedDigit())
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(verbatim: SleepReadouts.durationText(seconds: Double(nap.endTs - nap.effectiveStartTs)))
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: ZoopSpacing.s)
                Image(systemName: nap.userEdited ? "pencil.circle.fill" : "pencil.circle")
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(SleepStrings.editNap))
    }
}

/// The transient strip after a delete, with a real Undo button.
struct SleepUndoBanner: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: ZoopSpacing.m) {
            Text(verbatim: message)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: ZoopSpacing.s)
            Button(action: onUndo) {
                Text("Undo").font(ZoopType.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(minHeight: 44)
            .accessibilityLabel("Undo sleep deletion")
        }
        .padding(.horizontal, ZoopSpacing.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ZoopRadius.tile, style: .continuous).fill(StrandPalette.surfaceRaised))
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }
}
