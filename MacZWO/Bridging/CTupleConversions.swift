import Foundation

/// Helpers for pulling Swift-friendly values out of the fixed-size C arrays
/// (imported by Swift as tuples) found in ZWO SDK structs like `ASI_CAMERA_INFO`.
enum CTuple {
    /// Reads a fixed-size C `char[N]` (imported as a tuple of `CChar`) as a Swift `String`.
    static func string<T>(fromCCharTuple tuple: T) -> String {
        withUnsafePointer(to: tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cPtr in
                String(cString: cPtr)
            }
        }
    }

    /// Reads a fixed-size C `int[N]` (imported as a tuple of `Int32`) into a Swift `[Int32]`,
    /// stopping at the first `terminator` value (ZWO SDK arrays are terminated/padded with
    /// a sentinel such as `0` for bin lists or `-1` for format lists).
    static func int32Array<T>(fromTuple tuple: T, count: Int, terminator: Int32) -> [Int32] {
        let all: [Int32] = withUnsafePointer(to: tuple) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: count) { intPtr in
                (0..<count).map { intPtr[$0] }
            }
        }
        if let stopIndex = all.firstIndex(of: terminator) {
            return Array(all[..<stopIndex])
        }
        return all
    }
}
