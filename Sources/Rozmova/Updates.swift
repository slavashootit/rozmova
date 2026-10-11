import Foundation

/// Looks for a newer release on GitHub. Nothing is downloaded by itself: the menu and one
/// notification point to the release page.
@MainActor
final class Updates {
    struct Release {
        let version: String
        let page: URL
    }

    private static let api = URL(string: "https://api.github.com/repos/slavashootit/rozmova/releases/latest")!

    private(set) var available: Release?
    var onFound: ((Release) -> Void)?

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() async {
        guard Prefs.checkUpdates else { return }
        var request = URLRequest(url: Self.api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard Self.isNewer(version, than: Self.current) else {
                available = nil
                return
            }
            let release = Release(version: version, page: page)
            available = release
            onFound?(release)
        } catch {
            Log.info("Update check failed: \(error.localizedDescription)")
        }
    }

    /// "0.10.0" is newer than "0.9.1": numbers compared one by one, missing ones count as 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
