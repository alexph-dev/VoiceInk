import Foundation

let original = "Send the report to Нтн team today please."
let firstEdit = "Send the report to n8n team today please."
let secondEdit = "Send the report to n8n team tomorrow please."
var submitted = Set<String>()

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        print("FAIL: \(message)")
        exit(1)
    }
}

let first = CorrectionDiffEngine.candidates(
    from: .init(original: original, corrected: firstEdit), excluding: &submitted)
require(first.count == 1, "The first idle edit must produce one candidate")

let second = CorrectionDiffEngine.candidates(
    from: .init(original: original, corrected: secondEdit), excluding: &submitted)
require(second.count == 1, "A nearby edit must not resubmit the previously observed correction")
let pair = CorrectionDiffEngine.replacementPair(
    from: .init(original: second[0].originalText, corrected: second[0].correctedText))
require(pair?.source == "today" && pair?.destination == "tomorrow", "Only the newly edited word is submitted")

let final = CorrectionDiffEngine.candidates(
    from: .init(original: original, corrected: secondEdit), excluding: &submitted)
require(final.isEmpty, "The final snapshot must not count either edit again")

submitted = []
let nextSession = CorrectionDiffEngine.candidates(
    from: .init(original: original, corrected: firstEdit), excluding: &submitted)
require(nextSession.count == 1, "A new dictation can count the same real correction again")
print("Auto Learn idle/final correction identity: passed")
