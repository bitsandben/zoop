import Foundation

// MARK: - Template copy (zoop.template.* in the package catalogue)
//
// The few words the page templates own themselves. Everything else a template shows is passed in by
// the feature, so its copy stays in the feature's catalogue entries.

enum TemplateStrings {
    private static let bundle = LocalizedStringResource.BundleDescription.atURL(Bundle.module.bundleURL)

    static let trendEmptyTitle = LocalizedStringResource(
        "zoop.template.trend.empty.title", defaultValue: "No trend yet", bundle: bundle)
    static let trendEmptyMessage = LocalizedStringResource(
        "zoop.template.trend.empty.message",
        defaultValue: "Your trend appears after a few nights with the strap.", bundle: bundle)
    static let reached = LocalizedStringResource(
        "zoop.template.calibrating.reached", defaultValue: "Reached", bundle: bundle)
}
