import SwiftUI
import StrandDesign

// MARK: - Onboarding building blocks
//
// Every step is built from these few pieces so the flow reads as one calm surface: a large title
// with one supporting sentence, then `ListCard`s of rows with an icon in a round well. Type, spacing
// and cards come from the 2.0 tokens (`ZoopType`, `ZoopSpacing`, `ListCard`), so Classic and Pastel
// restyle the flow without a single theme branch here.

/// The frame of one step: title, one sentence, content. Scrolls so Dynamic Type XXL never clips.
struct OnboardingPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ZoopSpacing.xl) {
                VStack(alignment: .leading, spacing: ZoopSpacing.s) {
                    Text(title)
                        .font(ZoopType.title)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(ZoopType.body)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, ZoopSpacing.xl)
        }
        #if os(iOS)
        // #697: a vertical page must not rubber-band sideways on a horizontal swipe.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }
}

/// An SF Symbol in a round well, the concept's icon treatment.
struct OnboardingIconWell: View {
    let icon: String
    var tint: Color = StrandPalette.textPrimary
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: icon)
            .font(ZoopType.headline)
            .foregroundStyle(StrandPalette.icon(tint))
            .frame(width: size, height: size)
            .background(Circle().fill(StrandPalette.surfaceBase))
            .accessibilityHidden(true)
    }
}

/// One explanatory row inside a `ListCard`: icon, title, one sentence.
struct OnboardingInfoRow: View {
    let icon: String
    var tint: Color = StrandPalette.textPrimary
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: ZoopSpacing.m) {
            OnboardingIconWell(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ZoopType.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(message)
                    .font(ZoopType.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A selectable row inside a `ListCard`. The whole row is the hit target; the trailing mark carries
/// the state so selection never depends on colour alone.
struct OnboardingChoiceRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ZoopSpacing.m) {
                OnboardingIconWell(icon: icon, tint: selected ? StrandPalette.accent : StrandPalette.textPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ZoopType.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(ZoopType.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(ZoopType.headline)
                    .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A "label … value" row for read-only facts (strap name, battery, firmware).
struct OnboardingFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(ZoopType.body)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: ZoopSpacing.m)
            Text(value)
                .font(ZoopType.body.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Thin progress line under the top bar. A line rather than "3 / 9" text: the count would change
/// when a step is skipped, the line just jumps.
struct OnboardingProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.surfaceRaised)
                Capsule()
                    .fill(StrandPalette.accent)
                    .frame(width: max(4, geo.size.width * progress))
            }
        }
        .frame(height: 3)
        .animation(StrandMotion.gentle, value: progress)
        .accessibilityHidden(true)
    }
}

/// A small coloured dot plus plain text: the flat status treatment (no tinted capsule).
struct OnboardingStatusLine: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: ZoopSpacing.s) {
            Circle().fill(tint).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text)
                .font(ZoopType.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}
