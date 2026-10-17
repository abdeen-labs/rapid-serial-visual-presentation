import SwiftUI
import SwiftData

/// Copies of one book that the library may hold more than once, as the
/// notice and the review show them (see ``LikelyDuplicates``).
struct DuplicateGroup: Identifiable {
    let documents: [Document]

    var id: [UUID] { documents.map(\.id) }

    /// The library's likely duplicates, less the groups kept on this device,
    /// in library order. Empty until iCloud sync is running and has fetched
    /// everything (`LibrarySync.isReadyForDuplicateReview`); a view that asks
    /// reads sync's status, so it asks again as sync works.
    static func find(in documents: [Document], kept: KeptLikelyDuplicates) -> [DuplicateGroup] {
        let sync = LibrarySync.shared
        guard sync.isReadyForDuplicateReview else { return [] }
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = documents.map { document in
            LikelyDuplicates.Candidate(
                id: document.id,
                title: document.title,
                fileName: document.fileName,
                wordCount: document.wordCount,
                origin: sync.origin(ofDocument: document.id),
                isLeaving: sync.isLeavingLibrary(document.id)
            )
        }
        let groups = LikelyDuplicates.groups(among: candidates, kept: kept) { a, b in
            guard let first = byID[a.id], let second = byID[b.id] else { return false }
            return sync.haveSameWords(first, second)
        }
        return groups.map { ids in
            DuplicateGroup(documents: ids.compactMap { byID[$0] })
        }
    }
}

// MARK: - Notice

/// A row above the library grid when some books may be in the library more
/// than once, with a button that opens the review. Nothing otherwise.
struct LikelyDuplicatesNotice: View {
    let documents: [Document]
    let review: () -> Void
    @AppStorage(ReaderSettings.Keys.keptLikelyDuplicates) private var kept = KeptLikelyDuplicates()

    var body: some View {
        let groups = DuplicateGroup.find(in: documents, kept: kept)
        if !groups.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "square.on.square")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(Self.message(for: groups))
                    .font(messageFont)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Neutral: red is for reading.
                Button("Review", action: review)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(.primary)
                    .accessibilityHint("Shows the copies so you can keep one")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(StrobeTheme.elevatedSurface, in: .rect(cornerRadius: 12, style: .continuous))
        }
    }

    private static func message(for groups: [DuplicateGroup]) -> String {
        let books = groups.count == 1 ? "1 book" : "\(groups.count) books"
        let often = groups.allSatisfy { $0.documents.count == 2 } ? "twice" : "more than once"
        return "\(books) may be in your library \(often)"
    }

    private var messageFont: Font {
        #if os(macOS)
        .body
        #else
        .subheadline
        #endif
    }
}

// MARK: - Review

