import SwiftUI
import WhoopStore

/// The Workouts screen, now `TrainingScreen` (Strand/Features/Training). This name stays because the
/// iOS tab shell, the macOS sidebar, `TabRoute` and the demo-screen harness all construct it.
struct WorkoutsView: View {
    private let previewRows: [WorkoutRow]?
    private let asTrainingTab: Bool

    /// - Parameter asTrainingTab: true when this is the Training tab root, whose header opens the Lift
    ///   Log and the interval timer.
    init(previewRows: [WorkoutRow]? = nil, asTrainingTab: Bool = false) {
        self.previewRows = previewRows
        self.asTrainingTab = asTrainingTab
    }

    var body: some View {
        TrainingScreen(previewRows: previewRows, asTrainingTab: asTrainingTab)
    }
}
