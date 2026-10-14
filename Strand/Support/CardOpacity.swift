import SwiftUI
import StrandDesign

/// The user's "Card transparency" setting as a 0...1 fraction. Reads the same AppStorage key as the
/// Settings slider, so views update live when it changes.
@propertyWrapper
struct CardOpacity: DynamicProperty {
    @AppStorage(CardAppearancePrefs.opacityKey) private var percent = CardAppearancePrefs.defaultPercent

    var wrappedValue: Double { max(0, min(1, Double(percent) / 100)) }
}
