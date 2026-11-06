import ShiftProtocol
import SwiftUI

@main
struct ShiftMobileApp: App {
    @State private var model = RemoteModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.open(link: $0) }
                .onChange(of: scenePhase) { if scenePhase == .active { model.reconnectNow() } }
        }
    }
}

struct RootView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.pairing == nil {
                PairingView()
            } else {
                // A stack, not a safe area inset: the navigation bar ignores an inset and ends up under the banner.
                VStack(spacing: 0) {
                    LinkBanner()
                    NavigationStack {
                        ProjectsView()
                            .navigationDestination(for: UUID.self) { TaskListView(projectID: $0) }
                            .navigationDestination(for: Int.self) { TaskDetailView(taskID: $0) }
                    }
                }
            }
        }
        .task(id: model.pairing == nil) { await model.checkNotifications() }
        .sheet(isPresented: Binding(get: { model.offersNotifications }, set: { if !$0 { model.declineNotifications() } })) {
            NotificationsOffer()
        }
        .alert("Pair with this Mac?", isPresented: Binding(get: { model.proposedPairing != nil }, set: { if !$0 { model.proposedPairing = nil } })) {
            Button("Pair") {
                if let pairing = model.proposedPairing { model.pair(pairing) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only pair if you just scanned this code in Shift on your own Mac: \(model.proposedPairing?.server.host ?? "")")
        }
        .alert("Couldn't do that", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

/// Why Shift wants notifications, before iOS asks: a "Don't Allow" there can only be undone in Settings.
private struct NotificationsOffer: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Know when a task needs you")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Shift tells you when a task on your Mac is ready for review or waiting on an answer, so you don't have to keep checking.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                Task { await model.allowNotifications() }
            } label: {
                Text("Allow Notifications").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Not Now") { model.declineNotifications() }
        }
        .padding(24)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }
}

/// Says so whenever the Mac can't be reached, and what's on screen is as of the last time it could.
private struct LinkBanner: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        switch model.link {
        case .online: EmptyView()
        case .connecting: banner("Connecting to your Mac…", "antenna.radiowaves.left.and.right")
        case .offline: banner("Mac offline. Reconnecting…", "wifi.slash")
        case .refused: banner("Your Mac refused this iPhone. Pair it again if you revoked it.", "lock.slash")
        }
    }

    private func banner(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.footnote)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(.bar)
    }
}

private struct PairingView: View {
    @Environment(RemoteModel.self) private var model
    @State private var link = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("On your Mac, open Shift and choose Shift > Settings > Devices > Pair iPhone.", systemImage: "1.circle")
                    Label("Point this iPhone's Camera at the code, and open the link it finds.", systemImage: "2.circle")
                    Label("Both need Tailscale, signed in to the same account.", systemImage: "3.circle")
                }
                Section("Or paste the link") {
                    TextField("shift-remote://…", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(openLink)
                    Button("Pair", action: openLink).disabled(link.isEmpty)
                }
            }
            .navigationTitle("Connect to Your Mac")
        }
    }

    private func openLink() {
        if let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) { model.open(link: url) }
    }
}
