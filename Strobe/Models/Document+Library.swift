import Foundation

extension Document {
    var progressPercentage: Int {
        Int(progress * 100)
    }

    var kind: DocumentKind {
        DocumentKind(fileName: fileName)
    }

    var readingStatus: ReadingStatus {
        ReadingStatus(progress: progress)
    }

    /// Words after the resume position.
    var remainingWordCount: Int {
        max(0, wordCount - 1 - currentWordIndex)
    }

    /// Minutes to finish from the resume position at the document's speed,
    /// which counts the timing settings' pauses (see ``ReadingPace``).
    var remainingMinutes: Int {
        ReadingTime.minutes(words: remainingWordCount, wordsPerMinute: wordsPerMinute)
    }
}
