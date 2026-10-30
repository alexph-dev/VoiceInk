import AppKit
import Foundation
import os

@MainActor
final class TranscriptionDelivery {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionDelivery")

    struct Request {
        let transcription: Transcription
        let text: String?
        let output: OutputRuntimeConfiguration
        let responseConfig: EnhancementRuntimeConfiguration?
        let responseError: String?
        let isAssistantFollowUp: Bool
        let sendAfterPaste: Bool
    }

    struct Actions {
        let setState: (RecordingState) -> Void
        let dismiss: () async -> Void
        let sendFollowUp: (String, Transcription) async -> Void
        let showResponse: (String, String?) async -> Void
        let failResponse: (String) async -> Void
    }

    func deliver(_ request: Request, actions: Actions) async {
        guard request.transcription.transcriptionStatus == TranscriptionStatus.completed.rawValue else {
            await actions.dismiss()
            return
        }

        if request.isAssistantFollowUp {
            await deliverFollowUp(request, actions: actions)
            return
        }

        if request.output.outputMode == .respond,
            request.responseConfig != nil || request.responseError != nil
        {
            await deliverResponse(request, actions: actions)
            return
        }

        if request.output.outputMode == .customCommand {
            await deliverCustomCommand(request, actions: actions)
            return
        }

        if let text = request.text {
            let sendKey = request.sendAfterPaste ? FinishAndSendSettings.selectedKey : request.output.autoSendKey
            await paste(text, sendKey: sendKey, actions: actions)
        } else {
            await actions.dismiss()
        }
    }

    /// Delivers a retried transcription the way its Mode delivers a new dictation: runs the Mode's
    /// custom command, or pastes at the cursor for every other output.
    /// - Returns: Why the custom command failed, if it did.
    func deliverRetry(_ text: String, output: OutputRuntimeConfiguration) async -> Error? {
        guard output.outputMode == .customCommand else {
            _ = await CursorPaster.startPasteAtCursor(pastedText(from: text)).value
            return nil
        }

        guard let command = output.customCommand?.trimmedCommand else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            return CustomCommandDeliveryError.commandNotConfigured
        }

        return await runCustomCommand(command: command, commandText: deliverableText(from: text), finishAndSendKey: .none)
    }

    private func deliverFollowUp(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return
        }

        actions.setState(.enhancing)
        await actions.sendFollowUp(text, item.transcription)
    }

    private func deliverResponse(_ item: Request, actions: Actions) async {
        SoundManager.shared.playStopSound()

        if let responseError = item.responseError {
            await actions.failResponse("Enhancement failed: \(responseError)")
        } else if let text = item.text,
            item.responseConfig != nil
        {
            await actions.showResponse(text, item.transcription.aiRequestSystemMessage)
        } else {
            await actions.failResponse("No response was generated.")
        }
    }

    private func deliverCustomCommand(_ item: Request, actions: Actions) async {
        guard let text = item.text else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.noTextToDeliver)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        guard let customCommand = item.output.customCommand,
            let command = customCommand.trimmedCommand
        else {
            notifyCustomCommandFailure(CustomCommandDeliveryError.commandNotConfigured)
            SoundManager.shared.playStopSound()
            await actions.dismiss()
            return
        }

        let commandText = deliverableText(from: text)
        let finishAndSendKey: FinishAndSendKey = item.sendAfterPaste ? FinishAndSendSettings.selectedKey : .none
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        Task {
            _ = await runCustomCommand(command: command, commandText: commandText, finishAndSendKey: finishAndSendKey)
        }
    }

    /// - Returns: Why the command failed, or nil when it succeeded.
    private func runCustomCommand(command: String, commandText: String, finishAndSendKey: FinishAndSendKey) async
        -> Error?
    {
        let startTime = Date()
        logger.notice("Custom command started")

        do {
            let result = try await CustomCommandDeliveryRunner.run(
                command: command,
                timeout: 10,
                context: CustomCommandDeliveryContext(transcript: commandText)
            )

            let duration = Date().timeIntervalSince(startTime)
            let stdoutBytes = result.stdout.utf8.count
            let stderrBytes = result.stderr.utf8.count

            if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command stdout bytes=\(stdoutBytes, privacy: .public): \(result.stdout, privacy: .public)")
            }

            if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                logger.notice(
                    "Custom command succeeded with stderr duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public): \(result.stderr, privacy: .public)"
                )
            } else {
                logger.notice(
                    "Custom command succeeded duration=\(Self.formattedDuration(duration), privacy: .public)s stdoutBytes=\(stdoutBytes, privacy: .public) stderrBytes=\(stderrBytes, privacy: .public)"
                )
            }

            if finishAndSendKey.isEnabled {
                // Let the target app finish pasting before sending.
                try await Task.sleep(nanoseconds: 150_000_000)
                CursorPaster.performSendKey(finishAndSendKey)
            }
            return nil
        } catch {
            notifyCustomCommandFailure(error, duration: Date().timeIntervalSince(startTime))
            return error
        }
    }

    private func notifyCustomCommandFailure(_ error: Error, duration: TimeInterval? = nil) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let duration {
            logger.error(
                "Custom command failed duration=\(Self.formattedDuration(duration), privacy: .public)s: \(message, privacy: .public)"
            )
        } else {
            logger.error("Custom command failed: \(message, privacy: .public)")
        }
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration)
    }

    private func paste(_ text: String, sendKey: FinishAndSendKey, actions: Actions) async {
        let textToPaste = pastedText(from: text)
        actions.setState(.idle)
        SoundManager.shared.playStopSound()
        await actions.dismiss()

        let pasteTask = CursorPaster.startPasteAtCursor(textToPaste, sendKey: sendKey)

        Task { @MainActor in
            let pasteOutcome = await pasteTask.value

            if sendKey.isEnabled && pasteOutcome.result.didPostPasteCommand {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let generation = pasteOutcome.autoLearnGeneration {
                    await AutoLearnService.shared.cancelForAutoSend(generation: generation)
                }
                CursorPaster.performSendKey(sendKey)
            }
        }
    }

    private func pastedText(from text: String) -> String {
        let appendSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace")
        return deliverableText(from: text) + (appendSpace ? " " : "")
    }

    private func deliverableText(from text: String) -> String {
        var textToDeliver = text
        if let restrictionMessage = LicenseViewModel.shared.usageRestrictionMessage {
            textToDeliver = """
                \(restrictionMessage)
                \n\(textToDeliver)
                """
        }

        return textToDeliver
    }
}
