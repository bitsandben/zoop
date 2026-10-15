import Foundation
import StrandAnalytics
#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

// MARK: - Apple Health mindful sessions
//
// Reads mindful-minute samples other apps (Apple's Mindfulness app, Headspace, …) wrote to Health.
// Read access is requested with the rest of the bridge's read set (`HealthKitBridge.readTypes`); without
// it, or without HealthKit, the query returns nothing and the section simply counts the other sources.
// Samples Zoop's own sessions might match are de-duplicated later by `MindfulPractice.merge`.

enum MindfulHealthReader {

    static func sessions(since: Date) async -> [MindfulPractice.Session] {
        #if os(iOS) && canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { return [] }
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: [])
        return await withCheckedContinuation { cont in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 2_000,
                                      sortDescriptors: nil) { _, samples, _ in
                let mapped = (samples ?? []).map { s in
                    MindfulPractice.Session(startTs: Int(s.startDate.timeIntervalSince1970),
                                            endTs: Int(s.endDate.timeIntervalSince1970),
                                            kind: .meditation, source: .appleHealth)
                }
                cont.resume(returning: mapped)
            }
            store.execute(query)
        }
        #else
        return []
        #endif
    }
}
