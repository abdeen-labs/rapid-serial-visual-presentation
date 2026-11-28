import Foundation

/// The ``ResumePreview`` of each document the library shows one for: the
/// Continue Reading card's document and the widget's up-next one.
///
/// Working one out reads the words around the resume position out of the
/// stored blob, off the main actor, so it's kept by document and resume
/// position and worked out again only when either changes. Until then the
/// last preview worked out for the document stays, so the card doesn't
/// lose its text and change height while the new one is under way.
@Observable
final class ResumePreviews {
    static let shared = ResumePreviews()

    /// What a preview holds for. A document's words never change, so its
    /// resume position is all that moves its preview.
    nonisolated struct Key: Hashable, Sendable {
        let documentID: UUID
        let resumeIndex: Int
    }

    private struct Entry {
        let key: Key
        let text: String?
    }

    private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var pending: [UUID: (key: Key, task: Task<Void, Never>)] = [:]

    func key(for document: Document) -> Key {
        Key(documentID: document.id, resumeIndex: document.currentWordIndex)
    }

    /// The latest preview worked out for `document`, perhaps for an earlier
    /// resume position while ``prepare(_:)`` works out the current one. Nil
    /// until one is worked out, or when the document has no words. Never
    /// starts the work.
    func preview(for document: Document) -> String? {
        entries[document.id]?.text
    }

    /// Whether ``preview(for:)`` holds for `document`'s current resume
    /// position.
    func isCurrent(for document: Document) -> Bool {
        entries[document.id]?.key == key(for: document)
    }

    /// Starts working out `document`'s preview at its resume position,
    /// unless it's known or under way. The blobs are read here and the
    /// words around the position decoded off the main actor. Views call
    /// this from `.task(id: key(for:))`.
    func prepare(_ document: Document) {
        let key = self.key(for: document)
        guard entries[key.documentID]?.key != key, pending[key.documentID]?.key != key else { return }

        let wordsBlob = document.wordsBlob
        let legacyWords = wordsBlob?.isEmpty == false ? [] : document.words
        let blockEndsBlob = document.blockEndsBlob
        let chapters = document.chapters
        let task = Task {
            let text = await Task.detached(priority: .utility) {
                let window = ResumePreview.window(around: key.resumeIndex)
                let words: [String]
                let firstIndex: Int
                if let wordsBlob, !wordsBlob.isEmpty {
                    words = WordStorage.decode(wordsBlob, range: window)
                    firstIndex = window.lowerBound
                } else {
                    let clamped = window.clamped(to: legacyWords.indices)
                    words = Array(legacyWords[clamped])
                    firstIndex = clamped.lowerBound
                }
                return ResumePreview.text(
                    words: words,
                    firstIndex: firstIndex,
                    resumeIndex: key.resumeIndex,
                    blockEnds: BlockEndStorage.decode(blockEndsBlob),
                    chapters: chapters
                )
            }.value
            self.finish(key, text: text)
        }
        pending[key.documentID] = (key, task)
    }

    /// Waits for the preview under way for a document, if any.
    func waitForPending(_ documentID: UUID) async {
        if let task = pending[documentID]?.task {
            await task.value
        }
    }

    /// Stores a finished preview unless a newer request for the document
    /// replaced it.
    private func finish(_ key: Key, text: String?) {
        guard pending[key.documentID]?.key == key else { return }
        pending[key.documentID] = nil
        entries[key.documentID] = Entry(key: key, text: text)
    }
}
