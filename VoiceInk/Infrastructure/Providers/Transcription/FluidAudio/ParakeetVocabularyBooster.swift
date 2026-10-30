import FluidAudio
import Foundation
import os

/// Corrects saved dictionary words in Parakeet transcripts by checking the audio itself with
/// FluidAudio's CTC keyword spotter (parakeet-ctc-110m, about 98 MB, downloaded once).
///
/// Parakeet hears "n8n" as "Нтн" or "N"; text-only correction cannot tell such a word from
/// an ordinary one, while the CTC pass scores the dictionary spelling against the sound.
/// It runs only on whole-file transcription, where token timings match the audio.
actor ParakeetVocabularyBooster {
    static let shared = ParakeetVocabularyBooster()

    /// Measured on 60 recent dictations: 0.8 fixed "Нтн" → n8n and "ChatGBT" → ChatGPT with no
    /// false replacement. FluidAudio's 0.6 default and 0.7 rewrote ordinary words
    /// (for example, "tool" → "toggl").
    private static let minimumSimilarity: Float = 0.8
    /// The weight FluidAudio's text vocabulary format gives every term; the threshold was measured with it.
    private static let termWeight: Float = 10
    private static let variant: CtcModelVariant = .ctc110m

    private struct PreparedVocabulary {
        let key: String
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VocabularyBoosting")
    private var models: CtcModels?
    private var loadTask: Task<CtcModels, Error>?
    private var tokenizer: CtcTokenizer?
    private var prepared: PreparedVocabulary?

    nonisolated static var isEnabled: Bool { VocabularyCorrectionSettings.isEnabled }

    /// Loads the CTC model in the background, downloading it the first time.
    func prepare() {
        guard Self.isEnabled, models == nil else { return }
        _ = loadingTask()
    }

    /// Returns `text` with dictionary words restored where the audio supports them.
    /// Any failure keeps the original transcript: boosting must never break transcription.
    func rescore(
        text: String,
        tokenTimings: [TokenTiming]?,
        samples: [Float],
        vocabulary: RecordingVocabulary?
    ) async -> String {
        guard Self.isEnabled, let vocabulary, !vocabulary.savedTerms.isEmpty,
            let tokenTimings, !tokenTimings.isEmpty, !samples.isEmpty, !text.isEmpty
        else { return text }

        do {
            guard let models = try await readyModels() else { return text }
            let prepared = try await preparedVocabulary(for: vocabulary, models: models)
            let started = Date()
            let spot = try await prepared.spotter.spotKeywordsWithLogProbs(
                audioSamples: samples,
                customVocabulary: prepared.context,
                minScore: nil
            )
            guard !spot.logProbs.isEmpty else { return text }

            let output = prepared.rescorer.ctcTokenRescore(
                transcript: text,
                tokenTimings: tokenTimings,
                logProbs: spot.logProbs,
                frameDuration: spot.frameDuration,
                cbw: ContextBiasingConstants.rescorerConfig(forVocabSize: prepared.context.terms.count).cbw,
                marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
                minSimilarity: Self.minimumSimilarity
            )
            let applied = output.replacements.filter(\.shouldReplace)
            logger.notice(
                "Vocabulary boosting replacements=\(applied.count, privacy: .public) terms=\(prepared.context.terms.count, privacy: .public) elapsed=\(Date().timeIntervalSince(started), format: .fixed(precision: 3), privacy: .public)s"
            )
            guard output.wasModified else { return text }
            return Self.restoringDictionarySpelling(
                in: output.text,
                replacements: applied,
                terms: vocabulary.savedTerms
            )
        } catch {
            logger.error("Vocabulary boosting skipped: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }

    /// Waits for a model already on disk; starts a first download in the background and skips this run.
    private func readyModels() async throws -> CtcModels? {
        if let models { return models }
        let directory = CtcModels.defaultCacheDirectory(for: Self.variant)
        let task = loadingTask()
        guard CtcModels.modelsExist(at: directory) else {
            logger.notice("Vocabulary boosting model is downloading; this transcription is not boosted")
            return nil
        }
        return try await task.value
    }

    private func loadingTask() -> Task<CtcModels, Error> {
        if let loadTask { return loadTask }
        let task = Task<CtcModels, Error> { try await CtcModels.downloadAndLoad(variant: Self.variant) }
        loadTask = task
        Task { await self.finishLoading(task) }
        return task
    }

    private func finishLoading(_ task: Task<CtcModels, Error>) async {
        do {
            models = try await task.value
            logger.notice("Vocabulary boosting model loaded")
        } catch {
            if loadTask == task { loadTask = nil }
            logger.error("Vocabulary boosting model failed to load: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func preparedVocabulary(for vocabulary: RecordingVocabulary, models: CtcModels) async throws
        -> PreparedVocabulary
    {
        let key = vocabulary.savedTerms.map { term in
            ([term] + (vocabulary.savedAliases[term] ?? [])).joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        if let prepared, prepared.key == key { return prepared }

        let directory = CtcModels.defaultCacheDirectory(for: Self.variant)
        let tokenizer = try await loadedTokenizer(from: directory)
        let terms = vocabulary.savedTerms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIds = tokenizer.encode(term)
            guard !tokenIds.isEmpty else { return nil }
            let aliases = vocabulary.savedAliases[term] ?? []
            return CustomVocabularyTerm(
                text: term,
                weight: Self.termWeight,
                aliases: aliases.isEmpty ? nil : aliases,
                ctcTokenIds: tokenIds
            )
        }
        let context = CustomVocabularyContext(terms: terms)
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            config: .default,
            ctcModelDirectory: directory
        )
        let result = PreparedVocabulary(key: key, context: context, spotter: spotter, rescorer: rescorer)
        prepared = result
        return result
    }

    private func loadedTokenizer(from directory: URL) async throws -> CtcTokenizer {
        if let tokenizer { return tokenizer }
        let loaded = try await CtcTokenizer.load(from: directory)
        tokenizer = loaded
        return loaded
    }

    /// FluidAudio capitalizes a replacement after a capitalized word ("Нтн" → "N8n"); the
    /// dictionary spelling is the one the user chose.
    static func restoringDictionarySpelling(
        in text: String,
        replacements: [VocabularyRescorer.RescoringResult],
        terms: [String]
    ) -> String {
        var result = text
        for word in Set(replacements.compactMap(\.replacementWord)) {
            guard let term = terms.first(where: { $0.lowercased() == word.lowercased() }), term != word else {
                continue
            }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        return result
    }
}
