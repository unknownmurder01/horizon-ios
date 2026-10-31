import SwiftUI

/// A content mod in Horizon's registry that this phone can install: the newest version made for the game's
/// Minecraft version, with no code in it.
struct RegistryMod: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
    let authors: [String]
    let downloads: Int
    let icon: URL?
    let version: String
    let file: URL
    let size: Int64
    let signed: Bool
}

/// A mod in the game's `horizon-mods` folder.
struct InstalledMod: Identifiable, Equatable {
    let id: String
    var enabled: Bool
}

/// Horizon's mod registry (docs/api/mod-index.md): `index.json`, read here to list and download; the game
/// (`launcher-mod`, crates/horizon-client/src/game/launcher_mods.rs) does the checking that matters before
/// anything reaches `horizon-mods/`: size, SHA-256, revocation, the author's signature and the mod's own
/// manifest. Nothing here is trusted to have decided that.
@MainActor
final class ModStore: ObservableObject {
    @Published private(set) var mods: [RegistryMod] = []
    @Published private(set) var installed: [InstalledMod] = []
    @Published private(set) var loading = false
    @Published private(set) var failed: String?
    /// Mod ids being downloaded or checked.
    @Published private(set) var working: Set<String> = []

    typealias Request = @MainActor (String) async -> [String: Any]
    private let request: Request
    init(request: @escaping Request = { await Bridge.send($0) }) { self.request = request }

    static let indexURL = URL(string: "https://horizon-rust.github.io/horizon-mods/index.json")!
    /// The only folder the game takes files from (`STAGING` in launcher_mods.rs).
    private static var staging: URL { GameFolder.documents.appendingPathComponent("mod-browser") }
    private static let maxFile: Int64 = 64 << 20
    private static let agent = "heyskylo/horizon-ios launcher (github.com/heyskylo/horizon-ios)"

    // MARK: Registry

