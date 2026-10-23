import SwiftUI
import SwiftData
import StoreKit
internal import UniformTypeIdentifiers

/// The library: generated covers under the document the reader was last
/// in, with import, sort, and search in the toolbar.
///
/// Also the navigation root. It registers the reader and chapter list
/// destinations and owns importing (the file picker, drag and drop, and the
/// File menu commands), plain-text entry, and legacy word storage migration.
/// It asks for an App Store rating when ``ReviewPrompt`` says one is due,
/// asks about iCloud sync when a ``SyncPrompt`` is waiting, shows What's New
/// once after an update (``WhatsNew``), and offers to merge books that may
/// be in the library twice (``LikelyDuplicates``).
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.requestReview) private var requestReview
    @Query(sort: \Document.dateAdded, order: .reverse) private var documents: [Document]

    @AppStorage(ReaderSettings.Keys.defaultWPM) private var defaultWPM: Int = ReaderSettings.Defaults.defaultWPM
    @AppStorage(TextCleaningLevel.storageKey) private var textCleaningLevel = TextCleaningLevel.defaultValue.rawValue
    @AppStorage(ReaderSettings.Keys.hasSeenTutorial) private var hasSeenTutorial = false
    @AppStorage(ReaderSettings.Keys.iCloudSyncPrompt) private var pendingSyncPrompt: SyncPrompt?
    @AppStorage(ReaderSettings.Keys.didCompactLegacyWordStorage) private var didCompactLegacyWordStorage = false
    @AppStorage(LibrarySortOrder.storageKey) private var librarySortOrderRaw = LibrarySortOrder.defaultValue.rawValue

    @State private var isImporting = false
    @State private var isProcessingImport = false
    @State private var importFileName = ""
    @State private var importTask: Task<Void, Never>?
    @State private var importQueue = ImportQueue()
    @State private var importError: ImportQueue.Report?
    @State private var persistenceError: String?
    @State private var showSettings = false
    @State private var showWelcome = false
    @State private var showTextInput = false
    @State private var documentPendingDeletion: Document?
    @State private var documentPendingRename: Document?
    @State private var renameText = ""
    @State private var searchText = ""
    @State private var isDropTargeted = false
    @State private var navigationPath = NavigationPath()
    @State private var isReviewingDuplicates = false

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 20, alignment: .top)]
        #else
        let minimum: CGFloat = horizontalSizeClass == .regular ? 150 : 120
        return [GridItem(.adaptive(minimum: minimum, maximum: 200), spacing: 18, alignment: .top)]
        #endif
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: librarySortOrderRaw) ?? LibrarySortOrder.defaultValue
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Documents re-sorted by the user's chosen order and filtered by the
    /// search query. The base `@Query` is already newest-first by date added.
    private var displayedDocuments: [Document] {
        var result = documents
        switch sortOrder {
        case .dateAdded:
            break
        case .lastRead:
            result.sort { ($0.lastReadDate ?? .distantPast) > ($1.lastReadDate ?? .distantPast) }
        case .title:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        let query = trimmedSearchText
        guard !query.isEmpty else { return result }
        return result.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// The most recently read document that's started but not finished.
    /// Hidden while searching, and in a one-document library, where it would
    /// repeat the only cover.
    private var continueReadingDocument: Document? {
        guard trimmedSearchText.isEmpty, documents.count > 1 else { return nil }
        return Document.mostRecentlyRead(in: documents)
    }

    /// Whether a waiting sync question can be asked: after the welcome, on
    /// the library itself (never over the reader), with nothing else up.
    private var canAskAboutSync: Bool {
        hasSeenTutorial && !showWelcome && !showSettings && !showTextInput && !isImporting
            && !isReviewingDuplicates && navigationPath.isEmpty
            && documentPendingRename == nil && documentPendingDeletion == nil
            && importError == nil && persistenceError == nil
    }

    /// Whether What's New can show: as for a sync question, which goes
    /// first when one is waiting.
    private var canShowWhatsNew: Bool {
        canAskAboutSync && pendingSyncPrompt == nil
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            libraryContent
                .navigationTitle("Library")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
                #endif
                .toolbar { libraryToolbar }
                .modifier(LibrarySearch(isEnabled: !documents.isEmpty, text: $searchText))
                // Value-based so a destination isn't built until the user
                // navigates — an eager `destination:` link would construct a
                // ReaderView (and decode word blobs) for every visible cover.
                .navigationDestination(for: Document.self) { document in
                    if document.chapters.isEmpty {
                        ReaderView(document: document)
                    } else {
                        ChapterListView(document: document)
                    }
                }
                .navigationDestination(for: ReaderRoute.self) { route in
                    ReaderView(document: route.document, startingWordIndex: route.startingWordIndex)
                }
        }
        .onChange(of: navigationPath.count) { oldCount, newCount in
            // Backing out of the reader or a book page is a natural pause,
            // never the middle of reading.
            if newCount < oldCount {
                requestReviewIfDue(atDepth: newCount)
            }
        }
        .focusedSceneValue(\.libraryActions, LibraryActions(
            importFile: { isImporting = true },
            newText: { showTextInput = true }
        ))
        #if os(iOS)
        // On macOS, settings open in the standard Settings window (Cmd+,).
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        #endif
        .welcomeSheet(isPresented: $showWelcome)
        .syncPrompt(canAsk: canAskAboutSync)
        .whatsNewAfterUpdate(canShow: canShowWhatsNew)
        .sheet(isPresented: $showTextInput) {
            TextInputView()
        }
        .sheet(isPresented: $isReviewingDuplicates) {
            LikelyDuplicatesReview()
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: DocumentImportPipeline.supportedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .alert(importError?.title ?? "Couldn't Import File", isPresented: .init(isPresent: $importError)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError?.message ?? "")
        }
        .alert("Save Error", isPresented: .init(isPresent: $persistenceError)) {
            Button("OK") { persistenceError = nil }
        } message: {
            Text(persistenceError ?? "")
        }
        .alert(
            "Rename Document",
            isPresented: .init(isPresent: $documentPendingRename),
            presenting: documentPendingRename
        ) { doc in
            TextField("Title", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    doc.title = trimmed
                    saveOrReport("Could not rename the document")
                }
                documentPendingRename = nil
            }
            Button("Cancel", role: .cancel) {
                documentPendingRename = nil
            }
        }
        .alert(
            "Delete this document?",
            isPresented: .init(isPresent: $documentPendingDeletion),
            presenting: documentPendingDeletion
        ) { doc in
            Button("Delete", role: .destructive) {
                modelContext.delete(doc)
                // Surfaced because a silently failed save rolls the delete
                // back — the document would reappear on next launch with
                // no explanation.
                saveOrReport("Could not delete the document")
                documentPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                documentPendingDeletion = nil
            }
        } message: { doc in
            Text("\u{201C}\(doc.title)\u{201D} will be permanently removed from your library.")
        }
        // A document in an open alert stays until the alert closes, even if
        // it's deleted on another device meanwhile.
        .onChange(of: documentPendingRename?.id) { old, new in
            LibrarySync.shared.documentReferenceChanged(from: old, to: new)
        }
        .onChange(of: documentPendingDeletion?.id) { old, new in
            LibrarySync.shared.documentReferenceChanged(from: old, to: new)
        }
        .onAppear {
            compactLegacyWordStorageIfNeeded()
            if !hasSeenTutorial {
                showWelcome = true
            }
        }
        .onOpenURL { url in
            if let link = AppLink(url: url) {
                AppRouter.shared.open(link)
            }
        }
        // Links go to this window rather than opening another one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        // Initial, for a request made while the app was launching.
        .onChange(of: AppRouter.shared.pendingLink, initial: true) {
            openPendingLink()
        }
    }

    // MARK: - Library content

    private var libraryContent: some View {
        Group {
            if documents.isEmpty && !isProcessingImport {
                emptyLibrary
            } else if displayedDocuments.isEmpty && !isProcessingImport {
                ContentUnavailableView.search(text: trimmedSearchText)
            } else {
                libraryGrid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { StrobeTheme.background.ignoresSafeArea() }
        #if os(macOS)
        // With no grid scrolling under it, the window toolbar would draw
        // its background as a bar over the empty state.
        .toolbarBackground(displayedDocuments.isEmpty && !isProcessingImport ? .hidden : .automatic, for: .windowToolbar)
        #endif
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            handleDrop(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                dropHighlight
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var libraryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let document = continueReadingDocument {
                    ContinueReadingCard(document: document)
                }

                if trimmedSearchText.isEmpty {
                    LikelyDuplicatesNotice(documents: documents) {
                        isReviewingDuplicates = true
                    }
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
                    if isProcessingImport {
                        ImportingTile(
                            fileName: importFileName,
                            position: importQueue.startedCount,
                            count: importQueue.queuedCount
                        ) {
                            cancelImports()
                        }
                    }
                    ForEach(displayedDocuments) { document in
                        DocumentTile(
                            document: document,
                            onRename: { beginRename(document) },
                            onDelete: { documentPendingDeletion = document }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Your Library Is Empty", systemImage: "books.vertical")
        } description: {
            Text(emptyLibraryMessage)
        } actions: {
            Button("Import File") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
            Button("New Text") {
                showTextInput = true
            }
        }
    }

    private var emptyLibraryMessage: String {
        #if os(macOS)
        "Import an EPUB, PDF, or text file, or paste text to start reading. You can also drop a file here."
        #else
        "Import an EPUB, PDF, or text file, or paste text to start reading."
        #endif
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(StrobeTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(StrobeTheme.accent.opacity(0.06), in: .rect(cornerRadius: 20, style: .continuous))
            .overlay {
                Label("Drop to Import", systemImage: "arrow.down.doc")
                    .font(.headline)
                    .foregroundStyle(StrobeTheme.accent)
            }
            .padding(12)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: - Toolbar

    // Toolbar controls stay neutral; the accent is kept for reading.
    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .tint(.primary)
        }
        #endif
        ToolbarItemGroup(placement: .primaryAction) {
            if !documents.isEmpty {
                sortMenu
                    .tint(.primary)
            }
            addMenu
                .tint(.primary)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $librarySortOrderRaw) {
                ForEach(LibrarySortOrder.allCases) { order in
                    Text(order.displayName).tag(order.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .accessibilityValue(sortOrder.displayName)
    }

    private var addMenu: some View {
        Menu {
            Button {
                isImporting = true
            } label: {
                Label("Import File…", systemImage: "doc.badge.plus")
            }
            Button {
                showTextInput = true
            } label: {
                Label("New Text…", systemImage: "text.cursor")
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuIndicator(.hidden)
    }

    // MARK: - Document actions

    private func beginRename(_ document: Document) {
        renameText = document.title
        documentPendingRename = document
    }

    /// Saves the model context, surfacing failures in the Save Error alert
    /// (mirrors `ReaderView.persistState` — `try?` here silently rolled the
    /// change back on next launch).
    private func saveOrReport(_ what: String) {
        do {
            try modelContext.save()
        } catch {
            persistenceError = "\(what): \(error.localizedDescription)"
        }
    }

    // MARK: - Links

    /// Carries out a request from outside the library: a widget tap, a
    /// `strobe://` link, or a shortcut (see ``AppRouter``).
    private func openPendingLink() {
        guard let link = AppRouter.shared.takePendingLink() else { return }
        switch link {
        case .library:
            navigationPath = NavigationPath()
        case .reader(let documentID):
            guard AppRouter.shared.openReaderDocumentID != documentID else { return }
            let descriptor = FetchDescriptor<Document>(predicate: #Predicate<Document> { $0.id == documentID })
            guard let document = try? modelContext.fetch(descriptor).first else {
                // Deleted since the widget last updated.
                navigationPath = NavigationPath()
                return
            }
            showSettings = false
            navigationPath = NavigationPath([ReaderRoute(document: document)])
        }
    }

    // MARK: - Review prompt

    /// Asks for an App Store rating if one is due. Waits a moment first, so
    /// the reader has closed and counted its words, and the prompt doesn't
    /// land during the transition.
    private func requestReviewIfDue(atDepth depth: Int) {
        Task {
            try? await Task.sleep(for: .seconds(1))
            // The reader may have been opened again in the meantime.
            guard navigationPath.count == depth else { return }
            let version = ReviewPrompt.currentAppVersion
            var prompt = ReviewPrompt.load()
            guard prompt.isDue(at: .now, appVersion: version) else { return }
            requestReview()
            prompt.recordPrompt(at: .now, appVersion: version)
            prompt.save()
        }
    }
}

/// Adds library search once there's something to search.
private struct LibrarySearch: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, placement: placement, prompt: "Search")
        } else {
            content
        }
    }

    private var placement: SearchFieldPlacement {
        #if os(iOS)
        .navigationBarDrawer(displayMode: .always)
        #else
        .automatic
        #endif
    }
}

// MARK: - Library sort order

/// User-selectable sort orders for the library grid, persisted in UserDefaults.
enum LibrarySortOrder: String, CaseIterable, Identifiable {
    static let storageKey = "librarySortOrder"
    static let defaultValue: LibrarySortOrder = .dateAdded

    case dateAdded
    case lastRead
    case title

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateAdded: "Recently Added"
        case .lastRead: "Recently Read"
        case .title: "Title"
        }
    }
}

// MARK: - Import Logic

extension ContentView {
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                importQueue.enqueue(.init(url: url, deleteAfterImport: false))
            }
            startNextImport()
        case .failure(let error):
            importError = .init(message: error.localizedDescription)
        }
    }

    /// Queues every dropped file as it loads, starting the first right away.
    private func handleDrop(_ providers: [NSItemProvider]) {
        let generation = importQueue.beginLoading(providers.count)
        for provider in providers {
            Self.loadDroppedFile(from: provider) { result in
                Task { @MainActor in
                    receiveDroppedFile(result, from: generation)
                }
            }
        }
    }

    /// Loads a dropped file via `loadInPlaceFileRepresentation`, then hands
    /// `completion` the file to import or why it can't be. The raw `fileURL`
    /// item is unusable on iOS — it points into the source app's sandbox
    /// with no security scope, so opening it fails with a misleading
    /// "corrupted file" error. The in-place/copied representation is
    /// readable; the system reclaims copies when the handler returns, so
    /// they're cloned out first.
    nonisolated private static func loadDroppedFile(
        from provider: NSItemProvider,
        completion: @escaping @Sendable (ImportQueue.DropResult) -> Void
    ) {
        let supported = DocumentImportPipeline.supportedContentTypes
        let typeID = provider.registeredTypeIdentifiers.first { id in
            guard let type = UTType(id) else { return false }
            return supported.contains { type.conforms(to: $0) }
        }

        guard let typeID else {
            // A Finder drag on macOS lists only the file's URL, never its
            // type, so the type has to come from the file itself.
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                completion(Self.untypedDropResult(for: url))
            }
            return
        }

        let suggestedName = provider.suggestedName
        _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeID) { url, inPlace, _ in
            guard let url else {
                completion(.rejected(.unreadable(fileName: suggestedName)))
                return
            }
            if inPlace {
                completion(.file(.init(url: url, deleteAfterImport: false)))
                return
            }
            // The system deletes this copy when the handler returns —
            // clone it to our own temp location first.
            do {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("drop_\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let copy = dir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                completion(.file(.init(url: copy, deleteAfterImport: true)))
            } catch {
                completion(.rejected(.unreadable(fileName: url.lastPathComponent)))
            }
        }
    }

    /// A dropped file whose drag didn't list its type: imported if the file
    /// is one Strobe reads. Only on macOS: there the drag grants access to
    /// the URL itself, while on iOS it's unreadable and only names the file.
    nonisolated private static func untypedDropResult(for url: URL?) -> ImportQueue.DropResult {
        guard let url else { return .rejected(.unsupported(fileName: nil)) }
        #if os(macOS)
        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if DocumentImportPipeline.resolveSourceType(for: url, detectedContentType: contentType) != .unknown {
            return .file(.init(url: url, deleteAfterImport: false))
        }
        #endif
        return .rejected(.unsupported(fileName: url.lastPathComponent))
    }

    private func receiveDroppedFile(_ result: ImportQueue.DropResult, from generation: Int) {
        guard importQueue.receive(result, from: generation) else {
            // Its batch was cancelled while it loaded.
            if case .file(let item) = result, item.deleteAfterImport {
                try? FileManager.default.removeItem(at: item.url)
            }
            return
        }
        startNextImport()
    }

    /// Starts the next waiting file unless one is importing. Once nothing is
    /// left, reports the batch's failures in one alert.
    private func startNextImport() {
        guard !isProcessingImport else { return }
        if let item = importQueue.next() {
            importDocument(item)
        } else if let report = importQueue.finishBatch() {
            importError = report
        }
    }

    /// The importing tile's Cancel: stops the running import and drops the
    /// files waiting behind it.
    private func cancelImports() {
        for item in importQueue.cancel() where item.deleteAfterImport {
            try? FileManager.default.removeItem(at: item.url)
        }
        importTask?.cancel()
    }

    private func importDocument(_ item: ImportQueue.Item) {
        let url = item.url
        let deleteAfterImport = item.deleteAfterImport
        let isSecurityScoped = url.startAccessingSecurityScopedResource()

        let bookmarkData: Data
        #if os(iOS)
        let bookmarkOptions: URL.BookmarkCreationOptions = .minimalBookmark
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #endif
        if let data = try? url.bookmarkData(
            options: bookmarkOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            bookmarkData = data
        } else {
            bookmarkData = Data()
        }

        isProcessingImport = true
        importFileName = url.lastPathComponent
        let fileName = url.lastPathComponent

        importTask = Task(priority: .userInitiated) {
            defer {
                if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                if deleteAfterImport { try? FileManager.default.removeItem(at: url) }
                isProcessingImport = false
                importFileName = ""
                importTask = nil
                startNextImport()
            }

            do {
                let cleaningLevel = TextCleaningLevel.resolve(textCleaningLevel)
                // The storage blobs are encoded on the background task too —
                // encoding a book-length word array is ~2 MB of work that
                // would otherwise hitch the main thread at import completion.
                let extraction = Task.detached(priority: .userInitiated) {
                    () -> (result: ImportResult, wordsBlob: Data, complexityBlob: Data?) in
                    let detectedType = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
                    let result = try DocumentImportPipeline.extractWordsAndChapters(
                        from: url,
                        detectedContentType: detectedType,
                        cleaningLevel: cleaningLevel
                    )
                    try Task.checkCancellation()
                    let wordsBlob = WordStorage.encode(result.words)
                    let complexityBlob = result.complexityScores.isEmpty
                        ? nil
                        : ComplexityStorage.encode(result.complexityScores)
                    return (result, wordsBlob, complexityBlob)
                }
                // Detached tasks don't inherit cancellation — forward the
                // overlay's Cancel to the extraction work explicitly.
                let extracted = try await withTaskCancellationHandler {
                    try await extraction.value
                } onCancel: {
                    extraction.cancel()
                }
                try Task.checkCancellation()

                guard !extracted.result.words.isEmpty else {
                    throw DocumentImportError.noReadableText
                }

                let title = DocumentImportPipeline.resolveTitle(
                    metadataTitle: extracted.result.title,
                    fileName: fileName
                )

                let document = Document(
                    title: title,
                    fileName: fileName,
                    bookmarkData: bookmarkData,
                    wordsBlob: extracted.wordsBlob,
                    wordCount: extracted.result.words.count,
                    complexityBlob: extracted.complexityBlob,
                    chapters: extracted.result.chapters,
                    wordsPerMinute: defaultWPM
                )
                modelContext.insert(document)
                try modelContext.save()
            } catch is CancellationError {
                // User cancelled — no alert.
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                importQueue.record(.failed(fileName: fileName, message: message))
            }
        }
    }

    private func compactLegacyWordStorageIfNeeded() {
        // One-time pass. Touching `wordsBlob`/`words` on every document
        // faults every row (and can pull external blobs) on the main thread —
        // without this flag, every launch paid that for an empty check.
        guard !didCompactLegacyWordStorage else { return }
        var didCompact = false
        for document in documents where document.wordsBlob == nil && !document.words.isEmpty {
            document.compactWordStorageIfNeeded()
            didCompact = true
        }
        if didCompact {
            do {
                try modelContext.save()
            } catch {
                // Leave the flag unset so the next launch retries.
                importError = .init(message: "Could not migrate document storage: \(error.localizedDescription)")
                return
            }
        }
        didCompactLegacyWordStorage = true
    }
}
