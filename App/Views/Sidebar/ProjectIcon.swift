import SwiftUI
import AppKit

/// The project's own icon when it has one (web app icon or favicon, native app icon), else a folder.
/// Looked up again whenever `version` changes and whenever the app becomes active, so an icon that
/// appears or changes (e.g. merged in from a task) shows up without a restart.
struct ProjectIcon: View {
    let repoPath: String
    /// Anything that changes when the project's base may have changed, e.g. the latest merge date.
    var version: Date?
    @State private var image: NSImage?
    @State private var activations = 0

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "folder")
            }
        }
        .frame(width: 18, height: 18)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in activations += 1 }
        .task(id: "\(repoPath)|\(version?.timeIntervalSince1970 ?? 0)|\(activations)") {
            let path = repoPath
            image = await Task.detached(priority: .utility) { ProjectIconFinder.icon(in: URL(fileURLWithPath: path)) }.value
        }
    }
}

enum ProjectIconFinder {
    /// Folders to look in, most likely first. Covers plain sites, Next/Vite/Astro/SvelteKit/Remix-style layouts.
    private static let webFolders = ["", "public", "static", "app", "src/app", "src", "assets", "images", "img"]
    /// Best first: large touch icons and app icons beat tiny favicons.
    private static let webNames = ["apple-touch-icon.png", "apple-touch-icon-precomposed.png", "apple-icon.png",
                                   "icon.svg", "icon.png", "logo.svg", "logo.png", "favicon.svg", "favicon.png", "favicon.ico"]
    private static let appIconFiles = ["src-tauri/icons/icon.png", "src-tauri/icons/128x128@2x.png",
                                       "build/icon.png", "resources/icon.png", "assets/icon.png",
                                       "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
                                       "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"]

    static func icon(in repo: URL) -> NSImage? {
        linkedIcon(in: repo) ?? appleAppIcon(in: repo) ?? firstImage(repo, appIconFiles) ?? webIcon(in: repo)
    }

    /// `<link rel="apple-touch-icon" | "icon" href="…">` in a root or public index.html: what the site itself declares.
    private static func linkedIcon(in repo: URL) -> NSImage? {
        for page in ["index.html", "public/index.html", "src/index.html"] {
            let file = repo.appendingPathComponent(page)
            guard let html = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var candidates: [(rank: Int, href: String)] = []
            guard let tag = try? Regex("<link\\b[^>]*>").ignoresCase() else { return nil }
            for match in html.matches(of: tag) {
                let link = String(html[match.range])
                guard let rel = attribute("rel", in: link)?.lowercased(), rel.contains("icon"),
                      let href = attribute("href", in: link), !href.hasPrefix("http"), !href.hasPrefix("data:") else { continue }
                candidates.append((rel.contains("apple-touch") ? 0 : 1, href))
            }
            for candidate in candidates.sorted(by: { $0.rank < $1.rank }) {
                // Root-relative hrefs are served from the page's folder (or public/ for bundlers).
                let href = candidate.href.split(separator: "?").first.map(String.init) ?? candidate.href
                let base = file.deletingLastPathComponent()
                let paths = href.hasPrefix("/")
                    ? [base.appendingPathComponent(String(href.dropFirst())), repo.appendingPathComponent("public" + href)]
                    : [base.appendingPathComponent(href)]
                if let image = paths.lazy.compactMap(load).first { return image }
            }
        }
        return nil
    }

    /// The largest PNG in an Xcode AppIcon set anywhere in the first few levels (skipping dependencies).
    private static func appleAppIcon(in repo: URL) -> NSImage? {
        guard let walker = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var best: (size: Int, url: URL)?
        var visited = 0
        for case let url as URL in walker {
            // A project can be a huge folder (even a home folder); give up rather than crawl it.
            visited += 1
            if visited > 5000 { break }
            if ["node_modules", "Pods", "build", "DerivedData", ".build", "dist", "vendor"].contains(url.lastPathComponent) {
                walker.skipDescendants(); continue
            }
            if walker.level > 4 { walker.skipDescendants(); continue }
            guard url.pathExtension == "appiconset" else { continue }
            let pngs = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for png in pngs where png.pathExtension == "png" {
                let size = (try? png.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > best?.size ?? 0 { best = (size, png) }
            }
            walker.skipDescendants()
        }
        return best.flatMap { load($0.url) }
    }

    private static func webIcon(in repo: URL) -> NSImage? {
        for name in webNames {
            for folder in webFolders {
                let url = folder.isEmpty ? repo.appendingPathComponent(name) : repo.appendingPathComponent(folder).appendingPathComponent(name)
                if let image = load(url) { return image }
            }
        }
        return nil
    }

    private static func firstImage(_ repo: URL, _ paths: [String]) -> NSImage? {
        paths.lazy.compactMap { load(repo.appendingPathComponent($0)) }.first
    }

    private static func load(_ url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url),
              image.size.width > 0 else { return nil }
        return image
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = try? Regex("\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()
        guard let pattern, let match = tag.firstMatch(of: pattern), let value = match.output[1].substring else { return nil }
        return String(value)
    }
}
