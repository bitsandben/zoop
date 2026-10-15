import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Strength
//
// This week's working sets and lifted volume, shown only when the Lift Log has a recent session. Nothing
// here is drawn for a user who does not lift, so the page never shows an empty strength card. The muscle
// recovery card is placed by `TrainingScreen` on its own, since it covers every sport.

struct TrainingStrengthSection: View {
    let snapshot: LiftFitnessSnapshot
    let unitSystem: UnitSystem

    private var volume: String {
        let v = LiftFormat.display(fromKilograms: snapshot.week.volumeKg, system: unitSystem)
        return v.rounded().formatted(.number.precision(.fractionLength(0)).locale(AppLanguage.activeLocale))
            + "\u{00A0}" + LiftFormat.weightUnit(unitSystem)
    }

    var body: some View {
        if snapshot.hasRecentLifts {
            ContentCard {
                HStack(alignment: .firstTextBaseline) {
                    Text("Strength").font(ZoopType.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: ZoopSpacing.s)
                    Text("This week").font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                HStack(alignment: .top, spacing: ZoopSpacing.m) {
                    stat("Working sets", "\(snapshot.week.workingSets)")
                    stat("Volume", volume)
                }
            }
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(ZoopType.caption).foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(ZoopType.metric)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