    /// Download `index.json` and list its content mods made for `game`.
    func refresh(game: String) async {
        loading = true
        failed = nil
        defer { loading = false }
        do {
            try FileManager.default.createDirectory(at: Self.staging, withIntermediateDirectories: true)
            var request = URLRequest(url: Self.indexURL)
            request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadRevalidatingCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                failed = "Horizon's mod registry didn't answer. Try again in a moment."
                return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                failed = "The mod registry's answer wasn't readable."
                return
            }
            if let schema = json["schema"] as? Int, schema > 1 {
                failed = "The mod registry has a newer format. Update Horizon."
                return
            }
            try data.write(to: Self.indexFile, options: .atomic)
            mods = Self.parse(json, game: game)
        } catch {
            failed = "Horizon's mod registry couldn't be read: \(error.localizedDescription)"
        }
    }

    private static var indexFile: URL { staging.appendingPathComponent("horizon-index.json") }

    /// What the page offers. The game checks every one again at install, so this only decides what is worth
    /// showing: content mods (`mod`) for this game, with no code and not taken down.
    static func parse(_ json: [String: Any], game: String) -> [RegistryMod] {
        let revoked = (json["revoked"] as? [[String: Any]]) ?? []
        func isRevoked(_ id: String, _ sha: String) -> Bool {
            revoked.contains { entry in
                entry["id"] as? String == id
                    && ((entry["sha256"] as? String).map { $0.lowercased() == sha.lowercased() } ?? true)
            }
        }
        let projects = (json["projects"] as? [[String: Any]]) ?? []
        return projects.compactMap { project in
            guard project["kind"] as? String == "mod",
                  let id = project["id"] as? String, isModID(id),
                  let name = project["name"] as? String,
                  let versions = project["versions"] as? [[String: Any]]
            else { return nil }
            // Newest first, as the index lists them.
            let version = versions.first { v in
                guard v["game"] as? String == game,
                      let file = v["file"] as? [String: Any],
                      let sha = file["sha256"] as? String
                else { return false }
                let capabilities = (v["capabilities"] as? [String]) ?? []
                return !isRevoked(id, sha) && capabilities.allSatisfy { $0 == "registries" }
            }
            guard let version, let number = version["version"] as? String,
                  let file = version["file"] as? [String: Any],
                  let fileName = file["name"] as? String, isPlain(fileName), fileName.hasSuffix(".hmod"),
                  let address = (file["url"] as? String).flatMap(URL.init(string:)), isReleaseAsset(address),
                  let size = (file["size"] as? NSNumber)?.int64Value, size > 0, size <= maxFile
            else { return nil }
            return RegistryMod(
                id: id, name: name, summary: project["summary"] as? String ?? "",
                authors: project["authors"] as? [String] ?? [],
                downloads: project["downloads"] as? Int ?? 0,
                icon: (project["icon"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil },
                version: number, file: address, size: size, signed: project["key"] is String
            )
        }
        .sorted { $0.downloads != $1.downloads ? $0.downloads > $1.downloads : $0.name < $1.name }
    }

    /// `[a-z0-9_]{1,64}`, the registry's id rule.
    static func isModID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }
    }

    private static func isPlain(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".."
            && part.utf8.allSatisfy {
                ($0 >= 97 && $0 <= 122) || ($0 >= 65 && $0 <= 90) || ($0 >= 48 && $0 <= 57)
                    || $0 == 45 || $0 == 95 || $0 == 46 || $0 == 43 || $0 == 37
            }
    }

    /// `https://github.com/<owner>/<repo>/releases/download/<tag>/<name>`, the only shape the registry lists
    /// (the same rule as the desktop launcher's).
    static func isReleaseAsset(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "github.com", url.query == nil, url.fragment == nil else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, parts[0].isEmpty, parts[3] == "releases", parts[4] == "download" else { return false }
        return [parts[1], parts[2], parts[5], parts[6]].allSatisfy(isPlain)
    }

    // MARK: The game folder

    func reloadInstalled() async -> String? {
        let answer = await request("launcher-mod " + Self.json(["action": "list"]))
        if let error = answer.error { return error }
        let rows = (answer["mods"] as? [[String: Any]]) ?? []
        installed = rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return InstalledMod(id: id, enabled: row["enabled"] as? Bool ?? false)
        }
        return nil
    }

    func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }

    /// Download `mod`, then ask the game to check it and put it in `horizon-mods/`.
    func install(_ mod: RegistryMod) async -> Result<String, PackError> {
        guard !working.contains(mod.id) else { return .failure(PackError("\(mod.name) is already being installed.")) }
        working.insert(mod.id)
        defer { working.remove(mod.id) }
        do {
            try FileManager.default.createDirectory(at: Self.staging, withIntermediateDirectories: true)
            var request = URLRequest(url: mod.file)
            request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .failure(PackError("GitHub refused the download of \(mod.name)."))
            }
            // Under the id alone: the game's index says which file it must be, by hash.
            let staged = Self.staging.appendingPathComponent("\(mod.id).hmod")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: temporary, to: staged)
            let line = "launcher-mod " + Self.json([
                "action": "install", "id": mod.id, "version": mod.version,
                "index": Self.indexFile.path, "file": staged.path,
            ])
            let answer = await self.request(line)
            try? FileManager.default.removeItem(at: staged)
            if let error = answer.error { return .failure(PackError(error)) }
            if let error = await reloadInstalled() { return .failure(PackError(error)) }
            let trust = answer["trust"] as? String == "verified" ? "Its author's signature checked out." : "It isn't signed by its author."
            return .success("\(mod.name) \(mod.version) is installed and on. \(trust) Start the game again to use it.")
        } catch {
            return .failure(PackError(error.localizedDescription))
        }
    }

    func set(_ id: String, on: Bool) async -> String? {
        let answer = await request("launcher-mod " + Self.json(["action": "set", "id": id, "on": on]))
        if let error = answer.error { return error }
        return await reloadInstalled()
    }

    func remove(_ id: String) async -> String? {
        let answer = await request("launcher-mod " + Self.json(["action": "remove", "id": id]))
        if let error = answer.error { return error }
        return await reloadInstalled()
    }

    /// The arguments as one line of JSON, so ids and paths with odd characters arrive whole.
    private static func json(_ arguments: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - The page

/// The Packs page's Mods tab: Horizon's own content mods, from its registry.
struct ModsSection: View {
    @ObservedObject var link: GameLink
    @StateObject private var store = ModStore()
    @State private var query = ""
    @State private var notice: String?

    private var shown: [RegistryMod] {
        let words = query.lowercased().split(separator: " ")
        return store.mods.filter { mod in
            let haystack = (mod.name + " " + mod.summary + " " + mod.id).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            installedSection
            SectionHeader(title: "Horizon's mod registry")
            Field(title: "SEARCH", placeholder: "Minimap, ruby…", text: $query, keyboard: .default)
            if let failed = store.failed {
                Label(failed, systemImage: "wifi.exclamationmark").font(Theme.sans(12)).foregroundStyle(Theme.warn)
            }
            if store.loading && store.mods.isEmpty {
                ProgressView().tint(Theme.accentText).frame(maxWidth: .infinity).padding(24)
            }
            if !store.loading && store.failed == nil && shown.isEmpty {
                EmptyNote(icon: "shippingbox", text: store.mods.isEmpty
                    ? "No mods for Minecraft \(link.version) are listed yet."
                    : "Nothing matches that search.")
            }
            VStack(spacing: 0) {
                ForEach(shown) { mod in
                    ModRow(mod: mod, working: store.working.contains(mod.id),
                           installed: store.isInstalled(mod.id), canInstall: link.canList) {
                        Task { await install(mod) }
                    }
                    if mod != shown.last {
                        Divider().overlay(Theme.border).padding(.leading, 70)
                    }
                }
            }
            .card()
            Text("Mods come from Horizon's registry and are checked against it before they are installed. Only mods made of blocks, items and data are offered: mods with code can't run on iPhone or iPad. The game reads mods when it starts.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
        }
        .task { await store.refresh(game: link.version) }
        .task(id: link.canList) {
            if link.canList, let error = await store.reloadInstalled() { notice = error }
        }
        .alert("Mods", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder private var installedSection: some View {
        SectionHeader(title: "Installed")
        if store.installed.isEmpty {
            EmptyNote(icon: "shippingbox", text: link.canList
                ? "None yet. Find one below, or drop a .hmod into Horizon's horizon-mods folder in Files."
                : "Installed mods show here in a moment.")
        } else {
            VStack(spacing: 0) {
                ForEach(store.installed) { mod in
                    HStack(spacing: 12) {
                        Text(mod.id).font(Theme.sans(14)).foregroundStyle(Theme.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { mod.enabled },
                            set: { on in
                                Haptics.tap()
                                Task { if let error = await store.set(mod.id, on: on) { notice = error } }
                            }
                        ))
                        .labelsHidden()
                        .tint(Theme.accent)
                        .disabled(!link.canList)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { if let error = await store.remove(mod.id) { notice = error } }
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    if mod != store.installed.last {
                        Divider().overlay(Theme.border).padding(.leading, 14)
                    }
                }
            }
            .card()
            Text("Switch a mod on to play with it; hold one to delete it. Changes apply the next time the game starts.")
                .font(Theme.sans(11)).foregroundStyle(Theme.textFaint)
        }
    }

    private func install(_ mod: RegistryMod) async {
        Haptics.tap()
        switch await store.install(mod) {
        case let .success(said):
            Haptics.done()
            notice = said
        case let .failure(error):
            Haptics.failed()
            notice = error.message
        }
    }
}

private struct ModRow: View {
    let mod: RegistryMod
    let working: Bool
    let installed: Bool
    let canInstall: Bool
    let install: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: mod.icon) { image in
                image.resizable().interpolation(.none).scaledToFill()
            } placeholder: {
                Theme.surfaceSunken
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            VStack(alignment: .leading, spacing: 3) {
                Text(mod.name).font(Theme.sans(15, .semiBold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(mod.summary).font(Theme.sans(11)).foregroundStyle(Theme.textMuted).lineLimit(2)
                HStack(spacing: 6) {
                    Text(mod.version)
                    if !mod.authors.isEmpty {
                        Text("·")
                        Text("by \(mod.authors.joined(separator: ", "))")
                    }
                    if mod.downloads > 0 {
                        Text("·")
                        Text("\(mod.downloads.formatted(.number.notation(.compactName))) downloads")
                    }
                    if !mod.signed {
                        Text("·")
                        Text("unsigned").foregroundStyle(Theme.warn)
                    }
                }
                .font(Theme.mono(9)).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer(minLength: 4)
            Group {
                if working {
                    ProgressView().tint(Theme.accentText)
                } else if installed {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 26))
                        .foregroundStyle(Theme.accentText)
                        .accessibilityLabel("\(mod.name) is installed")
                } else {
                    Button(action: install) {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 26))
                            .foregroundStyle(canInstall ? Theme.accentBright : Theme.textFaint)
                    }
                    .disabled(!canInstall)
                    .accessibilityLabel("Install \(mod.name)")
                }
            }
            .frame(width: 44, height: 44)
        }
        .padding(12)
    }
}
