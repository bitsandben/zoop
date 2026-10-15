import SwiftUI
import StrandDesign

// MARK: - Terms acknowledgement (clickwrap body)
//
// One view for both places the terms are accepted: step 2 of onboarding for a new install, and the
// standalone `TermsGateView` when an existing user meets a new `Terms.currentVersion`. The wording is
// `Terms.points` / `Terms.attestations` unchanged (it is the legal text, English keys are binding);
// only the presentation is shared here.

struct TermsAcknowledgement: View {
    /// One flag per `Terms.attestations` entry. Never pre-checked: each tick is a separate consent.
    @Binding var checks: [Bool]

    static func allAccepted(_ checks: [Bool]) -> Bool {
        checks.count == Terms.attestations.count && checks.allSatisfy { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.sectionGap) {
            ListCard {
                ForEach(Array(Terms.points.enumerated()), id: \.offset) { index, point in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(point.0)
                            .font(ZoopType.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(point.1)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .listCardRow(isFirst: index == 0)
                }
            }

            VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                Text("zoop.onboarding.terms.confirm")
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                ListCard {
                    ForEach(Array(Terms.attestations.enumerated()), id: \.offset) { index, line in
                        attestationRow(index: index, line: line)
                            .listCardRow(isFirst: index == 0)
                    }
                }
            }

            Text("The full terms are in TERMS.md, shipped with Zoop. This is not legal advice.")
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A tick box rather than a switch: a consent reads as something you sign, not a setting.
    private func attestationRow(index: Int, line: String) -> some View {
        let on = index < checks.count && checks[index]
        return Button {
            guard index < checks.count else { return }
            checks[index].toggle()
        } label: {
            HStack(alignment: .top, spacing: ZoopSpacing.m) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(ZoopType.headline)
                    .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text(line)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
