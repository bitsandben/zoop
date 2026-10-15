import Foundation
import WhoopProtocol

/// "Check for updates": one call to the project's public releases API (GitHub), comparing the latest
/// version to the installed one. Nothing about the user is sent, and it never installs anything.
///
/// Two callers: the Settings button (only when tapped) and `UpdateWatch`, the daily check (at most
/// once a day after onboarding and the Terms gate; ON by default, off in Settings stops the request).
/// See docs/PRIVACY_SECURITY.md section 1.1c. Uses the network-client entitlement, otherwise only
/// for the opt-in AI Coach.
@MainActor
final class UpdateChecker: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate(version: String)
        case available(version: String, url: URL, notes: String)
        case failed
    }

    @Published var state: State = .idle

    private static let endpoint = URL(string: "https://api.github.com/repos/bitsandben/zoop/releases/latest")!

    /// One release read shared by the button and the automatic check, so endpoint, headers and parsing
    /// exist in one copy.
    struct Release: Equatable {
        let version: String
        let url: URL
        let notes: String
    }

    static func fetchLatest() async -> Release? {
        do {
            var req = URLRequest(url: Self.endpoint, timeoutInterval: 12)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let urlString = json["html_url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return Release(version: latest, url: url, notes: cleanNotes(json["body"] as? String ?? ""))
        } catch {
            return nil
        }
    }

    func check(currentVersion: String) {
        guard state != .checking else { return }
        state = .checking
        Task {
            guard let release = await Self.fetchLatest() else {
                state = .failed
                return
            }
            state = VersionCheck.isNewer(release.version, than: currentVersion)
                ? .available(version: release.version, url: release.url, notes: release.notes)
                : .upToDate(version: release.version)
        }
    }

    /// Turns a GitHub release body into a short "what's new": drops the "Downloads" footer, strips heavy markdown, caps the length.
    static func cleanNotes(_ body: String) -> String {
        var s = body.components(separatedBy: "Downloads").first ?? body
        for marker in ["**", "## ", "# "] { s = s.replacingOccurrences(of: marker, with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 700 { s = String(s.prefix(700)).trimmingCharacters(in: .whitespacesAndNewlines) + "…" }
        return s
    }
}
