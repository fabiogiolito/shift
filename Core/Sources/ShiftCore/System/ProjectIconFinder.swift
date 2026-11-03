import AppKit
import QuickLookThumbnailing

public enum ProjectIconFinder {
    /// Folders to look in, most likely first. Covers plain sites, Next/Vite/Astro/SvelteKit/Remix-style layouts.
    private static let webFolders = ["", "public", "public/images", "static", "app", "src/app", "src", "assets", "images", "img"]
    /// Best first: large touch icons and app icons beat tiny favicons.
    private static let webNames = ["apple-touch-icon.png", "apple-touch-icon-precomposed.png", "apple-icon.png",
                                   "icon.svg", "icon.png", "logo.svg", "logo.png", "favicon.svg", "favicon.png", "favicon.ico"]
    private static let appIconFiles = ["src-tauri/icons/icon.png", "src-tauri/icons/128x128@2x.png",
                                       "build/icon.png", "resources/icon.png", "assets/icon.png",
                                       "android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
                                       "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"]

    /// Subfolders where a monorepo usually keeps its website, checked after the root.
    private static let webPackages = ["web", "www", "site", "website", "frontend", "apps/web", "apps/www", "apps/site"]

    public static func icon(in repo: URL) async -> NSImage? {
        if let image = linkedIcon(in: repo) { return image }
        if let file = appleAppIconFile(in: repo),
           let image = file.pathExtension == "icon" ? await thumbnail(file) : load(file) { return image }
        return firstImage(repo, appIconFiles) ?? webIcon(in: repo)
            ?? webPackages.lazy.compactMap { webIcon(in: repo.appendingPathComponent($0)) }.first
    }

    /// The icon as a PNG at most `side` points square (@2x), for a phone. nil: the project has none.
    public static func png(in repo: URL, side: CGFloat = 40) async -> Data? {
        guard let image = await icon(in: repo) else { return nil }
        let pixels = Int(side * 2)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Aspect fit, centered.
        let scale = min(CGFloat(pixels) / image.size.width, CGFloat(pixels) / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
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

    /// An Icon Composer `.icon` (rendered by Quick Look), else the largest PNG in an Xcode AppIcon set,
    /// anywhere in the first few levels (skipping dependencies).
    private static func appleAppIconFile(in repo: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: repo, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var best: (size: Int, url: URL)?
        var composerIcon: URL?
        var visited = 0
        for case let url as URL in walker {
            // A project can be a huge folder (even a home folder); give up rather than crawl it.
            visited += 1
            if visited > 5000 { break }
            if ["node_modules", "Pods", "build", "DerivedData", ".build", "dist", "vendor"].contains(url.lastPathComponent) {
                walker.skipDescendants(); continue
            }
            if walker.level > 4 { walker.skipDescendants(); continue }
            if url.pathExtension == "icon", composerIcon == nil { composerIcon = url; walker.skipDescendants(); continue }
            guard url.pathExtension == "appiconset" else { continue }
            let pngs = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for png in pngs where png.pathExtension == "png" {
                let size = (try? png.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > best?.size ?? 0 { best = (size, png) }
            }
            walker.skipDescendants()
        }
        return composerIcon ?? best?.url
    }

    private static func thumbnail(_ url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
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