/// Lists the likely duplicates for the user to settle, a section per book:
/// keep one copy, which takes the reading of the copy read most recently
/// while the others leave the library on every device, or keep them all,
/// which this device remembers. Closes once nothing is left to settle.
struct LikelyDuplicatesReview: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Document.dateAdded, order: .reverse) private var documents: [Document]
    @AppStorage(ReaderSettings.Keys.keptLikelyDuplicates) private var kept = KeptLikelyDuplicates()
    @State private var saveError: String?
    @State private var copiesChanged = false

    var body: some View {
        let groups = DuplicateGroup.find(in: documents, kept: kept)

        sheetContainer(groups: groups)
            .onChange(of: groups.isEmpty) { _, isEmpty in
                // The last book is settled, or sync stopped. With an alert
                // up, the sheet stays until it's read.
                if isEmpty && saveError == nil && !copiesChanged { dismiss() }
            }
            .alert("Save Error", isPresented: .init(isPresent: $saveError)) {
                Button("OK") {
                    saveError = nil
                    if groups.isEmpty { dismiss() }
                }
            } message: {
                Text(saveError ?? "")
            }
            .alert("Nothing Was Removed", isPresented: $copiesChanged) {
                Button("OK", role: .cancel) {
                    if groups.isEmpty { dismiss() }
                }
            } message: {
                Text("One of these copies changed in iCloud since the list opened. Check the list and try again.")
            }
    }

    @ViewBuilder
    private func sheetContainer(groups: [DuplicateGroup]) -> some View {
        #if os(iOS)
        NavigationStack {
            form(groups: groups)
                .navigationTitle("Possible Duplicates")
                .navigationBarTitleDisplayMode(.inline)
        }
        #else
        // A macOS sheet shows no navigation title.
        VStack(spacing: 0) {
            Text("Possible Duplicates")
                .font(.headline)
                .padding(.top, 18)
            form(groups: groups)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 620)
        #endif
    }

    private func form(groups: [DuplicateGroup]) -> some View {
        Form {
            ForEach(groups) { group in
                section(for: group)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No Duplicates",
                    systemImage: "checkmark.circle",
                    description: Text("Each book is in your library once.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func section(for group: DuplicateGroup) -> some View {
        let isPair = group.documents.count == 2
        let keepAllTitle = isPair ? "Keep Both" : "Keep All"
        let footer = isPair
            ? "Keeping one removes the other from your library on all your devices. Your reading position carries over to the copy you keep."
            : "Keeping one removes the others from your library on all your devices. Your reading position carries over to the copy you keep."

        return Section {
            ForEach(group.documents) { document in
                DuplicateCopyRow(document: document) {
                    keep(document, from: group)
                }
            }
            // Neutral, like Keep This One: red is for reading.
            Button(keepAllTitle) {
                keepAll(group)
            }
            .tint(.primary)
        } header: {
            // What the copies have in common besides the title.
            if let fileName = group.documents.first?.fileName {
                Text(fileName)
                    .textCase(nil)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } footer: {
            Text(footer)
        }
    }

    /// Keeps `keeper` and removes the group's other copies. The keeper takes
    /// the reading of the copy read most recently, carried over in
    /// proportion to the copies' lengths, and the furthest progress of any
    /// (`LikelyDuplicates.mergedReading`). It's an ordinary edit and
    /// deletions, saved once, so sync carries it to every device.
    private func keep(_ keeper: Document, from group: DuplicateGroup) {
        let sync = LibrarySync.shared
        // Sync may have moved on since the list was drawn. A copy deleted on
        // another device stays while it's shown and leaves once the sheet
        // closes, so keeping it would lose the book.
        guard sync.isReadyForDuplicateReview,
              group.documents.allSatisfy({ !sync.isLeavingLibrary($0.id) }) else {
            copiesChanged = true
            return
        }
        let others = group.documents.filter { $0.id != keeper.id }
        let position = LikelyDuplicates.mergedReading(
            keeping: LikelyDuplicates.Reading(document: keeper),
            others: others.map { LikelyDuplicates.Reading(document: $0) }
        )
        keeper.applyReadingPosition(position)
        for other in others {
            modelContext.delete(other)
        }
        // Reported like `ContentView.saveOrReport`: a save that fails
        // silently would bring the copies back at the next launch.
        do {
            try modelContext.save()
        } catch {
            saveError = "Could not remove the other copies: \(error.localizedDescription)"
        }
    }

    /// Keeps every copy, and stops offering this group on this device until
    /// another copy joins it.
    private func keepAll(_ group: DuplicateGroup) {
        kept.keep(group.id, library: Set(documents.map(\.id)))
    }
}

/// One copy in the review: a small cover, the title, and what tells the
/// copies apart, with the button that keeps it.
private struct DuplicateCopyRow: View {
    let document: Document
    let keep: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DocumentCover(document: document, showsText: false)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.title)
                        .font(StrobeTheme.displayFont(size: 17, relativeTo: .headline))
                        .lineLimit(2)
                        .padding(.bottom, 2)
                    Group {
                        Text(lengthLine)
                        Text(datesLine)
                        if let originLine {
                            Text(originLine)
                        }
                    }
                    .font(StrobeTheme.metadataFont)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .accessibilityElement(children: .combine)

                Button("Keep This One", action: keep)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.primary)
                    .padding(.top, 10)
                    .accessibilityHint("Removes the other copies from all your devices")
            }
        }
        .padding(.vertical, 4)
        // A copy deleted on another device stays while it's shown here.
        .marksDocumentOpen(document.id)
    }

    private var lengthLine: String {
        let words = document.wordCount == 1 ? "1 word" : "\(document.wordCount.formatted()) words"
        return "\(words) · \(document.readingStatus.label)"
    }

    private var datesLine: String {
        let added = "Added \(document.dateAdded.formatted(date: .abbreviated, time: .omitted))"
        guard let lastRead = document.lastReadDate else { return added }
        return "\(added) · Last read \(lastRead.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Nil when sync doesn't know, rather than guess.
    private var originLine: String? {
        switch LibrarySync.shared.origin(ofDocument: document.id) {
        case .importedHere: "Added on this device"
        case .fromICloud: "From iCloud"
        case nil: nil
        }
    }
}

private extension LikelyDuplicates.Reading {
    @MainActor
    init(document: Document) {
        self.init(wordCount: document.wordCount, position: document.readingPosition)
    }
}
