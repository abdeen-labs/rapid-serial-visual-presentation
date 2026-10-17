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
    /// stretched by its ``ReadingPace`` factor. Nil, before the factor is
    /// known, gives the plain estimate.
    func remainingMinutes(paceFactor: Double?) -> Int {
        ReadingTime.minutes(words: remainingWordCount, wordsPerMinute: wordsPerMinute, paceFactor: paceFactor ?? 1)
    }
}
