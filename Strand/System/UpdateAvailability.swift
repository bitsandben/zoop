import Foundation
import WhoopProtocol

/// When may Zoop look for a newer release on its own, and when is it worth telling the user?
///
/// The manual "Check for updates" button is user-initiated (see `UpdateChecker`). This is the
/// automatic half: a sideloaded iOS app cannot install or re-sign an `.ipa` (only AltStore/SideStore
/// can), so the most the app can do is notice and post a row to the existing Updates inbox, with no
/// new surface and no interruption (#1659).
enum UpdateAvailability {

    /// ON by default (#1659). A sideloaded app has no store to update it, so a default nobody discovers
    /// means silently running an old build. The request is one read of a public version number, once a
    /// day, after onboarding and the Terms gate; nothing about the user is sent. Turning it off in
    /// Settings stops the request entirely.
    static let defaultEnabled = true

    /// Once a day; the watched thing moves on a days-to-weeks scale.
    static let checkInterval: TimeInterval = 24 * 60 * 60

    /// May a background check run now? `lastCheckedAt` is epoch seconds, 0 meaning never checked (due
    /// immediately). `now < lastCheckedAt` (clock moved backwards) counts as due, which self-heals on the next write.
    static func shouldCheckNow(enabled: Bool,
                               lastCheckedAt: TimeInterval,
                               now: TimeInterval,
                               interval: TimeInterval = checkInterval) -> Bool {
        guard enabled else { return false }
        if lastCheckedAt <= 0 { return true }
        if now < lastCheckedAt { return true }          // clock went backwards — don't strand the check
        return now - lastCheckedAt >= interval
    }

    /// Is this result worth a row in the inbox? Once per version: `lastPostedVersion` is persisted, so a
    /// user who can't act quickly (AltStore or a re-sign) isn't nagged daily.
    static func shouldPost(latest: String, current: String, lastPostedVersion: String?) -> Bool {
        guard VersionCheck.isNewer(latest, than: current) else { return false }
        return latest != lastPostedVersion
    }

    /// Has the install caught up with a version we previously announced? Then the "is available" row is
    /// stale and should be pruned; the persisted `lastPostedVersion` makes this answerable without
    /// parsing the title. Evaluated even when the toggle is OFF, so a stale row can't outlive the feature.
    static func shouldPruneAnnouncement(lastPostedVersion: String?, current: String) -> Bool {
        guard let posted = lastPostedVersion, !posted.isEmpty else { return false }
        return !VersionCheck.isNewer(posted, than: current)
    }

    /// Assembles the row's body from already-localized fragments. User-facing copy is localized per
    /// platform (the i18n gates only scan SwiftUI `Text` literals, not model strings); the assembly
    /// (order, single space, blank line before notes, trimming) is the tested logic.
    static func composeMessage(body: String, sideload: String?, notes: String) -> String {
        var s = body
        if let sideload, !sideload.isEmpty { s += " " + sideload }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { s += "\n\n" + trimmed }
        return s
    }
}

// MARK: - The automatic check

/// Drives the automatic check: decide, fetch, post, remember. Kept out of `UpdateAvailability` so
/// that stays pure and testable without a network or clock.
enum UpdateWatch {

    enum Keys {
        /// On by default; see `UpdateAvailability.defaultEnabled`.
        static let enabled = "updates.autoCheck"
        static let lastCheckedAt = "updates.lastCheckedAt"
        static let lastPostedVersion = "updates.lastPostedVersion"
    }

    /// The real marketing version from the bundle (CFBundleShortVersionString), never a hand-edited
    /// constant that can go stale; shared by the button and the automatic check.
    static var installedVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? AppChangelog.currentVersion
    }

    /// Re-entrancy guard: `runIfDue` is called from `.onAppear` and the day's slot is stamped inside the
    /// task, so two quick appearances could both pass the due check.
    @MainActor private static var inFlight = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? UpdateAvailability.defaultEnabled
    }

    /// Runs a check if one is due and posts to the inbox if the result is worth saying. Early returns are
    /// silent by design (it runs at launch; the manual button is the loud path).
    @MainActor
    static func runIfDue(currentVersion: String, sideloadHint: Bool, now: Date = Date()) {
        let d = UserDefaults.standard
        // Runs before every guard, including the toggle: a stale announcement must not outlive the feature.
        if UpdateAvailability.shouldPruneAnnouncement(
            lastPostedVersion: d.string(forKey: Keys.lastPostedVersion), current: currentVersion) {
            for item in UpdateStore.shared.items where item.kind == .newVersion {
                UpdateStore.shared.remove(item.id)
            }
            d.removeObject(forKey: Keys.lastPostedVersion)
        }
        guard !inFlight else { return }
        guard UpdateAvailability.shouldCheckNow(enabled: isEnabled,
                                                lastCheckedAt: d.double(forKey: Keys.lastCheckedAt),
                                                now: now.timeIntervalSince1970) else { return }
        inFlight = true
        Task {
            defer { inFlight = false }
            // Stamped BEFORE examining the result: a failed read must still consume the day's slot, or an
            // unreachable GitHub would retry on every launch.
            d.set(now.timeIntervalSince1970, forKey: Keys.lastCheckedAt)
            guard let release = await UpdateChecker.fetchLatest() else { return }
            guard UpdateAvailability.shouldPost(latest: release.version,
                                                current: currentVersion,
                                                lastPostedVersion: d.string(forKey: Keys.lastPostedVersion))
            else { return }
            d.set(release.version, forKey: Keys.lastPostedVersion)
            // Localized here, at the platform edge, like the What's New row.
            let body = String(localized: "You're on \(currentVersion). Open Settings and use Check for updates to see what's new and download \(release.version).")
            let sideload = sideloadHint
                ? String(localized: "AltStore or SideStore can install it for you automatically if you added Zoop's source; a direct .ipa still has to be signed on your device.")
                : nil
            UpdateStore.shared.post(UpdateItem(
                kind: .newVersion,
                title: String(localized: "Zoop \(release.version) is available"),
                message: UpdateAvailability.composeMessage(body: body,
                                                           sideload: sideload,
                                                           notes: release.notes)))
        }
    }
}
