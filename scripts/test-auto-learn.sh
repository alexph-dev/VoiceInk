#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
xcrun swiftc VoiceInk/Features/Dictionary/AutoLearn/AutoLearnTypes.swift \
    VoiceInk/Features/Dictionary/AutoLearn/CorrectionDiffEngine.swift \
    VoiceInk/Features/Dictionary/AutoLearn/AutoLearnLocalReviewer.swift \
    Tests/AutoLearn/main.swift -o "$test_dir/auto-learn-tests"
"$test_dir/auto-learn-tests"
