#if os(iOS)
import SwiftUI
import UIKit
import StrandDesign

/// The one sync readout under the Today header and on the strap screen: a small ring glyph, the state
/// from `SyncCapsuleState`, and the active device's charge. Calm by default; a state that needs the user
/// explains itself on tap instead of turning the line amber.
struct SyncCapsule: View {
    var pull: PullSyncPhase = .idle
    /// Opens the strap screen. `nil` where the capsule already sits on it.
    var onOpenDevices: (() -> Void)?
    /// Starts another pull. `nil` where no pull is wired.
    var onRetry: (() -> Void)?

    @EnvironmentObject private var live: LiveState
    @State private var explaining: SyncExplanation?

    var body: some View {
        // The minute timeline keeps "Last sync 4 min ago" current while the screen stays open.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let state = SyncCapsuleState.resolve(status: live.syncStatus, pull: pull,
                                                 now: context.date.timeIntervalSince1970)
            Button { tap(state.tap) } label: { capsule(state) }
                .buttonStyle(LiquidPressStyle())
                .disabled(!isTappable(state.tap))
                .animation(ZoopMotion.gated(ZoopMotion.value, reduced: reduceMotion), value: state)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityText(state)))
                .accessibilityActions {
                    if let onRetry { Button("zoop.sync.retry", action: onRetry) }
                }
        }
        .sheet(item: $explaining) { explanation in
            SyncExplanationSheet(explanation: explanation, onRetry: onRetry, onOpenDevices: onOpenDevices)
                .presentationDetents([.medium])
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func capsule(_ state: SyncCapsuleState) -> some View {
        HStack(spacing: ZoopSpacing.s) {
            SyncRingGlyph(symbol: state.symbol, ring: state.ring, strong: state.celebrates)
            Text(state.title)
                .font(ZoopType.caption.weight(.medium))
                .foregroundStyle(state.celebrates ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .lineLimit(1)
                .contentTransition(.opacity)
            if let battery {
                Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 12)
                BatteryLabel(display: battery)
            }
            if case .explain = state.tap {
                Image(systemName: "info.circle")
                    .font(ZoopType.icon(12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.leading, ZoopSpacing.xs)
        .padding(.trailing, ZoopSpacing.m)
        .frame(minHeight: 36)
        .background(Capsule(style: .continuous).fill(StrandPalette.surfaceRaised))
        .overlay(Capsule(style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
        .contentShape(Capsule(style: .continuous))
        .frame(minHeight: 44)
    }

    private func isTappable(_ tap: SyncCapsuleState.Tap) -> Bool {
        if case .devices = tap { return onOpenDevices != nil }
        return true
    }

    private func tap(_ tap: SyncCapsuleState.Tap) {
        switch tap {
        case .devices: onOpenDevices?()
        case .explain(let explanation): explaining = explanation
        }
    }

    /// The charge only while it is known for the current link (see `StrapBatteryDisplay`).
    private var battery: StrapBatteryDisplay? {
        let display = StrapBatteryDisplay.resolve(
            activeIsWhoop: live.activeIsWhoop, connected: live.connected, batteryPct: live.batteryPct,
            charging: live.charging, ringPct: live.ouraBatteryPct, ringCharging: live.ouraWearState == .charging)
        switch display {
        case .charge, .pending(true): return display
        case .pending(false), .offline, .notActiveDevice: return nil
        }
    }

    private func accessibilityText(_ state: SyncCapsuleState) -> String {
        [state.title, battery.map(BatteryLabel.text)].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A small ring around a state glyph: closed when caught up, an indeterminate arc while something is in
/// flight (a still arc under Reduce Motion), and a plain well otherwise.
struct SyncRingGlyph: View {
    let symbol: String
    let ring: SyncCapsuleState.Ring
    var strong = false
    var size: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = ZoopMotionState.shared

    var body: some View {
        ZStack {
            Circle().fill(StrandPalette.surfaceInset)
            Circle().stroke(StrandPalette.hairline, lineWidth: 2).padding(1)
            switch ring {
            case .full:
                Circle().stroke(strong ? StrandPalette.textPrimary : StrandPalette.textSecondary, lineWidth: 2)
                    .padding(1)
            case .spinning:
                spinner
            case .none:
                EmptyView()
            }
            Image(systemName: symbol)
                .font(ZoopType.icon(size * 0.4, weight: .bold))
                .foregroundStyle(strong ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var spinner: some View {
        let arc = Circle().trim(from: 0, to: 0.3)
            .stroke(StrandPalette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .padding(1)
        if motion.poseStill(reduceMotion) {
            arc.rotationEffect(.degrees(-90))
        } else {
            TimelineView(.animation) { context in
                let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                arc.rotationEffect(.degrees(turns * 360 - 90))
            }
        }
    }
}

/// A battery glyph that tracks the charge, beside the percentage.
private struct BatteryLabel: View {
    let display: StrapBatteryDisplay

    var body: some View {
        HStack(spacing: ZoopSpacing.xs) {
            Image(systemName: Self.symbol(display))
                .font(ZoopType.icon(13, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
            if case .charge(let pct, _, _) = display {
                Text(Self.percent(pct))
                    .font(ZoopType.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .fixedSize()
    }

    static func symbol(_ display: StrapBatteryDisplay) -> String {
        guard case .charge(let pct, let charging, _) = display else { return "battery.100percent.bolt" }
        if charging { return "battery.100percent.bolt" }
        switch pct {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func percent(_ pct: Double) -> String {
        (pct / 100).formatted(.percent.precision(.fractionLength(0)).locale(AppLanguage.activeLocale))
    }

    static func text(_ display: StrapBatteryDisplay) -> String {
        switch display {
        case .charge(_, true, _), .pending(true): return String(localized: TodayCopy.batteryCharging)
        case .charge(let pct, false, _): return String(localized: TodayCopy.battery(percent(pct)))
        default: return ""
        }
    }
}

/// What a blocked or noted sync means, with the one fix that applies.
private struct SyncExplanationSheet: View {
    let explanation: SyncExplanation
    let onRetry: (() -> Void)?
    let onOpenDevices: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: ZoopSpacing.l) {
            SyncRingGlyph(symbol: symbol, ring: .none, size: 44)
            Text(explanation.lead)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = explanation.message {
                Text(message)
                    .font(ZoopType.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(ZoopSpacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    private var symbol: String {
        switch explanation {
        case .bluetooth: return "antenna.radiowaves.left.and.right.slash"
        case .note: return "info"
        case .stalled, .didNotStart: return "exclamationmark"
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: ZoopSpacing.s) {
            if explanation.offersSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                ZoopButton("zoop.sync.openSettings", systemImage: "gear", kind: .primary, fullWidth: true) {
                    dismiss(); openURL(url)
                }
            } else if explanation.offersRetry, let onRetry {
                ZoopButton("zoop.sync.retry", systemImage: "arrow.triangle.2.circlepath",
                           kind: .primary, fullWidth: true) { dismiss(); onRetry() }
            }
            if let onOpenDevices {
                ZoopButton("zoop.sync.openDevices", kind: .secondary, fullWidth: true) {
                    dismiss(); onOpenDevices()
                }
            } else {
                ZoopButton("zoop.sync.done", kind: .secondary, fullWidth: true) { dismiss() }
            }
        }
    }
}
#endif
