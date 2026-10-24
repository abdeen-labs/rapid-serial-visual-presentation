import SwiftUI

/// The open-source work Strobe ships or downloads (``Acknowledgements``),
/// by group, each opening its copyright lines and full license. Pushed from
/// Settings on iOS; a sheet over the Settings window on macOS
/// (``AcknowledgementsSheet``).
struct AcknowledgementsView: View {
    var body: some View {
        Form {
            ForEach(Acknowledgements.groups) { group in
                Section {
                    ForEach(group.credits) { credit in
                        NavigationLink {
                            AcknowledgementDetailView(credit: credit)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(credit.name)
                                Text("\(credit.author) · \(credit.license.name)")
                                    .font(StrobeTheme.metadataFont)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    Text(group.summary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Acknowledgements")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// One credit: who made it, its copyright lines, any NOTICE file, and the
/// full license text.
private struct AcknowledgementDetailView: View {
    let credit: Acknowledgements.Credit

    var body: some View {
        Form {
            Section {
                LabeledContent("By", value: credit.author)
                LabeledContent("License", value: credit.license.name)
                ExternalLinkRow(title: "Website", url: credit.url)
            } footer: {
                if let note = credit.note {
                    Text(note)
                }
            }

            if !credit.notices.isEmpty {
                Section("Copyright") {
                    Text(credit.notices.joined(separator: "\n"))
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }

            if let noticeFile = credit.noticeFile {
                Section("Notice") {
                    Text(noticeFile)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }

            Section(credit.license.name) {
                Text(credit.license.text)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(credit.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if os(macOS)
/// The acknowledgements in a sheet of their own, since the Settings
/// window's tabs have no navigation to push onto.
struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AcknowledgementsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        .frame(width: 520, height: 620)
    }
}
#endif
