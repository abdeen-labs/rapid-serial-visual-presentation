import SwiftUI
import SwiftData
import PhotosUI

extension View {
    /// Edit Cover for the library: while `document` is set, asks what to do
    /// with its cover (see ``CoverEditor``).
    func editsCover(of document: Binding<Document?>) -> some View {
        modifier(CoverEditor(document: document))
    }
}

/// Edit Cover, from a document's menu in the library: put a photo in the
/// cover's place, or remove the cover so the generated one shows.
///
/// Strobe keeps no copy of the imported file, so a book's own cover that is
/// replaced or removed can't be brought back short of importing the book
/// again. The dialog says so for a document that has a cover to lose. Every
/// change goes through ``Document/setCover(_:)`` and is saved, which sync
/// and the widget follow.
struct CoverEditor: ViewModifier {
    /// The document whose cover is being edited: set to ask, cleared when
    /// the dialog closes.
    @Binding var document: Document?
    @Environment(\.modelContext) private var modelContext
    /// The document a photo is being picked for, once the dialog has
    /// closed, until the photo is in place or the picker is dismissed.
    @State private var photoTarget: Document?
    @State private var isPickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var isLoadingPhoto = false
    @State private var photoFailed = false
    @State private var saveError: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Edit Cover",
                isPresented: .init(isPresent: $document),
                titleVisibility: .visible,
                presenting: document
            ) { document in
                Button("Choose Photo…") {
                    photoTarget = document
                    isPickingPhoto = true
                }
                if document.coverFingerprint != nil {
                    Button("Remove Cover", role: .destructive) {
                        document.setCover(nil)
                        save()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { document in
                if document.coverFingerprint != nil {
                    Text("Replacing or removing this cover can't be undone.")
                }
            }
            .photosPicker(isPresented: $isPickingPhoto, selection: $pickedPhoto, matching: .images)
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                isLoadingPhoto = true
                Task { await use(item) }
            }
            .onChange(of: isPickingPhoto) { _, isPicking in
                // Dismissed without a photo.
                if !isPicking, pickedPhoto == nil, !isLoadingPhoto { photoTarget = nil }
            }
            // A document being edited stays until it's done, even if it's
            // deleted on another device meanwhile.
            .onChange(of: document?.id) { old, new in
                LibrarySync.shared.documentReferenceChanged(from: old, to: new)
            }
            .onChange(of: photoTarget?.id) { old, new in
                LibrarySync.shared.documentReferenceChanged(from: old, to: new)
            }
            .alert("Couldn't Use That Photo", isPresented: $photoFailed) {
                Button("OK") {}
            }
            .alert("Save Error", isPresented: .init(isPresent: $saveError)) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
    }

    /// Makes the picked photo the cover: loaded, then scaled and encoded
    /// off the main actor as an imported cover is (``CoverImage``).
    private func use(_ item: PhotosPickerItem) async {
        defer {
            isLoadingPhoto = false
            photoTarget = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            photoFailed = true
            return
        }
        let cover = await Task.detached(priority: .userInitiated) {
            CoverImage.encode(imageData: data)
        }.value
        guard let cover else {
            photoFailed = true
            return
        }
        // Gone meanwhile, as when the library was replaced.
        guard let target = photoTarget, !target.isDeleted, target.modelContext != nil else { return }
        target.setCover(cover)
        save()
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            saveError = "Could not save the cover: \(error.localizedDescription)"
        }
    }
}
