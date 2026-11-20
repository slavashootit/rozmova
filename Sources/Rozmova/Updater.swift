import AppKit
import Foundation

/// Self-update from GitHub Releases.
/// Checks `releases/latest` at launch and every 6 hours; when a newer version is out, the app shows
/// "Є оновлення" with a button. Installing downloads the release .zip, checks it is really this app,
/// keeps the same code signature (so macOS does not drop Microphone / Accessibility permissions),
/// swaps the bundle in place and relaunches.
/// Same file in every Mac app of ours; only `Config` differs.
@MainActor
final class Updater: ObservableObject {
    struct Config {
        let repo: String          // "slavashootit/shepit"
        let bundleID: String      // must match the downloaded app
        let assetSuffix: String   // ".zip" or ".dmg"
        /// Certificate to sign with when the running copy is ad-hoc (e.g. "Kadr Dev"), so macOS
        /// permissions survive every later update. Used only if this Mac has it.
        var preferredIdentity: String? = nil
    }

    struct Release: Equatable {
        let version: String
        let page: URL
        let asset: URL
        let notes: String
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case installing(String)
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date?

    /// Called right before the app quits for the swap (stop workers, save state).
    var beforeRelaunch: (() -> Void)?
    /// Called when a newer release is found (each check), e.g. to post a notification.
    var onFound: ((Release) -> Void)?

    private let config: Config
    private var timer: Timer?

    init(_ config: Config) {
        self.config = config
    }

    nonisolated static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        Task { try? await Task.sleep(nanoseconds: 8_000_000_000); await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    func check() async {
        if case .installing = phase { return }
        phase = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(config.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                phase = .failed("GitHub не відповів як слід")
                return
            }
            lastChecked = Date()
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = json["assets"] as? [[String: Any]] ?? []
            let assetURL = assets
                .compactMap { $0["browser_download_url"] as? String }
                .first { $0.hasSuffix(config.assetSuffix) }
                .flatMap(URL.init(string:))
            guard Self.isNewer(version, than: Self.current), let assetURL else {
                available = nil
                phase = .upToDate
                return
            }
            let release = Release(version: version, page: page, asset: assetURL, notes: json["body"] as? String ?? "")
            available = release
            phase = .available
            onFound?(release)
        } catch {
            phase = .failed("Немає зв'язку з GitHub")
        }
    }

    func install() {
        guard let release = available else { return }
        if case .installing = phase { return }
        phase = .installing("Завантажую \(release.version)…")
        Task.detached(priority: .userInitiated) { [config] in
            do {
                let newApp = try await Self.prepare(release, config: config) { text in
                    Task { @MainActor in self.phase = .installing(text) }
                }
                try await MainActor.run { try self.swapAndRelaunch(newApp) }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - Steps

    private nonisolated static func prepare(_ release: Release, config: Config,
                                            progress: @escaping (String) -> Void) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let (downloaded, response) = try await URLSession.shared.download(from: release.asset)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw fail("Не вдалося завантажити оновлення") }
        progress("Розпаковую…")
        let unpacked = work.appendingPathComponent("x")
        if release.asset.pathExtension.lowercased() == "dmg" {
            let dmg = work.appendingPathComponent("update.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            let mount = work.appendingPathComponent("mnt")
            try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
            guard let inside = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw fail("В образі немає застосунку") }
            try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", [inside.path, unpacked.appendingPathComponent(inside.lastPathComponent).path])
        } else {
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        }
        guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw fail("В архіві немає застосунку") }

        progress("Перевіряю…")
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == config.bundleID else { throw fail("Це не той застосунок") }
        guard let newVersion = info?["CFBundleShortVersionString"] as? String,
              isNewer(newVersion, than: current) else { throw fail("В архіві стара версія") }
        _ = try? run("/usr/bin/xattr", ["-cr", app.path])

        // Same signer as the running copy keeps macOS permissions. A release built on GitHub may be
        // signed ad-hoc; when this Mac has the certificate of the running copy, re-sign with it.
        let mine = signer(of: Bundle.main.bundleURL) ?? config.preferredIdentity
        if let mine, signer(of: app) != mine, hasIdentity(mine) {
            progress("Підписую…")
            try run("/usr/bin/codesign", ["--force", "--deep", "--identifier", config.bundleID, "--sign", mine, app.path])
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        return app
    }

    private func swapAndRelaunch(_ newApp: URL) throws {
        let target = Bundle.main.bundleURL
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("swap-\(UUID().uuidString).sh")
        // Waits for this process to quit, swaps the bundle (old copy kept until the new one is in place), relaunches.
        let body = """
        #!/bin/bash
        PID="$1"; NEW="$2"; DEST="$3"
        for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
        OLD="${DEST%.app}.old-$$.app"
        mv "$DEST" "$OLD" || exit 1
        if ditto "$NEW" "$DEST"; then rm -rf "$OLD"; else rm -rf "$DEST"; mv "$OLD" "$DEST"; fi
        xattr -cr "$DEST" 2>/dev/null
        for _ in 1 2 3 4 5; do open "$DEST" && break; sleep 1; done
        rm -rf "$(dirname "$(dirname "$NEW")")" "$0"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path]
        try p.run()
        phase = .installing("Перезапускаю…")
        beforeRelaunch?()
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// "1.10.0" is newer than "1.9.1": numbers compared one by one, missing ones count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Common name of the leaf certificate, nil for ad-hoc.
    private nonisolated static func signer(of app: URL) -> String? {
        guard let out = try? run("/usr/bin/codesign", ["-dvv", app.path], stderr: true) else { return nil }
        return out.split(separator: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst(10)) }
    }

    private nonisolated static func hasIdentity(_ name: String) -> Bool {
        let out = (try? run("/usr/bin/security", ["find-identity", "-p", "codesigning"])) ?? ""
        return out.contains("\"\(name)\"")
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String], stderr: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        if stderr { p.standardError = pipe; p.standardOutput = FileHandle.nullDevice } else { p.standardOutput = pipe; p.standardError = pipe }
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 && !stderr {
            throw fail("\(URL(fileURLWithPath: tool).lastPathComponent): \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
        }
        return text
    }

    private nonisolated static func fail(_ text: String) -> NSError {
        NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
