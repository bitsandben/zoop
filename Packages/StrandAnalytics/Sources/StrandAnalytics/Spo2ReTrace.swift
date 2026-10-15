import Foundation

// Spo2ReTrace: the Connection-mode SpO2 reverse-engineering dump.
//
// Zoop nulls spo2Pct for WHOOP on purpose: a calibrated % needs the dense dual-wavelength waveform plus
// WHOOP's proprietary curve, and guessing it would fabricate a health number (cf. the withdrawn #194
// PPG->HR attempt). The only honest path is to see whether the strap already banks a computed SpO2 in an
// unmapped record field. This dumps a few FULL historical records (hex) beside their mapped red/IR
// channels, log-only and gated behind Test Centre Connection mode, for offline correlation. Records dump
// whether or not they carry SpO2 channels. No user-facing SpO2 value comes from this.
//
// Pure formatter: no I/O, no state, no PII.
public enum Spo2ReTrace {

    /// Max records dumped per offload session, across all layout versions. Keeps the strap log bounded.
    public static let maxSamples = 12

    /// Max records dumped per distinct layout version, so a dominant layout cannot spend the whole budget
    /// and starve a rarer, still-unmapped one.
    public static let maxPerVersion = 3

    /// Max records examined per session, separate from how many are dumped. Without it, a strap emitting one
    /// layout stays below `maxSamples` forever and every chunk re-examines every frame.
    public static let maxExamined = 512

    /// One record's RE line: mapped SpO2 channels, timestamp and layout version, then the FULL frame hex (the
    /// unmapped tail is where a banked SpO2 would sit). Absent channels render "null". Takes already-extracted
    /// ints so this package stays free of a WhoopProtocol dependency.
    public static func recordLine(frame: [UInt8], version: Int?, unix: Int?,
                                  red: Int?, ir: Int?, skinRaw: Int?) -> String {
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        func f(_ v: Int?) -> String { v.map(String.init) ?? "null" }
        return "spo2re v=\(f(version)) unix=\(f(unix)) red=\(f(red)) ir=\(f(ir)) "
            + "skinRaw=\(f(skinRaw)) len=\(frame.count) raw=\(hex)"
    }
}
