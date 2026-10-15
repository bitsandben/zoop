import SwiftUI

// MARK: - Native Liquid Glass search field
// Shared search chrome for every in-app filter/search bar. iOS 26 uses the platform `glassEffect` capsule; macOS and older iOS keep a solid elevated pill.

/// Full-width rounded search field with native Liquid Glass on iOS 26+.
public struct ZoopLiquidGlassSearchField: View {
    @Binding private var text: String
    private let prompt: String
    private let accessibilityPrompt: String
    private var externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    public init(text: Binding<String>,
                prompt: String,
                accessibilityLabel: String? = nil,
                isFocused: FocusState<Bool>.Binding? = nil) {
        self._text = text
        self.prompt = prompt
        self.accessibilityPrompt = accessibilityLabel ?? prompt
        self.externalFocus = isFocused
    }

    public var body: some View {
        HStack(spacing: ZoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused(focusBinding)
                .submitLabel(.search)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, ZoopMetrics.space4)
        .padding(.vertical, ZoopMetrics.space3)
        .nativeLiquidGlassSearchChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityPrompt))
    }

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }
}

public extension View {
    /// Capsule Liquid Glass search chrome (iOS 26 `glassEffect`; otherwise the shared elevated pill). Glass APIs stay behind `#if os(iOS)` so macOS 13 never type-checks them.
    @ViewBuilder
    func nativeLiquidGlassSearchChrome() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.noopStandardSearchChrome()
        }
        #else
        self.noopStandardSearchChrome()
        #endif
    }

    /// Circular/capsule interactive Liquid Glass button chrome (Home header, live-workout controls). iOS 26 only; other platforms keep the caller's `fallback`.
    @ViewBuilder
    func nativeLiquidGlassButtonChrome<Fallback: View>(
        controlSize: ControlSize = .small,
        capsule: Bool = false,
        @ViewBuilder fallback: () -> Fallback
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(capsule ? .capsule : .circle)
                .controlSize(controlSize)
        } else {
            fallback()
        }
        #else
        fallback()
        #endif
    }

    /// Interactive circular `glassEffect` finish layer (e.g. Home profile photo over glass).
    /// No-op outside iOS 26 so macOS never imports the glass path.
    @ViewBuilder
    func nativeLiquidGlassCircleFinish() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    private func noopStandardSearchChrome() -> some View {
        self.background(
            ZoopPanelSurface(cornerRadius: ZoopVisualStyle.pillRadius, elevated: false)
        )
    }
}
