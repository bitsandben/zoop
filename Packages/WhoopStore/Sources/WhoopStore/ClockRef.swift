import Foundation

/// The strap-clock to wall-clock correlation captured at the start of a session. Held by the live and
/// backfill paths; every historical decode is offset by it. Kept out of `RawOutbox.swift` because that
/// file is wrapped in `#if canImport(Compression)`, which would hide this type on other platforms.
public struct ClockRef: Equatable, Codable {
    public let device: Int
    public let wall: Int
    public init(device: Int, wall: Int) { self.device = device; self.wall = wall }
}
