import Foundation
import Testing
@testable import skyformac

struct DiskSpaceCheckerTests {
    @Test func reportsPositiveFreeSpaceForARealDirectory() throws {
        // A real integration check against the actual filesystem (not mocked) — this machine's
        // temp directory should always report some nonzero available capacity.
        let bytes = try #require(DiskSpaceChecker.availableBytes(at: FileManager.default.temporaryDirectory))
        #expect(bytes > 0)
    }

    @Test func returnsNilForANonexistentPath() {
        let bogus = URL(fileURLWithPath: "/this/path/definitely/does/not/exist/\(UUID().uuidString)")
        #expect(DiskSpaceChecker.availableBytes(at: bogus) == nil)
    }
}
