import Foundation

/// A preallocated raw buffer reused across every poll of `ASIGetVideoData`, per the project's
/// "pre-allocate a fixed-size buffer to avoid re-allocating memory on every frame" rule.
/// Only reallocates when the ROI/format actually changes size.
final class FrameBuffer {
    private(set) var pointer: UnsafeMutableRawBufferPointer
    private(set) var byteCount: Int

    init(byteCount: Int) {
        self.byteCount = byteCount
        self.pointer = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 16)
    }

    /// Resizes storage only if `newByteCount` differs from the current capacity.
    func ensureCapacity(_ newByteCount: Int) {
        guard newByteCount != byteCount else { return }
        pointer.deallocate()
        byteCount = newByteCount
        pointer = UnsafeMutableRawBufferPointer.allocate(byteCount: newByteCount, alignment: 16)
    }

    deinit {
        pointer.deallocate()
    }
}
