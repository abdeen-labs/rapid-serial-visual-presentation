import SwiftUI

/// App settings: a grouped form in a sheet on iOS, with timing, the
/// while-reading options, and reading aloud on their own pages; a tabbed
/// Settings window on macOS. Both are built from the same sections. The
/// Read Aloud page shows only on a device that can run the voice model
/// (``KokoroVoiceModel/isSupported``).
struct SettingsView: View {
    @State private var showWelcome = false
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    var body: some View {
        #if os(macOS)
        TabView {
            Form {
                Section {
                    ReaderPreview()
                }
                ReadingAppearanceSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("Reading", systemImage: "textformat.size") }

            Form {
                TimingSections()
            }
            .formStyle(.grouped)
            .tabItem { Label("Timing", systemImage: "timer") }

            Form {
                WhileReadingSections()
            }
            .formStyle(.grouped)
            .tabItem { Label("Display", systemImage: "eye") }

            if KokoroVoiceModel.isSupported {
                Form {
                    ReadAloudSettingsSections()
                }
                .formStyle(.grouped)
                .keepsVoiceModelLoaded()
                .tabItem { Label("Read Aloud", systemImage: "speaker.wave.2") }
            }

            Form {
                ReadingControlsSection()
                ImportSettingsSection()
                SyncSettingsSection()
                AboutSection(showWelcome: $showWelcome)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 680)
        .welcomeSheet(isPresented: $showWelcome)
        #else
        NavigationStack {
            Form {
                Section {
                    ReaderPreview()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                ReadingAppearanceSection()

                Section {
                    NavigationLink("Timing") {
                        SettingsPage(title: "Timing") {
                            TimingSections()
                        }
                    }
                    NavigationLink("While Reading") {
                        SettingsPage(title: "While Reading") {
                            WhileReadingSections()
                        }
                    }
                    if KokoroVoiceModel.isSupported {
                        NavigationLink("Read Aloud") {
                            SettingsPage(title: "Read Aloud") {
                                ReadAloudSettingsSections()
                            }
                            .keepsVoiceModelLoaded()
                        }
                    }
                }

                ReadingControlsSection()
                ImportSettingsSection()
                SyncSettingsSection()
                AboutSection(showWelcome: $showWelcome)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .welcomeSheet(isPresented: $showWelcome)
        #endif
    }
}

#if os(iOS)
/// A pushed settings page holding one group of sections.
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
