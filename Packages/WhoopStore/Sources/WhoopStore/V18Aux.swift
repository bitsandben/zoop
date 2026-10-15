import Foundation
import WhoopProtocol

/// Storage codec for the 5/MG v18 auxiliary-field stream (`v18AuxSample.fields`).
///
/// A blob rather than columns: seventeen slots arrive once per strap-second, nullable columns cost a
/// header byte each on a hot table, and every new slot would be a migration. One blob costs a 5-byte
/// header plus the present bytes, and a new slot appends a bitmap bit. SQL cannot filter on a slot,
/// which is fine since nothing queries these yet.
///
/// Wire format (little-endian, no padding):
///
///     byte  0      format version (`formatVersion`)
///     bytes 1..4   u32 presence bitmap; bit `V18AuxSlot.rawValue` set == that slot follows
///     bytes 5..    each present slot's value, in ascending slot order, `slot.width` bytes each
///
/// A clear bit means "the strap did not report this field", never 0. Slots are unsigned integers of
/// 1, 2 or 4 bytes (`unknownF32At113` is banked as its raw 32-bit pattern); interpretation happens at
/// the accessor. Byte-identical to the Kotlin `V18AuxCodec`, both deriving order and widths from `V18AuxSlot`.
public enum V18AuxCodec {
    /// Bumped only for an incompatible layout change. A reader meeting an unknown version returns an empty
    /// sample rather than mis-parsing.
    ///
    /// v2 widened the bitmap from u16 to u32 and split the `@36`/`@37` and `@106`/`@107` pairs into two u8
    /// slots each, shifting every bit position past `cardiacFlags`. A v1 row reads back as unknown rather
    /// than mis-sliced; v1 never shipped.
    public static let formatVersion = 2
    /// Version byte + u32 bitmap. Widened at v2 because 17 slots do not fit a u16.
    static let headerBytes = 5

    /// Packs a sample's slots. Returns empty `Data` when nothing is present so the caller can skip the row.
    public static func pack(_ sample: V18AuxSample) -> Data {
        let values = sample.slotValues
        var bitmap = 0
        var body = Data()
        for slot in V18AuxSlot.allCases {
            guard slot.rawValue < values.count, let v = values[slot.rawValue] else { continue }
            bitmap |= (1 << slot.rawValue)
            // Truncate to the slot's declared width; a no-op for wire values, a guard against out-of-range input.
            let u = UInt32(truncatingIfNeeded: v)
            for byte in 0..<slot.width { body.append(UInt8(truncatingIfNeeded: u >> (8 * byte))) }
        }
        if bitmap == 0 { return Data() }
        var out = Data(capacity: headerBytes + body.count)
        out.append(UInt8(formatVersion))
        for byte in 0..<4 { out.append(UInt8(truncatingIfNeeded: bitmap >> (8 * byte))) }
        out.append(body)
        return out
    }

    /// Inverse of `pack`. A malformed, truncated or unknown-version blob yields an all-nil sample rather
    /// than throwing. Trailing bytes past the last known slot are ignored, so a row from a later build
    /// still decodes the slots this build knows.
    public static func unpack(_ data: Data, ts: Int) -> V18AuxSample {
        let bytes = [UInt8](data)
        let empty = V18AuxSample(ts: ts)
        guard bytes.count >= headerBytes, Int(bytes[0]) == formatVersion else { return empty }
        var bitmap = 0
        for byte in 0..<4 { bitmap |= Int(bytes[1 + byte]) << (8 * byte) }
        var values = [Int?](repeating: nil, count: V18AuxSlot.allCases.count)
        var i = headerBytes
        for slot in V18AuxSlot.allCases {
            guard bitmap & (1 << slot.rawValue) != 0 else { continue }
            guard i + slot.width <= bytes.count else { return V18AuxSample(ts: ts, slotValues: values) }
            var u = 0
            for byte in 0..<slot.width { u |= Int(bytes[i + byte]) << (8 * byte) }
            values[slot.rawValue] = u
            i += slot.width
        }
        return V18AuxSample(ts: ts, slotValues: values)
    }
}
