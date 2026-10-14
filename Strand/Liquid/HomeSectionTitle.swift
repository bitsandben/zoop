#if os(iOS)
import SwiftUI
import StrandDesign

/// A sentence-case section title with an optional trailing control. Only the patterns carousel still
/// uses it; Today titles its own sections.
struct HomeSectionTitle<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(ZoopType.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: ZoopMetrics.space2)
            trailing()
        }
        .padding(.top, ZoopMetrics.space5)
        .padding(.horizontal, 2)
    }
}
#endif
