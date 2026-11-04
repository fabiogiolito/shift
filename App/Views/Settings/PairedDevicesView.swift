import CoreImage.CIFilterBuiltins
import ShiftCore
import SwiftUI

/// Pairs phones and revokes them. Anyone with a code can start agents on this Mac, so it's only shown on request.
struct PairedDevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var code: (device: RemoteDevice, pairing: Pairing)?
    @State private var error: String?
    @State private var isPairing = false

    var body: some View {
        Form {
            Section {
                ForEach(model.remoteDevices.filter { $0.lastSeen != nil }) { device in
                    LabeledContent {
                        Button("Revoke", role: .destructive) { model.revokeDevice(device.id) }
                    } label: {
                        Text(device.name)
                        if let seen = device.lastSeen { Text("Last seen \(seen, format: .relative(presentation: .named))") }
                    }
                }
                if let code {
                    VStack(spacing: 8) {
                        if let image = Self.qrCode(code.pairing.link) {
                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        }
                        Text("Point your iPhone's Camera at this code. Treat it like a password: it lets that phone run agents on this Mac.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Cancel") { cancelCode() }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Button(isPairing ? "Preparing…" : "Pair iPhone…") { pair() }.disabled(isPairing)
                }
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Your phone reaches this Mac over Tailscale and only while signed in as you. Your Mac stays awake while a task is working.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.remoteDevices) {
            // The phone connected: its code has done its job.
            if let id = code?.device.id, model.remoteDevices.first(where: { $0.id == id })?.lastSeen != nil { code = nil }
        }
        .onDisappear(perform: cancelCode)
    }

    private func pair() {
        isPairing = true
        error = nil
        Task {
            do { code = try await model.pairDevice() } catch { self.error = error.localizedDescription }
            isPairing = false
        }
    }

    /// A code nobody used stops being valid.
    private func cancelCode() {
        if let code, model.remoteDevices.first(where: { $0.id == code.device.id })?.lastSeen == nil { model.revokeDevice(code.device.id) }
        code = nil
    }

    private static func qrCode(_ url: URL) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: output.extent.size)
    }
}
