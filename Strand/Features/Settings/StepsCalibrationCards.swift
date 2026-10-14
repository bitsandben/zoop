import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopProtocol

// The sheet's cards and formatting, split from `StepsCalibrationSheet.swift` to keep both files short.
extension StepsCalibrationSheet {

    /// The honest "it's an estimate, not a step counter" framing — reused verbatim from the engine doc.
    var explainerCard: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("How this works", systemImage: "figure.walk.motion")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(is5MG
                     ? String(localized: "Zoop estimates your steps from your WHOOP's stored motion, calibrated to your phone's step count. It's an estimate, not a hardware step counter; normal WHOOP 5/MG history sync supplies the motion data.")
                     : String(localized: "Zoop estimates your steps from your WHOOP's motion, calibrated to your phone's step count. It's an estimate, not a step counter. A WHOOP 4.0 doesn't transmit steps."))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("On the days your phone also counted steps, Zoop learns how much your motion maps to steps, then applies that to the strap-only days. The more matching days it has, the more it trusts the estimate.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown when the strap has banked NO motion yet (sampleMotion is nil) — the real reason a fresh
    /// WHOOP 4.0 shows zero steps (#37 bringiton321). Steps are built from the strap's synced motion
    /// history, so without a backfill there is nothing to estimate from — calibration can't help yet.
    ///
    /// #107: family-aware. A 4.0 streams motion automatically → "let it sync" is right. A 5/MG only streams
    /// motion once the experimental deep-data unlock is ON — so on a 5/MG the honest advice is "turn that on
    /// and reconnect", not "wait for a sync" (which never comes). Imports don't supply strap motion either.
    var noMotionNote: some View {
        ZoopCard(tint: StrandPalette.metricAmber) {
            VStack(alignment: .leading, spacing: 10) {
                Label("No motion synced yet", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(noMotionLead)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(noMotionAction)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The "why it's empty" line — a 5/MG needs the deep-data unlock before it streams motion at all.
    var noMotionLead: String {
        if is5MG {
            return String(localized: "We're not seeing motion from your WHOOP 5.0 / MG yet. Keep Zoop connected and let strap history finish syncing; the experimental R22 flags are not required. Account or Apple Health imports do not contain the raw strap motion this estimate needs.")
        }
        return String(localized: "We're not seeing any motion from your strap yet. Steps are estimated from your WHOOP's banked motion history, so your strap needs to sync that history before Zoop has anything to count.")
    }

    /// The "what to do" line — 5/MG points at the deep-data toggle (unless it's already on, then just sync).
    var noMotionAction: String {
        if is5MG && !deepDataEnabled {
            return String(localized: "Open Zoop near the strap and let WHOOP 5/MG history finish syncing. The step estimate and calibration fill in once enough stored motion has arrived; the legacy R22 experiment is not required.")
        }
        if is5MG {
            return String(localized: "Deep data is on — open Zoop near your strap and let it sync its motion history (a full first-run sync can take a while). Once a day or two of motion lands, your step estimate and the calibration below fill in.")
        }
        return String(localized: "Open Zoop near your strap and let it catch up (a full history sync can take a while on first run). Once a day or two of motion lands, your step estimate and the calibration below will start to fill in.")
    }

    /// The current calibration read-out: coefficient, sample days, and a Low/Medium/High confidence —
    /// or, if nothing's fit yet and no manual value is set, an honest "what we still need" prompt.
    var currentFitCard: some View {
        ZoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current calibration").strandOverline()
                if profile.stepsCalibrationCoefficient > 0 || profile.stepsManualCoefficient > 0 {
                    let coeff = profile.stepsManualCoefficient > 0
                        ? profile.stepsManualCoefficient : profile.stepsCalibrationCoefficient
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ZoopNumber.decimal(coeff, digits: 1))
                            .font(StrandFont.number(30))
                            .foregroundStyle(StrandPalette.accent)
                        Text("steps per motion unit")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    if profile.stepsManualCoefficient > 0 {
                        statLine(String(localized: "Source"), String(localized: "Manual (you set this by hand)"))
                    } else {
                        statLine(String(localized: "Fitted from"),
                                 profile.stepsCalibrationSampleDays == 1
                                     ? String(localized: "1 day your phone also counted")
                                     : String(localized: "\(profile.stepsCalibrationSampleDays) days your phone also counted"))
                        statLine(String(localized: "Confidence"), "\(StepsCalibrationFormat.confidenceLabel(profile.stepsCalibrationConfidence)) · \(Int((profile.stepsCalibrationConfidence * 100).rounded()))%")
                    }
                } else {
                    Text("Not calibrated yet")
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                    // Only ask for phone-step days when phone-step days are what is actually missing.
                    //
                    // A step estimate is `motion * coefficient` (`StepsEstimateEngine.estimate`) and a
                    // calibration point is the ratio `steps / motion`, so BOTH halves are required. With no
                    // banked strap motion neither the estimate nor the fit can move however many days the
                    // phone counts. The countdown below then names the half the user already has and hides
                    // the half they do not — a field report asked whether entering Apple Health steps by
                    // hand would start the calibration, which is exactly the conclusion it invites.
                    //
                    // The no-motion banner at the top of this sheet already explains the real blocker, so
                    // the honest move is to stop competing with it rather than to add more copy.
                    if !strapHasNoMotion {
                    // #589: a concrete countdown instead of a vague "a few days". Headline comes straight
                    // from the engine's needsMoreDays state so the wording matches the Today steps tile.
                    // #693: drive `have` off `profile.stepsCalibrationSampleDays` — the value the engine
                    // persists for the not-yet-calibrated case (IntelligenceEngine.swift sets it to the
                    // usable-day `have`, the SAME source the Today tile reads). `usableMatchedDays` can't be
                    // used here: `loadIfNeeded` early-returns before computing it when coeff == 0 (no fit
                    // yet), so it would always read 0 and the card was stuck on "Need 3 more days".
                    Text(StepsEstimateEngine.CalibrationStatus
                        .needsMoreDays(have: profile.stepsCalibrationSampleDays,
                                       need: StepsEstimateEngine.minCalibrationDays)
                        .headline)
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.accent)
                    Text("These are the days where your phone also counted steps, so Zoop can learn how your motion maps to steps. Or set the coefficient manually below.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// The accuracy table: recent days that have BOTH an estimate and a phone count, side by side, so the
    /// user can SEE how close the estimate runs. Empty until enough both-have days exist.
    var comparisonCard: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Estimated vs your phone").strandOverline()
                if comparison.isEmpty {
                    Text("No days yet where both Zoop and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // Column header.
                    HStack {
                        Text("Day").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Est.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Phone").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 64, alignment: .trailing)
                        Text("Δ").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    ForEach(comparison) { row in
                        HStack {
                            Text(Self.shortDay(row.day))
                                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Self.grouped(row.estimated))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(Self.grouped(row.actual))
                                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 64, alignment: .trailing)
                            Text(String(format: "%+.0f%%", locale: AppLanguage.activeLocale, row.errorPct))
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(abs(row.errorPct) <= 15
                                                 ? StrandPalette.metricCyan : StrandPalette.statusWarning)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(Self.shortDay(row.day)): estimated \(row.estimated) steps, phone \(row.actual) steps, \(Int(row.errorPct.rounded())) percent difference")
                    }
                    Text("These days are excluded from the estimate (your phone's real count is shown instead). They're here only so you can judge the estimate's accuracy.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }

    /// Manual override: a slider bound to a draft, committed on release, with a live preview of what a
    /// typical recent day would estimate at the chosen coefficient. 0 returns to auto-fit.
    var manualAdjustCard: some View {
        ZoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Adjust manually").strandOverline()
                Text("Override the automatic fit with your own steps-per-motion value. Useful if your phone has no step history to learn from, or the estimate runs consistently high or low. Set it back to auto by dragging to the far left.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(draftManual > 0 ? ZoopNumber.decimal(draftManual, digits: 1) : String(localized: "Auto"))
                        .font(StrandFont.number(24))
                        .foregroundStyle(draftManual > 0 ? StrandPalette.accent : StrandPalette.textSecondary)
                    Text(draftManual > 0 ? "steps / motion unit" : "fit from your phone")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }

                Slider(value: $draftManual, in: 0...sliderMax, step: 0.5) {
                    Text("Manual steps coefficient")
                } minimumValueLabel: {
                    Text("Auto").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } maximumValueLabel: {
                    Text("High").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } onEditingChanged: { editing in
                    // Commit on release — snap a tiny drag back to 0 (auto) so "auto" is reachable.
                    if !editing { profile.stepsManualCoefficient = draftManual < 0.5 ? 0 : draftManual }
                }
                .tint(StrandPalette.accent)
                .accessibilityValue(draftManual > 0
                                    ? "\(ZoopNumber.decimal(draftManual, digits: 1)) steps per motion unit"
                                    : "Automatic")

                // Live preview: a typical recent day re-estimated at the draft coefficient.
                if let motion = sampleMotion {
                    let effective = draftManual > 0 ? draftManual : profile.stepsCalibrationCoefficient
                    if effective > 0 {
                        let preview = Int((motion * effective).rounded())
                        statLine(String(localized: "A typical recent day"),
                                 draftManual > 0
                                     ? String(localized: "≈ \(Self.grouped(preview)) steps at this setting")
                                     : String(localized: "≈ \(Self.grouped(preview)) steps (auto)"))
                    }
                }
                if draftManual > 0 {
                    Text("Takes effect on the next analytics pass (after the next sync).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// A small "label … value" line shared by the fit + preview cards.
    func statLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            Spacer(minLength: 12)
            Text(value).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: Formatting

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// "yyyy-MM-dd" → "EEE d MMM" for the table's day column.
    static func shortDay(_ key: String) -> String {
        let inF = DateFormatter(); inF.locale = Locale(identifier: "en_US_POSIX"); inF.dateFormat = "yyyy-MM-dd"
        guard let d = inF.date(from: key) else { return key }
        let outF = DateFormatter(); outF.dateFormat = "EEE d MMM"
        return outF.string(from: d)
    }
}
