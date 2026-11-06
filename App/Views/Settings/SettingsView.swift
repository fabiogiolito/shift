import SwiftUI
import ShiftCore

/// Shift's own settings (⌘,), for every project. Each project's are in Project Settings (⇧⌘,).
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            #if DEBUG
            // Phase 1 of onboarding: fake states only, so not in release builds yet.
            SetupSettingsView()
                .tabItem { Label("Setup", systemImage: "checklist") }
                .tag("setup")
            #endif
            PairedDevicesView()
                .tabItem { Label("Paired Devices", systemImage: "iphone") }
                .tag("devices")
        }
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(OpenInMenu.editorKey) private var editorPath: String?
    @AppStorage(OpenInMenu.terminalKey) private var terminalPath: String?
    private let apps = ExternalApps()

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                appPicker("Code editor", selection: $editorPath,
                          options: apps.installedEditors().filter { $0 != .finder }.compactMap(apps.appURL))
                appPicker("Terminal", selection: $terminalPath, options: apps.installedTerminals())
            } header: {
                Text("Open in")
            } footer: {
                Text("Shown first in Open in, and opened with ⇧⌘E and ⇧⌘T.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("Stop idle servers after", selection: $model.serverTTL) {
                    ForEach([1, 5, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                    Divider()
                    Text("Never").tag(0)
                }
            } header: {
                Text("Dev servers")
            } footer: {
                Text("A server is idle while no agent runs on its task and no browser tab is connected to it. A new prompt, or clicking the server's button, starts it again.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func appPicker(_ title: String, selection: Binding<String?>, options: [URL]) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(String?.none)
            ForEach(options, id: \.self) { app in
                Label { Text(apps.name(of: app)) } icon: { Image(nsImage: apps.icon(of: app)) }
                    .tag(Optional(app.path))
            }
        }
    }
}
