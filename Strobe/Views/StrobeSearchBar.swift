import SwiftUI

/// The passage view's search bar: magnifying-glass icon, plain text field,
/// and a clear button in a capsule of the reader's glass, like the system's
/// search fields.
///
/// The bare `TextField` is handed to `configureField` so each call site can
/// attach its own focus, submit handling, and platform input modifiers
/// without this component needing to know about them.
struct StrobeSearchBar<Field: View>: View {
    let placeholder: String
    @Binding var text: String
    /// Runs when the clear button is tapped. Defaults to clearing `text`;
    /// call sites with extra search state to reset pass their own action.
    var onClear: (() -> Void)? = nil
    @ViewBuilder let configureField: (TextField<Text>) -> Field

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            configureField(TextField(placeholder, text: $text))
                .foregroundStyle(.primary)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    if let onClear {
                        onClear()
                    } else {
                        text = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        // The glyph alone is a ~17pt target; pad the hit area
                        // toward the 44pt minimum without growing the bar.
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.body)
        .padding(.leading, 14)
        .padding(.trailing, text.isEmpty ? 14 : 4)
        .frame(minHeight: 44)
        .readerGlass(in: Capsule())
    }
}
