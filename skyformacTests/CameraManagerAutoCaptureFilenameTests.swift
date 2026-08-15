import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerAutoCaptureFilenameTests {
    private var fixedDate: Date {
        DateComponents(calendar: .current, year: 2026, month: 8, day: 15, hour: 21, minute: 30, second: 45).date!
    }

    @Test func usesTheObjectNameAndDateTime() {
        let name = CameraManager.autoCaptureFilename(object: "M13", extension: "fits", date: fixedDate)
        #expect(name == "M13-2026-08-15-213045.fits")
    }

    @Test func fallsBackToAGenericNameWhenNoObjectIsGiven() {
        let name = CameraManager.autoCaptureFilename(object: nil, extension: "png", date: fixedDate)
        #expect(name == "capture-2026-08-15-213045.png")
    }

    @Test func fallsBackToAGenericNameWhenTheObjectIsBlank() {
        let name = CameraManager.autoCaptureFilename(object: "   ", extension: "tiff", date: fixedDate)
        #expect(name == "capture-2026-08-15-213045.tiff")
    }

    @Test func sanitizesUnsafeCharactersInTheObjectName() {
        let name = CameraManager.autoCaptureFilename(object: "M13/Herc:ules", extension: "ser", date: fixedDate)
        #expect(name == "M13-Herc-ules-2026-08-15-213045.ser")
    }
}
