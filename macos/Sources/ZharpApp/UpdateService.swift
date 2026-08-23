import AppKit
import UserNotifications

/// Update channel: asks the website for the newest released version and, when
/// one is available, opens the download page.
///
/// The Windows build hands off to a silent Inno Setup upgrade. macOS apps are
/// distributed as a signed disk image the user drags into /Applications, so the
/// macOS build reports the new version and opens `/download` instead of
/// replacing itself in place.
enum UpdateService {
    static let currentVersion = App.version

    struct VersionInfo {
        let version: String
        let publishedAt: String?
    }

    /// Fetches the newest advertised version, or nil when the check fails.
    ///
    /// The endpoint serves per-platform releases; without the parameter it
    /// answers for Windows, which is what the pre-macOS clients expect.
    static func latest(baseURL: String) async -> String? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            + "/api/version?platform=macos") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Zharp/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let version = json?["version"] as? String, !version.isEmpty else { return nil }
            return version
        } catch {
            App.log("Update check failed: \(error)")
            return nil
        }
    }

    static var downloadURL: URL? {
        URL(string: "https://zharp.app/download?platform=macos")
    }

    /// Compares dotted versions numerically ("0.10.0" > "0.9.9").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let lhs = i < a.count ? a[i] : 0
            let rhs = i < b.count ? b[i] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// Posts a user notification about an available release, once per version.
    static func notify(version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Zharp update available"
            content.body = "Version \(version) is ready to install - you have \(currentVersion)."
            let request = UNNotificationRequest(identifier: "zharp.update.\(version)",
                                                content: content, trigger: nil)
            center.add(request)
        }
    }
}
