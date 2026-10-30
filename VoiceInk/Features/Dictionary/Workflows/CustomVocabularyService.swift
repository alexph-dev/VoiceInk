import Foundation
import SwiftData

@MainActor
final class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    func loadSavedVocabulary(from context: ModelContext) -> RecordingVocabulary {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        let words = (try? context.fetch(descriptor)) ?? []
        let terms = words.map(\.word)

        // A replacement rule whose result is a dictionary word records how the model mishears
        // that word. Rules for other phrases are left out: as acoustic aliases they rewrote
        // ordinary speech in testing.
        var termsByKey: [String: String] = [:]
        for term in terms { termsByKey[WordReplacementVariants.key(for: term)] = term }
        var aliases: [String: [String]] = [:]
        let replacements = (try? context.fetch(FetchDescriptor<WordReplacement>())) ?? []
        for replacement in replacements {
            guard let term = termsByKey[WordReplacementVariants.key(for: replacement.replacementText)] else { continue }
            aliases[term, default: []].append(contentsOf: WordReplacementVariants.parse(replacement.originalText))
        }
        return RecordingVocabulary(savedTerms: terms, savedAliases: aliases)
    }
}
