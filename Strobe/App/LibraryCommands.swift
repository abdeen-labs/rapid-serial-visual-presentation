import SwiftUI

/// The library's File menu actions, published by `ContentView` for the
/// app's menu bar commands.
struct LibraryActions {
    let importFile: () -> Void
    let newText: () -> Void
}

nonisolated private struct LibraryActionsKey: FocusedValueKey {
    typealias Value = LibraryActions
}

extension FocusedValues {
    nonisolated var libraryActions: LibraryActions? {
        get { self[LibraryActionsKey.self] }
        set { self[LibraryActionsKey.self] = newValue }
    }
}

/// File ▸ New Text… (⌘N) and Import File… (⌘O), in place of New Window.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Text…") {
                actions?.newText()
            }
            .keyboardShortcut("n")
            .disabled(actions == nil)

            Button("Import File…") {
                actions?.importFile()
            }
            .keyboardShortcut("o")
            .disabled(actions == nil)
        }
    }
}
