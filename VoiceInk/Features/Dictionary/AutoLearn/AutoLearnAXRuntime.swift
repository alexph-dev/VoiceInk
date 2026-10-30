import ApplicationServices
import Foundation
import OSLog

final class AutoLearnAXRuntime: @unchecked Sendable {
    private struct Session {
        let token: AutoLearnPasteToken
        let appElement: AXUIElement
        let targetElement: AXUIElement
        let baselineFieldText: String
        let pastedRange: NSRange
        let pastedText: String
        /// Last non-blank text seen in the field. Sending a message clears the field, so the
        /// final read can come back empty even though the user corrected the dictation first.
        var latestFieldText: String?
        var latestChangeAt: UInt64 = 0
        /// Field text already handed to the review pipeline, so one edit is not submitted twice.
        var submittedFieldText: String?
    }

    private let queue = DispatchQueue(label: "com.prakashjoshipax.voiceink.auto-learn.accessibility")
    private let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink",
        category: "AutoLearnCapture"
    )
    private let textReader = AccessibilityTextReader(
        messagingTimeout: AutoLearnLimits.captureAccessibilityTimeoutSeconds,
        releasesWebAccessibilityWhenUnreadable: false
    )
    private var session: Session?

    func prepareWebAccessibility(processID: pid_t) async -> AccessibilityTextReader.WebAccessibilityPreparation {
        await perform { [self] in
            guard AXIsProcessTrusted(), processID != ProcessInfo.processInfo.processIdentifier else {
                return .unavailable
            }
            return textReader.prepareWebAccessibility(processID: processID)
        }
    }

    /// Restores web accessibility once the hold after the last dictation into the app has passed.
    func releaseWebAccessibility(processID: pid_t) async {
        await perform { [self] in
            if let active = session, AXProcessID(active.appElement) == processID { return }
            textReader.restoreWebAccessibility(
                processID: processID,
                appElement: AXUIElementCreateApplication(processID)
            )
        }
    }

    func capturePastedText(text: String, processID: pid_t) async -> AutoLearnCaptureOutcome {
        await perform { [self] in
            session = nil

            guard AXIsProcessTrusted() else { return rejectCapture("accessibility-not-trusted") }
            guard processID != ProcessInfo.processInfo.processIdentifier else {
                return rejectCapture("target-is-voiceink")
            }
            guard !text.isEmpty else { return rejectCapture("empty-pasted-text") }
            guard text.count <= AutoLearnLimits.maximumPastedCharacters else {
                return rejectCapture("pasted-text-too-large")
            }

            var matchedReading: AccessibilityTextReading?
            var pastedRange: NSRange?
            var lastReading: AccessibilityTextReading?

            let readings = textReader.focusedReadings(processID: processID)
            for reading in readings {
                lastReading = reading
                if let resolvedRange = resolvedPastedRange(
                    for: text,
                    selectionAfterPaste: reading.selection,
                    fieldText: reading.fieldText
                ) {
                    matchedReading = reading
                    pastedRange = resolvedRange
                    break
                }
            }

            guard let reading = matchedReading, let pastedRange else {
                return rejectCapture(
                    lastReading == nil ? "focused-text-reading-unavailable" : "pasted-range-invalid",
                    retryable: true
                )
            }

            let fieldText = reading.fieldText
            let observedPastedText = (fieldText as NSString).substring(with: pastedRange)

            AXUIElementSetMessagingTimeout(
                reading.appElement,
                AutoLearnLimits.accessibilityTimeoutSeconds
            )
            let token = AutoLearnPasteToken(id: UUID())
            session = Session(
                token: token,
                appElement: reading.appElement,
                targetElement: reading.targetElement,
                baselineFieldText: fieldText,
                pastedRange: pastedRange,
                pastedText: observedPastedText
            )
            logger.notice(
                "Auto Learn capture ok source=\(reading.source, privacy: .public) focus=\(reading.focusSource, privacy: .public)"
            )
            return .captured(token)
        }
    }

    /// Records the field's current text while the session runs.
    func sampleField(token: AutoLearnPasteToken) async {
        await perform { [self] in
            guard var active = session, active.token == token,
                let value = textReader.textValue(from: active.targetElement),
                value.text.utf16.count <= AccessibilityTextReader.maximumFieldUTF16Length,
                !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            if !(active.latestFieldText.map { textIsExactlyEqual($0, value.text) } ?? false) {
                active.latestChangeAt = DispatchTime.now().uptimeNanoseconds
            }
            active.latestFieldText = value.text
            session = active
        }
    }

    /// Returns a snapshot of an edited field once the user has stopped typing, and keeps the session
    /// running so later edits are still seen.
    func interimSnapshot(token: AutoLearnPasteToken, idleNanoseconds: UInt64) async -> AutoLearnFieldSnapshot? {
        await perform { [self] in
            guard var active = session, active.token == token,
                let latest = active.latestFieldText,
                !textIsExactlyEqual(latest, active.baselineFieldText),
                !(active.submittedFieldText.map { textIsExactlyEqual($0, latest) } ?? false),
                DispatchTime.now().uptimeNanoseconds - active.latestChangeAt >= idleNanoseconds
            else { return nil }
            active.submittedFieldText = latest
            session = active
            return AutoLearnFieldSnapshot(
                baselineFieldText: active.baselineFieldText,
                finalFieldText: latest,
                pastedRange: active.pastedRange,
                originalPastedText: active.pastedText
            )
        }
    }

    func finishSnapshot(token: AutoLearnPasteToken) async -> AutoLearnFieldSnapshot? {
        await perform { [self] in
            guard let active = session, active.token == token else { return nil }
            session = nil

            let finalFieldText: String
            if let finalTextValue = textReader.textValue(from: active.targetElement),
                !finalTextValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                finalFieldText = finalTextValue.text
            } else if let latestFieldText = active.latestFieldText {
                // The field was cleared or left the screen, usually because the message was sent.
                finalFieldText = latestFieldText
            } else {
                return nil
            }
            guard finalFieldText.utf16.count <= AccessibilityTextReader.maximumFieldUTF16Length else { return nil }
            guard !textIsExactlyEqual(finalFieldText, active.baselineFieldText) else { return nil }

            return AutoLearnFieldSnapshot(
                baselineFieldText: active.baselineFieldText,
                finalFieldText: finalFieldText,
                pastedRange: active.pastedRange,
                originalPastedText: active.pastedText
            )
        }
    }

    func targetIsFocused(token: AutoLearnPasteToken) async -> Bool {
        await perform { [self] in
            guard let active = session, active.token == token else { return false }
            return focusedElementMatches(active.targetElement, in: active.appElement)
        }
    }

    func discard(token: AutoLearnPasteToken? = nil) async {
        await perform { [self] in
            guard token == nil || session?.token == token else { return }
            session = nil
        }
    }

    private func AXProcessID(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return pid
    }

    private func textIsExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private func rejectCapture(_ reason: String, retryable: Bool = false) -> AutoLearnCaptureOutcome {
        logger.debug("Auto Learn capture attempt failed reason=\(reason, privacy: .public)")
        return retryable ? .retry(reason: reason) : .rejected(reason: reason)
    }

    private func focusedElementMatches(_ targetElement: AXUIElement, in appElement: AXUIElement) -> Bool {
        guard copyBoolAttribute(kAXFrontmostAttribute, from: appElement) != false else {
            return false
        }

        if let appFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ), CFEqual(appFocusedElement, targetElement) {
            return true
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        if let systemFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ), CFEqual(systemFocusedElement, targetElement) {
            return true
        }

        return copyBoolAttribute(kAXFocusedAttribute, from: targetElement) == true
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyBoolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func pastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange,
        fieldUTF16Length: Int
    ) -> NSRange? {
        guard isValid(selectionAfterPaste, inUTF16Length: fieldUTF16Length) else { return nil }

        let pastedLength = pastedText.utf16.count
        if selectionAfterPaste.length == pastedLength {
            return selectionAfterPaste
        }

        guard selectionAfterPaste.length == 0,
            selectionAfterPaste.location >= pastedLength
        else {
            return nil
        }

        return NSRange(
            location: selectionAfterPaste.location - pastedLength,
            length: pastedLength
        )
    }

    private func resolvedPastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange?,
        fieldText: String
    ) -> NSRange? {
        let field = fieldText as NSString
        let normalizedPastedText = AutoLearnTextNormalizer.accessibilityComparable(pastedText)

        if let selectionAfterPaste {
            if let inferredRange = pastedRange(
                for: pastedText,
                selectionAfterPaste: selectionAfterPaste,
                fieldUTF16Length: field.length
            ) {
                let observedText = field.substring(with: inferredRange)
                if textIsExactlyEqual(observedText, pastedText) {
                    return inferredRange
                }
                if !normalizedPastedText.isEmpty,
                    AutoLearnTextNormalizer.accessibilityComparable(observedText)
                        == normalizedPastedText
                {
                    return inferredRange
                }
            }
        }

        let exactMatches = exactMatches(for: pastedText, in: fieldText)
        if exactMatches.count == 1 {
            return exactMatches[0]
        }

        guard let selectionAfterPaste else {
            if let boundaryMatch = uniqueBoundaryWhitespaceMatch(
                for: pastedText,
                in: fieldText
            ) {
                return boundaryMatch
            }
            return nil
        }

        if let exactMatch = nearestMatch(
            in: exactMatches,
            near: selectionAfterPaste.location,
            pastedLength: pastedText.utf16.count
        ) {
            return exactMatch
        }

        guard selectionAfterPaste.length == 0 else { return nil }

        let expectedLength = pastedText.utf16.count
        let maximumLengthAdjustment = min(max(expectedLength / 4, 8), 128)
        guard !normalizedPastedText.isEmpty else { return nil }
        let caretLocation = min(max(selectionAfterPaste.location, 0), field.length)

        // Browser editors can expose the caret immediately before their own
        // trailing whitespace. Search only the closest boundaries around it.
        for endOffset in symmetricOffsets(upTo: 8) {
            let candidateEnd = caretLocation + endOffset
            guard candidateEnd >= 0, candidateEnd <= field.length else { continue }

            for lengthOffset in symmetricOffsets(upTo: maximumLengthAdjustment) {
                let candidateLength = expectedLength + lengthOffset
                guard candidateLength >= 0, candidateLength <= candidateEnd else { continue }

                let candidateRange = NSRange(
                    location: candidateEnd - candidateLength,
                    length: candidateLength
                )
                let candidateText = field.substring(with: candidateRange)
                if AutoLearnTextNormalizer.accessibilityComparable(candidateText)
                    == normalizedPastedText
                {
                    return candidateRange
                }
            }
        }

        return nil
    }

    /// Web editors may turn pasted boundary whitespace into their own leading
    /// space or trailing newline. Match the unchanged core exactly and leave
    /// the editor-owned whitespace outside the observed pasted range.
    private func uniqueBoundaryWhitespaceMatch(
        for pastedText: String,
        in fieldText: String
    ) -> NSRange? {
        let coreText = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coreText.isEmpty, !textIsExactlyEqual(coreText, pastedText) else {
            return nil
        }

        let matches = exactMatches(for: coreText, in: fieldText)
        return matches.count == 1 ? matches[0] : nil
    }

    private func symmetricOffsets(upTo maximum: Int) -> [Int] {
        guard maximum > 0 else { return [0] }
        var offsets = [0]
        offsets.reserveCapacity(maximum * 2 + 1)
        for offset in 1...maximum {
            offsets.append(offset)
            offsets.append(-offset)
        }
        return offsets
    }

    private func exactMatches(for pastedText: String, in fieldText: String) -> [NSRange] {
        let field = fieldText as NSString
        var searchRange = NSRange(location: 0, length: field.length)
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = field.range(of: pastedText, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)

            // Advance by one UTF-16 unit so overlapping occurrences are not skipped.
            let nextLocation = match.location + 1
            guard nextLocation < field.length else { break }
            searchRange = NSRange(location: nextLocation, length: field.length - nextLocation)
        }

        return matches
    }

    private func nearestMatch(
        in matches: [NSRange],
        near location: Int,
        pastedLength: Int
    ) -> NSRange? {
        let maximumDistance = max(pastedLength, 128)
        return matches.min {
            abs(NSMaxRange($0) - location) < abs(NSMaxRange($1) - location)
        }.flatMap {
            abs(NSMaxRange($0) - location) <= maximumDistance ? $0 : nil
        }
    }

    private func isValid(_ range: NSRange, inUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
