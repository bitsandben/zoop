import SwiftUI
import StrandDesign

/// A compact value + stepper control for the profile rows. Increments are closures so a field can step
/// in display units (lb, whole inches) while the profile keeps SI.
struct SettingsStepper: View {
    let value: String
    var unit: String?
    var muted = false
    let accessibilityLabel: String
    let increment: () -> Void
    let decrement: () -> Void

    var body: some View {
        HStack(spacing: ZoopSpacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: ZoopSpacing.xs) {
                Text(verbatim: value)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(muted ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .frame(minWidth: ZoopMetrics.formValueColumnWidth, alignment: .center)
                if let unit {
                    Text(verbatim: unit)
                        .font(ZoopType.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .fixedSize()
            Stepper(accessibilityLabel, onIncrement: increment, onDecrement: decrement)
                .labelsHidden()
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(Text(verbatim: [value, unit].compactMap { $0 }.joined(separator: " ")))
        }
        .fixedSize()
    }
}

/// The body-measurement and heart-rate steppers. Imperial fields step in pounds / whole inches and
/// write the SI equivalent back, so stored data never changes with the display unit. The owning page
/// observes the store, so these controls are rebuilt on every change.
@MainActor
struct SettingsBodyFields {
    let profile: ProfileStore
    let imperial: Bool

    var weight: SettingsStepper {
        if imperial {
            let lb = UnitFormatter.kgToPounds(profile.weightKg)
            return SettingsStepper(
                value: ZoopNumber.decimal(lb, digits: 0), unit: "lb",
                accessibilityLabel: String(localized: "Weight in pounds"),
                increment: { setPounds(lb.rounded() + 1) }, decrement: { setPounds(lb.rounded() - 1) })
        }
        return SettingsStepper(
            value: ZoopNumber.decimal(profile.weightKg, digits: 1), unit: "kg",
            accessibilityLabel: String(localized: "Weight in kilograms"),
            increment: { profile.weightKg = min(250, profile.weightKg + 0.5) },
            decrement: { profile.weightKg = max(30, profile.weightKg - 0.5) })
    }

    var height: SettingsStepper {
        if imperial {
            let inches = UnitFormatter.cmToInches(profile.heightCm).rounded()
            let parts = UnitFormatter.cmToFeetInches(profile.heightCm)
            return SettingsStepper(
                value: "\(parts.feet)′ \(parts.inches)″",
                accessibilityLabel: String(localized: "Height in inches"),
                increment: { setInches(inches + 1) }, decrement: { setInches(inches - 1) })
        }
        return SettingsStepper(
            value: ZoopNumber.decimal(profile.heightCm, digits: 0), unit: "cm",
            accessibilityLabel: String(localized: "Height in centimetres"),
            increment: { profile.heightCm = min(230, profile.heightCm + 1) },
            decrement: { profile.heightCm = max(120, profile.heightCm - 1) })
    }

    /// 0 means unset. The first step up from unset lands on a typical value instead of the range floor,
    /// and stepping below the floor clears it again.
    var waist: SettingsStepper {
        let isSet = profile.waistCm > 0
        if imperial {
            let inches = isSet ? UnitFormatter.cmToInches(profile.waistCm).rounded() : 0
            return SettingsStepper(
                value: isSet ? "\(Int(inches))" : String(localized: "Not set"), unit: isSet ? "in" : nil,
                muted: !isSet, accessibilityLabel: String(localized: "Waist in inches"),
                increment: {
                    profile.waistCm = min(160, ((isSet ? inches : 30) + 1) * UnitFormatter.centimetersPerInch)
                },
                decrement: {
                    let next = inches - 1
                    profile.waistCm = next < 24 ? 0 : next * UnitFormatter.centimetersPerInch
                })
        }
        return SettingsStepper(
            value: isSet ? ZoopNumber.decimal(profile.waistCm, digits: 0) : String(localized: "Not set"),
            unit: isSet ? "cm" : nil, muted: !isSet,
            accessibilityLabel: String(localized: "Waist in centimetres"),
            increment: { profile.waistCm = min(160, (isSet ? profile.waistCm : 79) + 1) },
            decrement: {
                let next = profile.waistCm - 1
                profile.waistCm = next < 60 ? 0 : next
            })
    }

    /// 0 = automatic (Tanaka from age).
    var hrMax: SettingsStepper {
        let manual = profile.hrMaxOverride > 0
        return SettingsStepper(
            value: manual ? "\(profile.hrMaxOverride)" : String(localized: "zoop.settings.auto"), unit: manual ? "bpm" : nil,
            muted: !manual, accessibilityLabel: String(localized: "Max heart rate override"),
            increment: { profile.hrMaxOverride = min(230, profile.hrMaxOverride + 1) },
            decrement: { profile.hrMaxOverride = max(0, profile.hrMaxOverride - 1) })
    }

    /// Steps neighbour-aware (`stepHRZoneThreshold`) so the five lower bounds stay strictly increasing.
    func zoneStart(_ index: Int) -> SettingsStepper {
        let value = profile.hrZoneThresholds.indices.contains(index) ? profile.hrZoneThresholds[index] : 0
        return SettingsStepper(
            value: "\(value)", unit: "bpm",
            accessibilityLabel: String(localized: "Zone \(index + 1) starts"),
            increment: { profile.stepHRZoneThreshold(at: index, up: true) },
            decrement: { profile.stepHRZoneThreshold(at: index, up: false) })
    }

    /// Daily steps = counter ticks ÷ this divisor. The variable increment keeps 1.0 precise and 30 reachable.
    var stepTicks: SettingsStepper {
        SettingsStepper(
            value: ZoopNumber.decimal(profile.stepTicksPerStep, digits: 1),
            accessibilityLabel: String(localized: "Step calibration"),
            increment: { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: true) },
            decrement: { profile.stepTicksPerStep = ProfileStore.steppedStepScale(profile.stepTicksPerStep, up: false) })
    }

    // Ranges mirror the metric 30…250 kg and 120…230 cm.
    private func setPounds(_ lb: Double) {
        profile.weightKg = min(551, max(66, lb)) / UnitFormatter.poundsPerKilogram
    }

    private func setInches(_ inches: Double) {
        profile.heightCm = min(91, max(47, inches)) * UnitFormatter.centimetersPerInch
    }
}
