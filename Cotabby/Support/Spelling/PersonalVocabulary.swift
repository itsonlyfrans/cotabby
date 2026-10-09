import Foundation

/// Validates explicit, user-authored words for local spelling protection and word completion.
///
/// The settings model and store call this pure boundary before retaining entries. It has no learning,
/// storage, or inference side effects: vocabulary is never collected from typing or added to prompts.
/// Display spelling is preserved, while canonical case folding gives composed and decomposed Unicode
/// spellings the same identity. Accents remain significant, so `resume` does not protect `résumé`.
nonisolated enum PersonalVocabulary {
    static let maximumEntries = 200
    static let maximumWordCharacters = 64

    static func normalizedWord(_ input: String) -> String? {
        // Reject control characters before trimming: a pasted multi-line list must never silently
        // become a single entry, and invisible formatting cannot affect what an accepted word types.
        guard !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let word = input.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        guard !word.isEmpty, word.count <= maximumWordCharacters,
              word.first?.isLetter == true, word.last?.isLetter == true,
              word.allSatisfy({ $0.isLetter || CaretWordContext.isConnector($0) }) else { return nil }
        return word
    }

    /// Extracts an exact typed prefix only for explicitly saved words. Unlike ordinary spelling
    /// policy, this accepts scripts without space-delimited words: the saved entry itself supplies
    /// the boundary, while the caller still refuses insertion when text follows inside the token.
    static func unfinishedWord(in precedingText: String) -> String? {
        let token = String(precedingText.reversed().prefix(while: { !$0.isWhitespace }).reversed())
        return normalizedWord(token)
    }

    static func identity(_ word: String) -> String {
        word.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    /// Preserves the first display spelling and insertion order, with bounded storage.
    static func normalize(_ entries: [String]) -> [String] {
        var seen: Set<String> = []
        var words: [String] = []
        for entry in entries {
            guard let word = normalizedWord(entry), seen.insert(identity(word)).inserted else { continue }
            words.append(word)
            if words.count == maximumEntries { break }
        }
        return words
    }

    static func contains(_ word: String, in entries: [String]) -> Bool {
        let key = identity(word)
        return entries.contains { identity($0) == key }
    }
}
