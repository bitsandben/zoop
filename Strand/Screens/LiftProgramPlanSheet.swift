import SwiftUI
import StrandDesign
import WhoopStore

/// Pick the weekdays a Lift Log program is planned on. The schedule feeds the dashed circles on the
/// training calendar; it is stored in `TrainingPlan` and never touches the workout history.
struct LiftProgramPlanSheet: View {
    let program: LiftProgramRow

    @Environment(\.dismiss) private var dismiss
    @AppStorage(TrainingPlan.storageKey) private var planRaw = ""
    @State private var days: Set<Int> = []

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ZoopMetrics.gap) {
                Text(program.name)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Planned days show as dashed circles in your training calendar.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(Self.orderedWeekdays, id: \.self) { day in
                        dayToggle(day)
                    }
                }
                .padding(.top, 4)
                Spacer(minLength: 0)
            }
            .padding(ZoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceBase)
            .navigationTitle("Plan")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #else
        .frame(width: 420, height: 260)
        #endif
        .onAppear { days = TrainingPlan.decode(planRaw).days(for: program.id) }
    }

    /// Weekday numbers (1 = Sunday) in the locale's week order, so a German week starts on Monday.
    static var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private func dayToggle(_ day: Int) -> some View {
        let on = days.contains(day)
        let symbol = Calendar.current.veryShortStandaloneWeekdaySymbols[day - 1]
        let name = Calendar.current.standaloneWeekdaySymbols[day - 1]
        return Button {
            if on { days.remove(day) } else { days.insert(day) }
        } label: {
            Text(symbol)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(on ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Circle().fill(on ? StrandPalette.effortColor : StrandPalette.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func save() {
        var plan = TrainingPlan.decode(planRaw)
        plan.set(days, for: program.id)
        planRaw = plan.encoded()
        dismiss()
    }
}
