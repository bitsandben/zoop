import SwiftUI

// MARK: - Domain Theme: per-domain colour worlds
//
// Maps a daily-score domain (Charge / Effort / Rest / Stress) to its accent colour world: a primary
// colour, a deep→bright gradient, and a glow colour. Surfaces read their colours from here.

public enum DomainTheme: String, CaseIterable, Sendable {
    case charge
    case effort
    case rest
    case stress

    public var color: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest:   return StrandPalette.restColor
        case .stress: return StrandPalette.stressColor
        }
    }

    public var deep: Color {
        switch self {
        case .charge: return StrandPalette.chargeDeep
        case .effort: return StrandPalette.effortDeep
        case .rest:   return StrandPalette.restDeep
        case .stress: return StrandPalette.stressDeep
        }
    }

    public var bright: Color {
        switch self {
        case .charge: return StrandPalette.chargeBright
        case .effort: return StrandPalette.effortBright
        case .rest:   return StrandPalette.restBright
        case .stress: return StrandPalette.stressBright
        }
    }

    /// Glow colour for blooms and gauge end-caps.
    public var glow: Color {
        switch self {
        case .charge: return StrandPalette.chargeGlow
        case .effort: return StrandPalette.effortGlow
        case .rest:   return StrandPalette.restGlow
        case .stress: return StrandPalette.stressGlow
        }
    }

    public var gradient: Gradient {
        switch self {
        case .charge: return StrandPalette.chargeGradient
        case .effort: return StrandPalette.effortGradient
        case .rest:   return StrandPalette.restGradient
        case .stress: return StrandPalette.stressGradient
        }
    }

    /// The data gradient values are sampled along (Charge/Rest = recovery scale, Effort = strain ramp).
    public var dataGradient: Gradient {
        switch self {
        case .charge, .rest, .stress: return StrandPalette.recoveryGradient
        case .effort:                 return StrandPalette.strainGradient
        }
    }
}

// MARK: - Scenic Hero Background
//
// A Canvas-drawn hero backdrop: radial blue-black gradient, optionally tinted toward a domain's glow.
// Deterministic (no per-frame randomness) so it never flickers.

public struct ScenicHeroBackground: View {

    /// Optional domain whose glow tints the upper bloom; nil = neutral blue-black.
    public var domain: DomainTheme?
    public var starCount: Int
    /// Whether to draw the bottom fade that lets content sit over the field.
    public var fadesToBase: Bool

    @Environment(\.colorScheme) private var scheme

    public init(domain: DomainTheme? = nil, starCount: Int = 40, fadesToBase: Bool = true) {
        self.domain = domain
        self.starCount = starCount
        self.fadesToBase = fadesToBase
    }

    public var body: some View {
        ZStack {
            RadialGradient(
                gradient: Gradient(colors: [StrandPalette.scenicCenter, StrandPalette.scenicEdge]),
                center: .init(x: 0.5, y: 0.36),
                startRadius: 0,
                endRadius: 520
            )

            // Flat look: the domain bloom and starfield are removed. `domain` and `starCount` stay for API stability but no longer paint.

            if fadesToBase {
                LinearGradient(
                    colors: [.clear, StrandPalette.scenicEdge.opacity(0.72), StrandPalette.scenicEdge],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("ScenicHeroBackground") {
    VStack(spacing: 0) {
        ScenicHeroBackground(domain: .charge)
            .frame(height: 220)
            .overlay(
                Text("87").font(.system(size: 60, weight: .bold, design: .rounded))
                    .foregroundStyle(StrandPalette.textPrimary)
            )
        ScenicHeroBackground(domain: .rest)
            .frame(height: 220)
    }
    .frame(width: 420, height: 440)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif
