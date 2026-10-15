import Foundation
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
import IOKit.ps
import Security
#endif

// MARK: - IOSDiagnostics
//
// Captures iOS environment facts that quietly break a sideloaded health app (OS/beta, certificate
// expiry, Data Protection locking the vault, Background App Refresh, Low Power Mode) as both a
// copy-pasteable block and typed fields. The public API compiles on macOS (nils / "n/a") so shared
// callers need no `#if`.

/// A platform-safe snapshot of the iOS runtime environment; on macOS every optional is nil.
struct IOSDiagnostics {

    /// Builds a fresh snapshot. `isProtectedDataAvailable` and `backgroundRefreshStatus` are
    /// main-actor isolated; callers are on the main thread, so main isolation is assumed internally
    /// rather than annotating `capture()`.
    static func capture() -> IOSDiagnostics {
        #if os(iOS)
        let (protectedData, backgroundRefresh): (Bool, String) = MainActor.assumeIsolated {
            (UIApplication.shared.isProtectedDataAvailable,
             Self.backgroundRefreshText(UIApplication.shared.backgroundRefreshStatus))
        }
        return IOSDiagnostics(
            deviceModel: Self.machineIdentifier(),
            osVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            isProtectedDataAvailable: protectedData,
            backgroundRefresh: backgroundRefresh,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isSideloaded: Self.isSideloadedBuild(),
            sideloadExpiry: Self.provisioningExpiryDate()
        )
        #elseif os(macOS)
        return IOSDiagnostics(
            osVersionString: ProcessInfo.processInfo.operatingSystemVersionString,
            macOnAC: Self.isOnAC(),
            macSigned: Self.isSignedAndNotarized(),
            macSandboxed: Self.isAppSandboxed()
        )
        #else
        return IOSDiagnostics()
        #endif
    }

    // MARK: Fields (optional so the struct is meaningful on macOS too)

    /// Hardware model identifier, e.g. "iPhone16,2". nil on macOS.
    var deviceModel: String? = nil
    /// Full OS version string incl. build number (the build suffix is the beta tell). nil on macOS.
    var osVersionString: String? = nil
    /// false means protected files are unreadable until the user unlocks once after a reboot. nil on macOS.
    var isProtectedDataAvailable: Bool? = nil
    /// Background App Refresh: "Available" / "Denied" / "Restricted". nil on macOS.
    var backgroundRefresh: String? = nil
    /// Low Power Mode (throttles BLE + background work). nil on macOS.
    var isLowPowerMode: Bool? = nil
    /// Looks sideloaded: embedded.mobileprovision present, no App Store receipt. nil on macOS.
    var isSideloaded: Bool? = nil
    /// Provisioning profile expiry, if embedded and parseable.
    var sideloadExpiry: Date? = nil

    /// macOS: on AC power (false on battery), nil off macOS.
    var macOnAC: Bool? = nil
    /// macOS: signed plus notarized. The macOS build is intentionally unsigned, so expected false. nil off macOS.
    var macSigned: Bool? = nil
    /// macOS: whether the App Sandbox is in effect. nil off macOS.
    var macSandboxed: Bool? = nil

    // MARK: Derived

    /// Whole days until the provisioning profile expires (negative if expired); nil with no parseable profile.
    func expiryDaysRemaining() -> Int? {
        guard let expiry = sideloadExpiry else { return nil }
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.startOfDay(for: expiry)
        return cal.dateComponents([.day], from: from, to: to).day
    }

