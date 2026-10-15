import Foundation
import WhoopStore
import StrandAnalytics
import StrandImport

extension AICoachEngine {
    // MARK: Live model list

    /// Set a custom model id (any string). Adds it to the picker if it isn't already listed.
    func setCustomModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !availableModels.contains(trimmed) {
            availableModels.insert(trimmed, at: 0)
        }
        model = trimmed
    }

    /// Best-effort: GET the chosen provider's models endpoint with the saved key and merge the
    /// returned ids into `availableModels`. Never crashes; failures land in `errorText` and leave
    /// the existing list intact. Requires a saved key.
    /// When the live catalogue was last pulled for `provider`, keyed per provider so switching does
    /// not hide one provider's stale list behind another's refresh. Kotlin twin:
    /// `ZoopPrefs.coachModelsRefreshedAt`.
    static func modelsRefreshedKey(_ provider: AIProvider) -> String {
        "ai.modelsRefreshed.\(provider.rawValue)"
    }

    /// How long a pulled catalogue is trusted. Kotlin twin: `MODEL_REFRESH_INTERVAL_MS`.
    static let modelRefreshInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether a catalogue last pulled at `last` is due another pull at `now`.
    ///
    /// Split out and `static` so the rule can be pinned without an engine: it decides how often the app
    /// talks to a provider unasked. A never-pulled catalogue (0) is stale, so the first visit fetches. A
    /// clock moved BACKWARDS gives a negative age and reads as fresh, keeping the cached list rather
    /// than refetching every visit until the clock catches up. Kotlin twin:
    /// `CoachViewModel.isCatalogueStale`.
    static func isCatalogueStale(last: TimeInterval, now: TimeInterval) -> Bool {
        now - last >= modelRefreshInterval
    }

    /// Pull the live catalogue at most once a week, so the picker offers what the provider sells today
    /// without this app shipping a build for every model release.
    ///
    /// Quiet about FAILURE: it passes `silent`, so `refreshModels` leaves the error surface untouched
    /// in both directions rather than this restoring it afterwards. Restoring would have raced — there
    /// is no re-entrancy guard here, so a manual Refresh tapped during the await would have had its
    /// result stomped by a stale snapshot on resume. Not touching the state cannot race with anything.
    ///
    /// Requires a stored key, so it cannot fire during first-run setup where there is nothing to
    /// authenticate with. Custom is excluded: `connectCustom()` already pulls its list, and its server
    /// is the user's own machine rather than a vendor catalogue.
    ///
    /// Only the LIST moves. The selected model is never changed underneath the user. Kotlin twin:
    /// `CoachViewModel.refreshModelsIfStale`.
    func refreshModelsIfStale() async {
        guard provider != .custom, hasKey else { return }
        let last = UserDefaults.standard.double(forKey: Self.modelsRefreshedKey(provider))
        guard Self.isCatalogueStale(last: last, now: Date().timeIntervalSince1970) else { return }
        await refreshModels(silent: true)
    }

    /// `silent` leaves the error surface entirely alone, in both directions: an automatic refresh must
    /// neither wipe a message the user is still reading nor raise one they never asked for. Kotlin twin:
    /// the `silent` parameter on `CoachViewModel.refreshModels`.
    func refreshModels(silent: Bool = false) async {
        guard let key = resolvedKey else {
            if !silent { errorText = AICoachError.noKey.errorDescription }
            return
        }
        if !silent { errorText = nil }

        // Snapshot the provider BEFORE the await. The Picker isn't disabled during a refresh, so the
        // user can switch providers mid-flight (#873). We fetch this provider's ids, then re-check on
        // resume that it's still the live one, and merge against THIS same snapshot, so the guard and
        // the merge always use one consistent provider, never a stale/mixed list for the wrong one.
        let capturedProvider = provider

        do {
            let ids: [String]
            #if DEBUG
            if let override = fetchModelsOverride {
                ids = try await override(capturedProvider, key)
            } else {
                ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            }
            #else
            ids = try await capturedProvider.client.fetchModels(key: key, session: session)
            #endif

            // The user switched providers while we were awaiting, so these ids belong to the old one.
            // Drop them rather than write a list for a provider that's no longer selected.
            guard provider == capturedProvider else { return }

            guard !ids.isEmpty else {
                if !silent { errorText = AICoachError.decode.errorDescription }
                return
            }

            // Merge: keep the captured provider's built-in options on top, append any newly-discovered
            // ids (sorted), and preserve a current custom selection if it isn't otherwise present.
            let builtin = capturedProvider.modelOptions
            let discovered = Set(ids).subtracting(builtin).sorted()
            var merged = builtin + discovered
            if !merged.contains(model) { merged.insert(model, at: 0) }
            availableModels = merged
            // Stamp only on a SUCCESSFUL pull, so a provider that is down does not buy itself a week
            // of silence from `refreshModelsIfStale()`.
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                                      forKey: Self.modelsRefreshedKey(capturedProvider))
        } catch let e as AICoachError {
            // A switch mid-flight makes any error moot for the old provider, so don't surface it.
            guard provider == capturedProvider, !silent else { return }
            // Typed first, because this used to report EVERY failure as a network problem, including a
            // key the provider had just turned away. Refresh is one of the two places a wrong key shows
            // itself, and it was the one that blamed the wrong thing: the wearer read "Network problem"
            // and went looking at their connection. It now says what happened and, for a rejection,
            // opens the field to fix it.
            errorText = e.errorDescription
            if case .badKey = e { keyRejected = true } else { keyRejected = false }
            return
        } catch {
            guard provider == capturedProvider, !silent else { return }
            errorText = AICoachError.network(error.localizedDescription).errorDescription
            keyRejected = false
            return
        }
    }
}
