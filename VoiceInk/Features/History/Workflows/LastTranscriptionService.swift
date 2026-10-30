import Foundation
import SwiftData

/// One "Retry with Mode" shortcut: the Mode it retries with, and whether the result goes through
/// that Mode's output (paste or custom command) instead of the clipboard.
struct RetryModeSlot: Identifiable {
    static let all = (1...3).map(RetryModeSlot.init(number:))

    let number: Int
    var id: Int { number }

    // Slot 1 keeps the keys of the original single shortcut so existing settings carry over.
    private var keySuffix: String { number == 1 ? "" : "\(number)" }
    var modeIDKey: String { "retryLastTranscriptionModeID" + keySuffix }
    var deliversModeOutputKey: String { "retryLastTranscriptionDeliversModeOutput" + keySuffix }
    var shortcutAction: ShortcutAction { .retryLastTranscriptionWithMode(number) }

    var selectedModeID: UUID? {
        UserDefaults.standard.string(forKey: modeIDKey).flatMap(UUID.init(uuidString:))
    }

    var deliversModeOutput: Bool {
        UserDefaults.standard.bool(forKey: deliversModeOutputKey)
    }
}

class LastTranscriptionService: ObservableObject {

    static func getLastTranscription(from modelContext: ModelContext) -> Transcription? {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            let transcriptions = try modelContext.fetch(descriptor)
            return transcriptions.first
        } catch {
            let failure = error as NSError
            ShortcutDiagnostics.error("history result=fetch-failed domain=\(failure.domain) code=\(failure.code)")
            print("Error fetching last transcription: \(error)")
            return nil
        }
    }

    static func copyLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        // Prefer enhanced text; fallback to original text
        let textToCopy: String = {
            if let enhancedText = lastTranscription.enhancedText, !enhancedText.isEmpty {
                return enhancedText
            } else {
                return lastTranscription.text
            }
        }()

        let success = ClipboardManager.copyToClipboard(textToCopy)

        Task { @MainActor in
            if success {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Last transcription copied"),
                    type: .success
                )
            } else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Failed to copy transcription"),
                    type: .error
                )
            }
        }
    }

    static func pasteLastTranscription(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            ShortcutDiagnostics.notice("utility action=pasteLastTranscription result=ignored reason=no-history")
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        let textToPaste = lastTranscription.text

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CursorPaster.pasteAtCursor(textToPaste)
        }
    }

    static func pasteLastEnhancement(from modelContext: ModelContext) {
        guard let lastTranscription = getLastTranscription(from: modelContext) else {
            ShortcutDiagnostics.notice("utility action=pasteLastEnhancement result=ignored reason=no-history")
            Task { @MainActor in
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription available"),
                    type: .error
                )
            }
            return
        }

        // Prefer enhanced text; if unavailable, fallback to original text (which may contain an error message)
        let textToPaste: String = {
            if let enhancedText = lastTranscription.enhancedText, !enhancedText.isEmpty {
                return enhancedText
            } else {
                return lastTranscription.text
            }
        }()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CursorPaster.pasteAtCursor(textToPaste)
        }
    }

    /// Retries the last recording with the slot's Mode, so the language, model, and enhancement
    /// of that Mode replace the active Mode's for this one retry.
    static func retryLastTranscription(
        with slot: RetryModeSlot,
        from modelContext: ModelContext, transcriptionModelManager: TranscriptionModelManager,
        serviceRegistry: TranscriptionServiceRegistry, enhancementService: AIEnhancementService?
    ) {
        Task { @MainActor in
            guard let modeID = slot.selectedModeID,
                let mode = ModeManager.shared.getConfiguration(with: modeID)
            else {
                NotificationManager.shared.showNotification(
                    title: String(localized: "Choose a mode for this shortcut in Settings"),
                    type: .error
                )
                return
            }

            retryLastTranscription(
                from: modelContext,
                transcriptionModelManager: transcriptionModelManager,
                serviceRegistry: serviceRegistry,
                enhancementService: enhancementService,
                mode: mode,
                deliversModeOutput: slot.deliversModeOutput
            )
        }
    }

    /// - Parameter deliversModeOutput: Paste the result or run the Mode's custom command, as a new
    ///   dictation in that Mode would. Otherwise the result is copied to the clipboard.
    static func retryLastTranscription(
        from modelContext: ModelContext, transcriptionModelManager: TranscriptionModelManager,
        serviceRegistry: TranscriptionServiceRegistry, enhancementService: AIEnhancementService?,
        mode: ModeConfig? = nil, deliversModeOutput: Bool = false
    ) {
        Task { @MainActor in
            guard let lastTranscription = getLastTranscription(from: modelContext),
                let audioURLString = lastTranscription.audioFileURL,
                let audioURL = URL(string: audioURLString),
                FileManager.default.fileExists(atPath: audioURL.path)
            else {
                ShortcutDiagnostics.notice("utility action=retryLastTranscription result=ignored reason=history-or-audio-unavailable")
                NotificationManager.shared.showNotification(
                    title: String(localized: "Cannot retry: Audio file not found"),
                    type: .error
                )
                return
            }

            guard
                let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                    mode: mode,
                    transcriptionModelManager: transcriptionModelManager
                )
            else {
                ShortcutDiagnostics.notice("utility action=retryLastTranscription result=ignored reason=no-model")
                NotificationManager.shared.showNotification(
                    title: String(localized: "No transcription model selected"),
                    type: .error
                )
                return
            }

            let transcriptionService = AudioTranscriptionService(
                modelContext: modelContext,
                serviceRegistry: serviceRegistry,
                enhancementService: enhancementService
            )

            if let mode {
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Retrying with %@ mode…"), mode.name),
                    type: .info,
                    duration: 10.0
                )
            }

            do {
                let result = try await transcriptionService.retranscribeAudio(
                    from: audioURL,
                    using: transcriptionConfiguration.model,
                    mode: mode
                )
                let newTranscription = result.transcription

                let resultText =
                    result.enhancementFailure == nil && newTranscription.enhancedText?.isEmpty == false
                    ? newTranscription.enhancedText! : newTranscription.text

                let outputMode = deliversModeOutput ? mode : nil
                if let outputMode {
                    NotificationManager.shared.dismissNotification()
                    if let deliveryError = await TranscriptionDelivery().deliverRetry(
                        resultText,
                        output: ModeRuntimeResolver.outputConfiguration(mode: outputMode)
                    ) {
                        NotificationManager.shared.showNotification(
                            title: (deliveryError as? LocalizedError)?.errorDescription
                                ?? deliveryError.localizedDescription,
                            type: .error
                        )
                        return
                    }
                } else {
                    _ = ClipboardManager.copyToClipboard(resultText)
                }

                if let enhancementFailure = result.enhancementFailure {
                    NotificationManager.shared.showNotification(
                        title: EnhancementFailureFormatter.transcriptionSavedMessage(
                            description: enhancementFailure
                        ),
                        type: .warning
                    )
                } else if outputMode == nil {
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Copied to clipboard"),
                        type: .success
                    )
                }
            } catch {
                let failure = error as NSError
                ShortcutDiagnostics.error("utility action=retryLastTranscription result=failed domain=\(failure.domain) code=\(failure.code)")
                NotificationManager.shared.showNotification(
                    title: String(format: String(localized: "Retry failed: %@"), error.localizedDescription),
                    type: .error
                )
            }
        }
    }
}
