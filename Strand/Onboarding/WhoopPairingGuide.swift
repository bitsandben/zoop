import SwiftUI
import StrandDesign

// MARK: - WHOOP pairing guidance shared by onboarding and the Add-device wizard
//
// Both flows pair the same two strap families, so the "get it ready" copy and the one-phone warning
// live here once. Moved verbatim out of `AddDeviceWizard` (same English keys, so every existing
// translation still resolves). Text and layout only: no scan or connect call ever lives here.

enum WhoopPairingGuide {
    /// Model-specific preparation, in the order the user does it.
    static func prepSteps(for model: WhoopModel) -> [String] {
        switch model {
        case .whoop4:
            return [
                String(localized: "Put your WHOOP 4.0 on your wrist and make sure it's awake."),
                String(localized: "Make sure it's NOT connected to the official WHOOP app right now."),
                String(localized: "Zoop will look for it nearby."),
            ]
        case .whoop5mg:
            return [
                String(localized: "WHOOP 5.0 / MG bonds to one device at a time. Unpair it from the official WHOOP app first."),
                String(localized: "Put the band into pairing mode, on your wrist and awake."),
                String(localized: "Zoop will look for it nearby."),
            ]
        }
    }
}

/// The amber "one phone at a time" heads-up shown before a WHOOP scan. A failed pairing is most often
/// the official WHOOP app still holding the band's single BLE link, so the fix is stated up front.
struct WhoopSingleConnectionNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Your WHOOP only talks to one phone at a time.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Force-quit the official WHOOP app first, or pairing may fail.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.statusWarning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heads-up. Your WHOOP only talks to one phone at a time. Force-quit the official WHOOP app first, or pairing may fail.")
    }
}