    /// A line saying this build's background-task identifiers can't register, or nil when fine.
    ///
    /// `BGTaskSchedulerPermittedIdentifiers` is baked into Info.plist at build time as
    /// `$(PRODUCT_BUNDLE_IDENTIFIER).<suffix>` while schedulers derive theirs at runtime from
    /// `Bundle.main.bundleIdentifier`; a re-signer rewriting the bundle id breaks the match and every
    /// background task goes inert silently. Reported, not worked around: only signing can fix it.
    static func backgroundTaskIdentityFault() -> String? {
        guard let runtimeID = Bundle.main.bundleIdentifier else { return nil }
        let permitted = Bundle.main.infoDictionary?["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        return backgroundTaskIdentityFault(runtimeID: runtimeID, permitted: permitted)
    }

    /// The decision alone, testable without a rebuilt Info.plist.
    static func backgroundTaskIdentityFault(runtimeID: String, permitted: [String]) -> String? {
        guard !permitted.isEmpty else { return nil }
        // Every permitted identifier is `<bundle id>.<suffix>`; if none sits under the runtime id, nothing can register.
        guard !permitted.contains(where: { $0.hasPrefix(runtimeID + ".") }) else { return nil }
        let baked = permitted.first.map { String($0.dropLast(($0.split(separator: ".").last?.count ?? 0) + 1)) }
        // States the mismatch and its consequence only; it cannot tell re-signing from a wrong prefix or hand-edited plist.
        return "Background tasks: WILL NOT REGISTER - this build runs as \(runtimeID), Info.plist permits "
            + "identifiers under \(baked ?? "a different prefix") - the derived identifiers are not in the "
            + "permitted list, so scheduled re-score, Health write-back, Coach brief and scheduled export "
            + "cannot start"
    }

    /// A multi-line environment block; empty on macOS (the header already carries OS + version).
    func summaryLines() -> [String] {
        #if os(iOS)
        var lines: [String] = []
        lines.append("Device: \(deviceModel ?? "unknown")")
        if let os = osVersionString { lines.append("iOS: \(os)") }
        if let p = isProtectedDataAvailable {
            lines.append("Data Protection: \(p ? "unlocked (files readable)" : "LOCKED — unlock once after reboot so history can sync")")
        }
        if let bg = backgroundRefresh { lines.append("Background refresh: \(bg)") }
        if let lpm = isLowPowerMode { lines.append("Low Power Mode: \(lpm ? "ON (throttles background BLE)" : "off")") }
        if let side = isSideloaded { lines.append("Sideloaded build: \(side ? "yes" : "no (App Store / TestFlight)")") }
        // Silent unless broken.
        if let broken = Self.backgroundTaskIdentityFault() { lines.append(broken) }
        if let days = expiryDaysRemaining() {
            if days < 0 {
                lines.append("Sideload expiry: EXPIRED \(-days) day\(abs(days) == 1 ? "" : "s") ago - re-sign to relaunch")
            } else {
                lines.append("Sideload expiry: \(days) day\(days == 1 ? "" : "s") remaining")
            }
        }
        return lines
        #elseif os(macOS)
        var lines: [String] = []
        if let os = osVersionString { lines.append("macOS: \(os)") }
        if let ac = macOnAC { lines.append("Power: \(ac ? "AC (plugged in)" : "battery")") }
        if let signed = macSigned {
            lines.append("Signed / notarized: \(signed ? "yes" : "no (unsigned build, Gatekeeper bypass expected)")")
        }
        if let sb = macSandboxed {
            lines.append("App Sandbox: \(sb ? "on (network entitlement gates the AI Coach)" : "off")")
        }
        return lines
        #else
        return []
        #endif
    }

    // MARK: - iOS-only probes

    #if os(iOS)

    /// Hardware model identifier (e.g. "iPhone16,2") via `utsname.machine`; the host arch on the Simulator.
    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    /// Human-readable Background App Refresh status.
    private static func backgroundRefreshText(_ status: UIBackgroundRefreshStatus) -> String {
        switch status {
        case .available:  return "Available"
        case .denied:     return "Denied (off in Settings)"
        case .restricted: return "Restricted (parental/MDM)"
        @unknown default: return "Unknown"
        }
    }

    /// Heuristic: sideloaded = ships `embedded.mobileprovision` and has no App Store receipt.
    private static func isSideloadedBuild() -> Bool {
        let hasProfile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
        let receiptExists: Bool = {
            guard let url = Bundle.main.appStoreReceiptURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }()
        return hasProfile && !receiptExists
    }

    /// Extracts `ExpirationDate` from the embedded provisioning profile. The `.mobileprovision` is a
    /// CMS blob wrapping an XML plist, so the plist is sliced out (`<?xml` to `</plist>`) and parsed
    /// rather than decoding CMS. Nil if absent or unparseable.
    private static func provisioningExpiryDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }

        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)

        guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any]
        else { return nil }

        return plist["ExpirationDate"] as? Date
    }

    #endif

    // MARK: - macOS-only probes

    #if os(macOS)

    /// True when drawing AC power (IOKit power sources); false on battery or if unreadable.
    private static func isOnAC() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSACPowerValue
            }
        }
        return false
    }

    /// Whether the build is signed and notarized; the macOS build ships unsigned, so expected false.
    private static func isSignedAndNotarized() -> Bool {
        // An unsigned build fails validity, giving a truthful "no".
        return Bundle.main.executableURL.flatMap { url -> Bool? in
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
                  let code = staticCode else { return false }
            let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)
            return status == errSecSuccess
        } ?? false
    }

    /// Whether the App Sandbox is active (container env marker present).
    private static func isAppSandboxed() -> Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    #endif
}
