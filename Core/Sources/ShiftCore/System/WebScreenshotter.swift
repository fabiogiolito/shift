import AppKit
import WebKit

/// Loads the page in a browser view of its own, in a window off screen, so it never gets in the user's way.
/// No cookies or storage are kept: a page behind a login shows the login.
@MainActor
public final class WebScreenshotter: Screenshotting {
    public init() {}

    public func capture(url: URL, to file: URL) async -> Bool {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let webView = WKWebView(frame: frame, configuration: configuration)
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20000, dy: -20000), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = webView
        window.orderBack(nil) // Pages that aren't in a visible window don't draw.
        defer { window.close() }

        let load = PageLoad()
        webView.navigationDelegate = load
        // Dev servers compile a page the first time it's asked for.
        let loaded = await load.run(timeout: .seconds(30)) { webView.load(URLRequest(url: url)) }
        guard loaded else { return false }
        // ponytail: fixed wait for scripts to draw; wait for network idle if pages get shot half loaded.
        try? await Task.sleep(for: .seconds(1.5))

        guard let image = try? await webView.takeSnapshot(configuration: nil),
              let tiff = image.tiffRepresentation else { return false }
        return Self.writePNG(from: tiff, to: file)
    }

    /// Off the main thread, and regular files only: the agent chose the path, and a pipe would never finish reading.
    public func copyImage(at source: URL, to file: URL) async -> Bool {
        await Task.detached {
            guard (try? source.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: source) else { return false }
            return Self.writePNG(from: data, to: file)
        }.value
    }

    private nonisolated static func writePNG(from image: Data, to file: URL) -> Bool {
        guard let png = NSBitmapImageRep(data: image)?.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

@MainActor
private final class PageLoad: NSObject, WKNavigationDelegate {
    private var done: ((Bool) -> Void)?

    func run(timeout: Duration, start: () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            done = { continuation.resume(returning: $0) }
            Task {
                try? await Task.sleep(for: timeout)
                finish(false)
            }
            start()
        }
    }

    private func finish(_ loaded: Bool) {
        done?(loaded)
        done = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
