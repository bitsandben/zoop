import Foundation

// CoachLanguageCheck.swift - does a cloud reply speak the app's language?
//
// The coach prompt names the target language, but a model fed English data can still answer in
// English. This is a cheap function-word count, enough to tell German from English, so the app can
// fall back to its own localised rules instead of showing a reply in the wrong language.

public enum CoachLanguageCheck {

    /// Frequent function words that are not also common in the other language.
    static let german: Set<String> = [
        "und", "der", "die", "das", "du", "dein", "deine", "deinen", "deiner", "ist", "nicht", "mit",
        "heute", "für", "auf", "ein", "eine", "einen", "zu", "den", "dem", "sich", "auch", "wie", "noch",
        "bei", "von", "dich", "dir", "nach", "wenn", "oder", "sind", "hast", "bist", "mehr", "weniger",
        "etwas", "jetzt", "sehr", "aber", "schlaf", "erholung", "abend", "morgen", "weil", "dass",
    ]
    static let english: Set<String> = [
        "the", "and", "you", "your", "is", "are", "not", "with", "today", "for", "on", "to", "of", "it",
        "this", "that", "be", "have", "has", "sleep", "recovery", "more", "less", "than", "but", "if",
        "or", "at", "what", "keep", "take", "get", "because", "tonight", "yesterday", "should",
    ]
    /// Fewer hits than this across both lists is too little text to judge.
    static let minHits = 3

    /// True when `text` reads as `languageCode` ("de" / "en"), or when it is too short or the language
    /// is not one the check knows.
    public static func matches(_ text: String, languageCode: String) -> Bool {
        let code = languageCode.lowercased().prefix(2)
        guard code == "de" || code == "en" else { return true }
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        let de = words.filter { german.contains($0) }.count
        let en = words.filter { english.contains($0) }.count
        guard de + en >= minHits else { return true }
        return code == "de" ? de >= en : en >= de
    }
}
