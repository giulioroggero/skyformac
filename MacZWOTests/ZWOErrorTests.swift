import Testing
@testable import MacZWO

struct ZWOErrorTests {
    @Test func successRawCodeDoesNotThrow() throws {
        try ZWOError.check(ASI_SUCCESS.rawValue.signedRepresentation)
    }

    @Test func cameraRemovedMapsCorrectly() {
        let error = ZWOError(rawCode: ASI_ERROR_CAMERA_REMOVED.rawValue.signedRepresentation)
        #expect(error == .cameraRemoved)
    }

    @Test func timeoutMapsCorrectly() {
        let error = ZWOError(rawCode: ASI_ERROR_TIMEOUT.rawValue.signedRepresentation)
        #expect(error == .timeout)
    }

    @Test func unknownCodeFallsBackToUnknownCase() {
        let error = ZWOError(rawCode: 9999)
        #expect(error == .unknown(9999))
    }

    @Test func checkThrowsForNonSuccessCode() {
        #expect(throws: ZWOError.self) {
            try ZWOError.check(ASI_ERROR_INVALID_ID.rawValue.signedRepresentation)
        }
    }
}

private extension UInt32 {
    var signedRepresentation: Int32 { Int32(bitPattern: self) }
}
