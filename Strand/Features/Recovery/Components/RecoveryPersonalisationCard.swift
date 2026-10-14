import SwiftUI
import StrandAnalytics
import StrandDesign

/// How the morning check-in tunes Recovery, and the way into the calibration screen.
struct RecoveryPersonalisationCard: View {
    let kind: RecoveryPersonalisation
    let todayFeeling: Int?

    var body: some View {
        NavigationLink {
            RecoveryCalibrationView()
        } label: {
            ContentCard("zoop.recovery.personal.title", showsChevron: true) {
                Text(status).font(ZoopType.body).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let todayFeeling {
                    Text(RecoveryStrings.personalToday(RecoveryCalibrationCopy.feelingLabel(todayFeeling)))
                        .font(ZoopType.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var status: LocalizedStringResource {
        switch kind {
        case .off:
            return RecoveryStrings.personalOff
        case .collecting(let mornings, let needed):
            return RecoveryStrings.personalCollecting(mornings, of: needed)
        case .learned(let shift?):
            let name = RecoveryCalibrationCopy.termName(shift.term)
            return shift.percent > 0
                ? RecoveryStrings.personalHigher(name, shift.percent)
                : RecoveryStrings.personalLower(name, -shift.percent)
        case .learned(nil):
            return RecoveryStrings.personalNoShift
        }
    }
}
