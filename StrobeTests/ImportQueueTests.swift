import Foundation
import Testing
@testable import Strobe

struct ImportQueueTests {

    private typealias Item = ImportQueue.Item

    private static func item(_ name: String, copy: Bool = false) -> Item {
        Item(url: URL(fileURLWithPath: "/tmp/\(name)"), deleteAfterImport: copy)
    }

    // MARK: - Order and position

    @Test func filesImportInTheOrderTheyArrive() {
        var queue = ImportQueue()
        queue.enqueue(Self.item("a.epub"))
        queue.enqueue(Self.item("b.pdf"))

        let first = queue.next()
        #expect(first == Self.item("a.epub"))
        #expect(queue.startedCount == 1)
        #expect(queue.queuedCount == 2)

        let second = queue.next()
        #expect(second == Self.item("b.pdf"))
        #expect(queue.startedCount == 2)
        #expect(queue.queuedCount == 2)

        let none = queue.next()
        #expect(none == nil)
    }

    @Test func filesQueuedDuringABatchJoinIt() {
        var queue = ImportQueue()
        queue.enqueue(Self.item("a.epub"))
        _ = queue.next()
        queue.enqueue(Self.item("b.epub"))

        #expect(queue.startedCount == 1)
        #expect(queue.queuedCount == 2)
    }

    @Test func aFinishedBatchCountsFromOneAgain() {
        var queue = ImportQueue()
        queue.enqueue(Self.item("a.epub"))
        queue.enqueue(Self.item("b.epub"))
        _ = queue.next()
        _ = queue.next()
        _ = queue.finishBatch()

        queue.enqueue(Self.item("c.epub"))
        _ = queue.next()
        #expect(queue.startedCount == 1)
        #expect(queue.queuedCount == 1)
    }

    // MARK: - Drops

    @Test func droppedFilesQueueAsTheyLoad() {
        var queue = ImportQueue()
        let generation = queue.beginLoading(2)

        let received = queue.receive(.file(Self.item("a.epub", copy: true)), from: generation)
        #expect(received)
        #expect(queue.pending == [Self.item("a.epub", copy: true)])
    }

    @Test func theBatchWaitsForDropsStillLoading() {
        var queue = ImportQueue()
        let generation = queue.beginLoading(2)
        _ = queue.receive(.rejected(.unsupported(fileName: "a.docx")), from: generation)

        let early = queue.finishBatch()
        #expect(early == nil)
        #expect(queue.failures.count == 1)

        _ = queue.receive(.rejected(.unsupported(fileName: "b.docx")), from: generation)
        let report = queue.finishBatch()
        #expect(report?.title == "Couldn't Import Files")
        #expect(queue.failures.isEmpty)
    }

    @Test func theBatchWaitsForWaitingFiles() {
        var queue = ImportQueue()
        queue.record(.unsupported(fileName: "a.docx"))
        queue.enqueue(Self.item("b.epub"))

        let early = queue.finishBatch()
        #expect(early == nil)
    }

    // MARK: - Cancel

    @Test func cancelReturnsTheWaitingFiles() {
        var queue = ImportQueue()
        queue.enqueue(Self.item("a.epub"))
        queue.enqueue(Self.item("b.epub", copy: true))
        _ = queue.next()

        let dropped = queue.cancel()
        #expect(dropped == [Self.item("b.epub", copy: true)])
        #expect(queue.pending.isEmpty)
    }

    @Test func dropsLoadingAtCancelAreIgnored() {
        var queue = ImportQueue()
        let generation = queue.beginLoading(1)
        _ = queue.cancel()

        let received = queue.receive(.file(Self.item("a.epub", copy: true)), from: generation)
        #expect(!received)
        #expect(queue.pending.isEmpty)

        // Nothing left loading, so the batch can end.
        let report = queue.finishBatch()
        #expect(report == nil)
    }

    @Test func aDropAfterCancelStillQueues() {
        var queue = ImportQueue()
        _ = queue.beginLoading(1)
        _ = queue.cancel()

        let generation = queue.beginLoading(1)
        let received = queue.receive(.file(Self.item("a.epub")), from: generation)
        #expect(received)
        #expect(queue.pending == [Self.item("a.epub")])
    }

    @Test func failuresBeforeCancelAreStillReported() {
        var queue = ImportQueue()
        queue.enqueue(Self.item("a.pdf"))
        queue.enqueue(Self.item("b.pdf"))
        queue.enqueue(Self.item("c.pdf"))
        _ = queue.next()
        queue.record(.failed(fileName: "a.pdf", message: "Could not open this PDF file."))
        _ = queue.next()
        _ = queue.cancel()

        let report = queue.finishBatch()
        #expect(report?.message == "1 of 2 files couldn't be imported.\n\na.pdf: Could not open this PDF file.")
    }

    // MARK: - Reports

    @Test func aBatchWithNoFailuresReportsNothing() {
        var queue = ImportQueue()
        queue.enqueue(Self.item("a.epub"))
        _ = queue.next()

        let report = queue.finishBatch()
        #expect(report == nil)
    }

    @Test func aLoneFileGetsItsOwnMessage() {
        var queue = ImportQueue()
        queue.enqueue(Self.item("a.pdf"))
        _ = queue.next()
        queue.record(.failed(fileName: "a.pdf", message: "This PDF is password-protected."))

        let report = queue.finishBatch()
        #expect(report == ImportQueue.Report(message: "This PDF is password-protected."))
    }

    @Test func aLoneUnsupportedDropNamesTheFile() {
        var queue = ImportQueue()
        let generation = queue.beginLoading(1)
        _ = queue.receive(.rejected(.unsupported(fileName: "notes.docx")), from: generation)

        let report = queue.finishBatch()
        #expect(report?.title == "Couldn't Import File")
        #expect(report?.message == "\"notes.docx\" isn't a supported file type. Drop a PDF, EPUB, or text file.")
    }

    @Test func oneFailureAmongSeveralIsListed() {
        let report = ImportQueue.report(
            for: [.unreadable(fileName: "b.epub")],
            fileCount: 3
        )
        #expect(report?.title == "Couldn't Import File")
        #expect(report?.message == "1 of 3 files couldn't be imported.\n\nb.epub: couldn't be read.")
    }

    @Test func severalFailuresAreListedTogether() {
        let report = ImportQueue.report(
            for: [
                .unsupported(fileName: "a.docx"),
                .failed(fileName: "b.epub", message: "This EPUB is DRM-protected."),
            ],
            fileCount: 5
        )
        #expect(report?.title == "Couldn't Import Files")
        #expect(report?.message == """
            2 of 5 files couldn't be imported.

            a.docx: not a PDF, EPUB, or text file.
            b.epub: This EPUB is DRM-protected.
            """)
    }

    @Test func allFailingSaysNone() {
        let report = ImportQueue.report(
            for: [.unsupported(fileName: "a.docx"), .unsupported(fileName: nil)],
            fileCount: 2
        )
        #expect(report?.message == """
            None of the 2 files could be imported.

            a.docx: not a PDF, EPUB, or text file.
            One file isn't a PDF, EPUB, or text file.
            """)
    }

    @Test func aLongListSumsUpTheRest() {
        let failures = (1...8).map { ImportQueue.Failure.unreadable(fileName: "\($0).epub") }
        let report = ImportQueue.report(for: failures, fileCount: 21)
        let lines = report?.message.components(separatedBy: "\n") ?? []

        #expect(lines.first == "8 of 21 files couldn't be imported.")
        #expect(lines.count == 2 + ImportQueue.maxListedFailures + 1)
        #expect(lines.last == "And 3 more.")
    }
}
