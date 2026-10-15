import Foundation
import StrandAnalytics

/// The language every coach reply must be written in: the app language the bundles chose
/// (`AppLanguage.activeLocale`), not the phone's. Every prompt that leaves the device carries the
/// directive, and replies the app keeps are checked against it (`CoachLanguageCheck`).
enum CoachLanguage {

    /// "de" or "en".
    static var code: String { AppLanguage.activeLocale.language.languageCode?.identifier ?? "en" }

    /// The explicit "answer in German" line appended to a system prompt.
    static var directive: String { CoachBriefReply.languageDirective(languageCode: code) }

    /// A system prompt (the user may have edited theirs) with the language line appended.
    static func withDirective(_ systemPrompt: String) -> String {
        systemPrompt + "\n\n" + directive
    }

    /// True when `text` reads as the app language, or is too short to tell.
    static func matches(_ text: String) -> Bool {
        CoachLanguageCheck.matches(text, languageCode: code)
    }

    /// A chat chip or follow-up prompt, looked up in the String Catalog by its English text. The
    /// chips come from `CoachSuggestions` (pure, shared with the Android twin) as English keys.
    static func localizedPrompt(_ english: String) -> String {
        Bundle.main.localizedString(forKey: english, value: english, table: nil)
    }
}
