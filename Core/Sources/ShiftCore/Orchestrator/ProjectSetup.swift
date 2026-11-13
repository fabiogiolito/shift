import Foundation

/// Defaults suggested when a project is added, and the wording of a failed setup.
/// ponytail: JavaScript package managers only; add other ecosystems when someone needs them.
enum ProjectSetup {
    static let envFiles = [".env", ".env.local"]

    /// The build script in `directory`, as a command: scripts/build.sh, else build.sh. Nil when neither is executable.
    static func buildScript(in directory: URL) -> String? {
        ["scripts/build.sh", "build.sh"]
            .first { FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path) }
            .map { $0.contains("/") ? $0 : "./" + $0 }
    }

    /// lockfile -> package manager, in order of precedence.
    static let lockfiles = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"),
                                    ("bun.lock", "bun"), ("package-lock.json", "npm")]

    /// - Parameters:
    ///   - rootFiles: names of the entries in the repository root.
    ///   - packageJSON: contents of the root package.json, if there is one.
    ///   - tracked: the env files that are tracked by git (those are in the worktree already).
    ///   - forced: the type to suggest commands for. Nil: the type the repo looks like.
    ///   - projectYML: contents of the root project.yml, if there is one.
    ///   - schemes: the application schemes of its Xcode project, when it has no project.yml.
    ///   - buildScript: the repo's build script, as a command (see `buildScript(in:)`).
    // ponytail: only looks at the repo root; an Electron app in a monorepo package needs Other.
    static func suggest(rootFiles: [String], packageJSON: Data? = nil, tracked: Set<String> = [],
                        as forced: ProjectType? = nil, projectYML: String? = nil, schemes: [DetectedApp] = [],
                        xcodeProject: String? = nil,
                        buildScript: String? = nil) -> (type: ProjectType, setup: String, server: String, targets: [BuildTarget]) {
        let manager = lockfiles.first { rootFiles.contains($0.0) }?.1
        let runner = manager ?? "npm"
        let copies = envFiles.filter { rootFiles.contains($0) && !tracked.contains($0) }
            .map { "cp \"$SHIFT_REPO/\($0)\" ." }
        let steps = (manager.map { ["\($0) install"] } ?? []) + copies
        let setup = steps.joined(separator: " && ")

        let package = packageJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let scripts = package?["scripts"] as? [String: Any] ?? [:]
        let dependencies = ["dependencies", "devDependencies"].compactMap { package?[$0] as? [String: Any] }
        let dev = scripts["dev"] as? String

        let type = forced ?? {
            if dependencies.contains(where: { $0["electron"] != nil }) { return .electronApp }
            if dev != nil { return .dynamicWebsite }
            if rootFiles.contains(where: { $0 == "project.yml" || $0.hasSuffix(".xcodeproj") }) { return .nativeApp }
            // Static has no setup, so a repo that needs one is not static.
            return steps.isEmpty ? .staticWebsite : .other
        }()
        switch type {
        case .electronApp:
            // A package manager may skip Electron's install script (pnpm does), leaving no binary to run.
            let install = ["\(runner) install", "node node_modules/electron/install.js"] + copies
            let run = dev != nil ? "\(runner) run dev" : scripts["start"] != nil ? "\(runner) run start" : "node_modules/.bin/electron ."
            return (type, install.joined(separator: " && "), "", [BuildTarget(name: "App", command: run, kind: .run)])
        case .dynamicWebsite:
            guard let dev else { return (type, setup, "", []) }
            // Vite and Astro ignore $PORT, so pass it as a flag. npm needs `--` to forward it; the others
            // forward arguments as-is (and pnpm would hand a literal `--` on to vite).
            var server = "\(runner) run dev"
            if dev.range(of: #"\b(vite|astro)\b"#, options: .regularExpression) != nil {
                server += runner == "npm" ? " -- --port $PORT" : " --port $PORT"
            }
            return (type, setup, server, [])
        case .staticWebsite:
            return (type, "", "", [])
        case .nativeApp:
            let apps = projectYML.map(applications(projectYML:)) ?? schemes
            return (type, setup, "", targets(apps: apps, xcodeGen: projectYML != nil, xcodeProject: xcodeProject,
                                             buildScript: buildScript))
        case .other:
            return (type, setup, "", [])
        }
    }

    // MARK: Build targets

    /// An application target found in a repo.
    struct DetectedApp: Equatable, Sendable {
        var name: String
        var kind: BuildTarget.Kind
        /// Its source folders, as path prefixes.
        var paths: [String] = []
    }

    /// One target per application, each building just that one. The first Mac app goes through the repo's build
    /// script if it has one, since the script may do more than `xcodebuild` (Shift's patches the generated project).
    /// The script is called with no arguments: what it takes is its own business (Shift's first argument is the
    /// derived data folder). It can read `SHIFT_TARGET` to tell targets apart.
    static func targets(apps: [DetectedApp], xcodeGen: Bool, xcodeProject: String? = nil, buildScript: String?) -> [BuildTarget] {
        var script = buildScript
        var targets = apps.map { app in
            let useScript = script != nil && app.kind == .macApp
            let command = useScript ? script! : buildCommand(for: app, xcodeGen: xcodeGen, xcodeProject: xcodeProject)
            if useScript { script = nil }
            return BuildTarget(name: app.name, command: command, kind: app.kind, paths: app.paths)
        }
        if let script { targets.insert(BuildTarget(name: "App", command: script), at: 0) }
        return targets
    }

    /// Prints the .app it built, like the build script does. Each target has derived data of its own: two
    /// builds at once in the same folder fail on a locked database.
    static func buildCommand(for app: DetectedApp, xcodeGen: Bool, xcodeProject: String? = nil) -> String {
        let folder = "build/" + quoted(app.name)
        let project = xcodeProject.map { " -project " + quoted($0) } ?? ""
        let isIOS = app.kind == .iOSSimulator
        let destination = isIOS ? " -destination 'generic/platform=iOS Simulator'" : ""
        let products = isIOS ? "Debug-iphonesimulator" : "Debug"
        let build = "xcodebuild\(project) -scheme \(quoted(app.name)) -configuration Debug\(destination) "
            + #"-derivedDataPath \#(folder) -quiet build && ls -d "$PWD"/\#(folder)/Build/Products/\#(products)/*.app | head -1"#
        // Builds side by side would fail generating the project at once, or rewrite it under each other: one at a
        // time, and skipped when nothing changed.
        return xcodeGen ? "mkdir -p build && /usr/bin/lockf -k build/.xcodegen.lock xcodegen --quiet --use-cache && " + build : build
    }

    /// For a Swift package with an executable (`Package.swift`'s contents): builds it and wraps it in a .app,
    /// which a SwiftUI app needs to open as one, then prints that .app. Nil when the package has no executable.
    // ponytail: reads the first executable by regex; a package with several apps needs its own command.
    static func swiftPackageCommand(_ package: String) -> String? {
        guard let match = package.firstMatch(of: #/\.executable(?:Target)?\(\s*name:\s*"([^"]+)"/#) else { return nil }
        let name = String(match.1)
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
            + "<key>CFBundleExecutable</key><string>\(name)</string><key>CFBundleName</key><string>\(name)</string>"
            + "<key>CFBundleIdentifier</key><string>local.shift.\(name.filter { $0.isLetter || $0.isNumber })</string>"
            + "<key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/></dict></plist>"
        let app = #""$PWD/.build/\#(name).app""#
        return #"swift build && A=\#(app) && rm -rf "$A" && mkdir -p "$A/Contents/MacOS" && "#
            + #"cp "$(swift build --show-bin-path)/"\#(quoted(name)) "$A/Contents/MacOS/" && "#
            + #"printf '%s' \#(quoted(plist)) > "$A/Contents/Info.plist" && echo "$A""#
    }

    /// A word for the shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The application targets in the `targets:` of an XcodeGen project.yml, for macOS and iOS.
    // ponytail: reads the plain block style by indentation, there being no YAML parser to hand. It doesn't follow
    // `include:` or target templates, and skips a list of platforms.
    static func applications(projectYML: String) -> [DetectedApp] {
        let lines: [(indent: Int, text: String)] = projectYML.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = String(raw)
            if line.hasPrefix("#") { return nil }
            if let comment = line.range(of: " #") { line = String(line[..<comment.lowerBound]) }
            let text = line.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : (line.prefix { $0 == " " }.count, text)
        }
        guard let start = lines.firstIndex(where: { $0.indent == 0 && $0.text == "targets:" }) else { return [] }
        let body = lines[(start + 1)...].prefix { $0.indent > 0 }
        guard let targetIndent = body.first?.indent else { return [] }

        func unquoted(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: #""' "#)) }
        /// The value after `key:` on this line, if this line is that key.
        func value(of key: String, in text: String) -> String? {
            text.hasPrefix(key + ":") ? unquoted(String(text.dropFirst(key.count + 1))) : nil
        }

        var apps: [DetectedApp] = []
        var rest = body[...]
        while let header = rest.first {
            let properties = rest.dropFirst().prefix { $0.indent > targetIndent }
            rest = rest.dropFirst(properties.count + 1)
            guard let propertyIndent = properties.first?.indent,
                  properties.contains(where: { $0.indent == propertyIndent && value(of: "type", in: $0.text) == "application" }),
                  let platform = properties.lazy.filter({ $0.indent == propertyIndent })
                      .compactMap({ value(of: "platform", in: $0.text) }).first else { continue }
            let kind: BuildTarget.Kind
            switch platform {
            case "macOS": kind = .macApp
            case "iOS": kind = .iOSSimulator
            default: continue
            }
            apps.append(DetectedApp(name: unquoted(String(header.text.dropLast())), kind: kind,
                                    paths: sources(in: Array(properties), propertyIndent: propertyIndent)))
        }
        return apps
    }

    /// `sources: App`, `sources: [App, Shared]`, or a list of folders or of items with a `path:`.
    private static func sources(in properties: [(indent: Int, text: String)], propertyIndent: Int) -> [String] {
        guard let index = properties.firstIndex(where: { $0.indent == propertyIndent && $0.text.hasPrefix("sources:") }) else { return [] }
        func clean(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: #""' "#)) }
        let inline = clean(String(properties[index].text.dropFirst("sources:".count)))
        var found: [String] = []
        if inline.hasPrefix("[") {
            found = inline.dropFirst().dropLast().split(separator: ",").map { clean(String($0)) }
        } else if !inline.isEmpty {
            found = [inline]
        } else {
            // YAML lets a list sit at its key's own indent.
            let items = properties[(index + 1)...].prefix {
                $0.indent > propertyIndent || ($0.indent == propertyIndent && $0.text.hasPrefix("- "))
            }
            let itemIndent = items.first?.indent
            for item in items {
                if item.indent == itemIndent, item.text.hasPrefix("- ") {
                    let text = clean(String(item.text.dropFirst(2)))
                    if text.hasPrefix("path:") {
                        found.append(clean(String(text.dropFirst("path:".count))))
                    } else if !text.contains(":") {
                        found.append(text)
                    }
                } else if item.text.hasPrefix("path:") {
                    found.append(clean(String(item.text.dropFirst("path:".count))))
                }
            }
        }
        return found.compactMap { source in
            let folder = source.hasPrefix("./") ? String(source.dropFirst(2)) : source
            guard !folder.isEmpty, folder != "." else { return nil }
            return folder.hasSuffix("/") ? folder : folder + "/"
        }
    }

    /// The JSON in the output of a command: what parses from the first line that starts like JSON, past any
    /// warnings above it (some of which have brackets in them) to the last bracket.
    private static func json(in output: String) -> Any? {
        guard let end = output.lastIndex(where: { $0 == "}" || $0 == "]" }) else { return nil }
        var start = output.startIndex
        while start < end {
            let lineEnd = output[start...].firstIndex(where: \.isNewline) ?? output.endIndex
            if let first = output[start..<lineEnd].first(where: { !$0.isWhitespace }), first == "{" || first == "[",
               let parsed = try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) {
                return parsed
            }
            guard lineEnd < output.endIndex else { break }
            start = output.index(after: lineEnd)
        }
        return nil
    }

    /// The schemes in the output of `xcodebuild -list -json`.
    static func schemes(listOutput: String) -> [String] {
        guard let list = json(in: listOutput) as? [String: Any],
              let container = (list["project"] ?? list["workspace"]) as? [String: Any] else { return [] }
        return container["schemes"] as? [String] ?? []
    }

    /// What `scheme` builds, from the output of `xcodebuild -showBuildSettings -json`. Nil when it is not a Mac or
    /// iOS app: `-list` also names test and library schemes, and doesn't tell the platform.
    static func application(scheme: String, buildSettingsOutput: String) -> DetectedApp? {
        let targets = json(in: buildSettingsOutput) as? [[String: Any]] ?? []
        let settings = targets.compactMap { $0["buildSettings"] as? [String: Any] }
        guard let app = settings.first(where: { $0["WRAPPER_EXTENSION"] as? String == "app" }) else { return nil }
        switch app["PLATFORM_NAME"] as? String {
        case "macosx": return DetectedApp(name: scheme, kind: .macApp)
        case "iphoneos", "iphonesimulator": return DetectedApp(name: scheme, kind: .iOSSimulator)
        default: return nil
        }
    }

    /// Asks `xcodebuild` about an Xcode project. Empty if it doesn't answer in time, which is not worth holding
    /// up adding the project for: a guess from the files takes over.
    private static func applicationSchemes(project: String, repo: URL, servers: ServerManaging) async -> [DetectedApp] {
        await withTaskGroup(of: [DetectedApp].self) { group in
            group.addTask {
                func output(_ arguments: String) async -> String {
                    // Its warnings go to stderr, and some of them look like JSON.
                    (try? await servers.run(command: "xcodebuild \(arguments) -json -project \(quoted(project)) 2>/dev/null",
                                            directory: repo, environment: [:]))?.output ?? ""
                }
                var apps: [DetectedApp] = []
                for scheme in schemes(listOutput: await output("-list")) {
                    let settings = await output("-showBuildSettings -scheme \(quoted(scheme))")
                    if let app = application(scheme: scheme, buildSettingsOutput: settings) { apps.append(app) }
                }
                return apps
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    static func suggest(repo: URL, git: GitServicing, servers: ServerManaging,
                        as forced: ProjectType? = nil) async -> (type: ProjectType, setup: String, server: String, targets: [BuildTarget]) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        var tracked: Set<String> = []
        for name in envFiles where files.contains(name) {
            if await git.isTracked(repo: repo, path: name) { tracked.insert(name) }
        }
        let package = FileManager.default.contents(atPath: repo.appendingPathComponent("package.json").path)
        let projectYML = try? String(contentsOf: repo.appendingPathComponent("project.yml"), encoding: .utf8)
        let script = buildScript(in: repo)
        var suggested = suggest(rootFiles: files, packageJSON: package, tracked: tracked, as: forced)
        guard suggested.type == .nativeApp else { return suggested }
        let xcodeProject = projectYML == nil ? files.first { $0.hasSuffix(".xcodeproj") } : nil
        let schemes = if let xcodeProject { await applicationSchemes(project: xcodeProject, repo: repo, servers: servers) } else { [DetectedApp]() }
        suggested = suggest(rootFiles: files, packageJSON: package, tracked: tracked, as: .nativeApp, projectYML: projectYML,
                            schemes: schemes, xcodeProject: xcodeProject, buildScript: script)
        if suggested.targets.isEmpty {
            suggested.targets = Project(name: "", repoPath: repo.path, baseBranch: "").defaultBuildTargets
        }
        return suggested
    }

    /// What serves a task's worktree: the project's own server command, else the dev script found in
    /// `directory` (a project the agent created after it was added), else a static file server.
    // ponytail: depends on python3 being installed (it ships with the Xcode command line tools);
    // replace with an in-process server if that becomes a problem.
    static func serverCommand(for project: Project, in directory: URL? = nil) -> String {
        let command = project.serverCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { return command }
        guard let directory else { return staticServer }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let package = FileManager.default.contents(atPath: directory.appendingPathComponent("package.json").path)
        let detected = suggest(rootFiles: files, packageJSON: package).server
        return detected.isEmpty ? staticServer : detected
    }

    /// What to build in a task's worktree: `target` itself, else the first one guessed from `directory`
    /// (an app the agent created after the project was added). No command when there is nothing to build yet.
    static func resolved(_ target: BuildTarget, in directory: URL) -> BuildTarget {
        guard !target.hasCommand else { return target }
        var guess = Project(name: "", repoPath: directory.path, baseBranch: "").defaultBuildTargets.first ?? target
        guess.id = target.id
        return guess
    }

    /// The install to run before a detected dev script when the project has no commands of its own
    /// (it was empty when added) and nothing installed its dependencies yet.
    static func installStep(for project: Project, in directory: URL) -> String? {
        guard project.serverCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.setupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return missingInstall(in: directory)
    }

    /// The install a JavaScript project needs before it can run: it has a package.json and no node_modules.
    /// The base server runs in the repo folder, which no setup command ever touches.
    static func missingInstall(in directory: URL) -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard files.contains("package.json"), !files.contains("node_modules") else { return nil }
        return "\(lockfiles.first { files.contains($0.0) }?.1 ?? "npm") install"
    }

    /// Serves the worktree on both 127.0.0.1 and ::1, since browsers may resolve `localhost` to either,
    /// and never binds beyond loopback. No-cache so a refresh always shows the agent's latest edits.
    static let staticServer = "python3 -c '" + """
        import http.server as h, os, socket, threading
        class Handler(h.SimpleHTTPRequestHandler):
            def end_headers(self):
                self.send_header("Cache-Control", "no-store")
                super().end_headers()
        class V6(h.ThreadingHTTPServer):
            address_family = socket.AF_INET6
        port = int(os.environ["PORT"])
        v4 = h.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        try:
            v6 = V6(("::1", port), Handler)
            threading.Thread(target=v6.serve_forever, daemon=True).start()
        except OSError:
            pass
        v4.serve_forever()
        """ + "'"

    /// Short reason for a blocked task: the exit code and the last few lines of output.
    /// Progress bars (lines with no letters or digits, like pnpm's `+++++`) are dropped so they don't bury the error.
    static func failure(_ result: CommandResult) -> String {
        let tail = result.output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
            .suffix(5).joined(separator: "\n")
        let headline = "Setup failed (exit code \(result.exitCode))."
        return tail.isEmpty ? headline : headline + "\n" + String(tail.suffix(400))
    }
}

extension Project {
    /// The targets guessed from the files in the repo: see `ProjectSetup.targets`. Else, if there is an Xcode
    /// project whose targets can't be read from here, a Debug `xcodebuild` of it (generated first when it comes
    /// from XcodeGen) that prints the .app it built. Empty when there is nothing to guess.
    /// ponytail: that last guess builds the project's default scheme, not a workspace; a CocoaPods app needs its own command.
    public var defaultBuildTargets: [BuildTarget] {
        let files = FileManager.default
        let script = ProjectSetup.buildScript(in: repoURL)
        let yml = repoURL.appendingPathComponent("project.yml")
        let hasYML = files.fileExists(atPath: yml.path)
        let apps = ProjectSetup.applications(projectYML: (try? String(contentsOf: yml, encoding: .utf8)) ?? "")
        let detected = ProjectSetup.targets(apps: apps, xcodeGen: hasYML, buildScript: script)
        guard detected.isEmpty else { return detected }
        let xcodebuild = #"xcodebuild -configuration Debug SYMROOT="$PWD/build" -quiet && ls -d "$PWD"/build/Debug/*.app | head -1"#
        if hasYML { return [BuildTarget(name: "App", command: "xcodegen -q && " + xcodebuild)] }
        let entries = (try? files.contentsOfDirectory(atPath: repoPath)) ?? []
        if entries.contains(where: { $0.hasSuffix(".xcodeproj") }) { return [BuildTarget(name: "App", command: xcodebuild)] }
        let package = (try? String(contentsOf: repoURL.appendingPathComponent("Package.swift"), encoding: .utf8)) ?? ""
        return ProjectSetup.swiftPackageCommand(package).map { [BuildTarget(name: "App", command: $0)] } ?? []
    }

    /// The command of the first target guessed from the repo. Empty when there is nothing to guess.
    public var defaultBuildCommand: String { defaultBuildTargets.first?.command ?? "" }
}

extension Project {
    /// GitHub's branch of static files served as the repo's website, whatever the rest of the repo is.
    public static let staticSiteBranch = "gh-pages"

    /// The project as `task` sees it: a task based on gh-pages is a static website, served from its worktree,
    /// with no setup and nothing to build. Every other task gets the project as it is.
    /// Whatever decides a task's server, setup, build targets or agent instructions reads this, not the project.
    public func forTask(_ task: TaskItem) -> Project {
        guard task.base(in: self) == Self.staticSiteBranch else { return self }
        var site = self
        site.type = .staticWebsite
        site.serverCommand = ProjectSetup.staticServer
        site.setupCommand = ""
        site.buildTargets = []
        return site
    }
}
