import Foundation
import Testing
@testable import skyformac

struct CalibrationLibraryTests {
    private func frame() -> CapturedFrame {
        CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data([1, 2, 3, 4]))
    }

    @Test func firstAddedDarkBecomesActiveAutomatically() {
        let library = CalibrationLibrary()
        let entry = library.addDark(frame(), exposureMicroseconds: 1_000_000)
        #expect(library.activeDarkID == entry.id)
        #expect(library.activeDark?.id == entry.id)
    }

    @Test func addingSecondDarkDoesNotChangeActiveSelection() {
        let library = CalibrationLibrary()
        let first = library.addDark(frame(), exposureMicroseconds: 1_000_000)
        _ = library.addDark(frame(), exposureMicroseconds: 2_000_000)
        #expect(library.activeDarkID == first.id)
        #expect(library.darkFrames.count == 2)
    }

    @Test func removingActiveDarkFallsBackToFirstRemaining() {
        let library = CalibrationLibrary()
        let first = library.addDark(frame(), exposureMicroseconds: 1_000_000)
        let second = library.addDark(frame(), exposureMicroseconds: 2_000_000)
        library.removeDark(id: first.id)
        #expect(library.activeDarkID == second.id)
        #expect(library.darkFrames.count == 1)
    }

    @Test func removingLastDarkClearsActiveSelection() {
        let library = CalibrationLibrary()
        let only = library.addDark(frame(), exposureMicroseconds: 1_000_000)
        library.removeDark(id: only.id)
        #expect(library.activeDarkID == nil)
        #expect(library.activeDark == nil)
    }

    @Test func flatsAreIndependentOfDarks() {
        let library = CalibrationLibrary()
        let dark = library.addDark(frame(), exposureMicroseconds: 1_000_000)
        let flat = library.addFlat(frame(), exposureMicroseconds: 500_000)
        #expect(library.activeDarkID == dark.id)
        #expect(library.activeFlatID == flat.id)
        #expect(library.flatFrames.count == 1)
        #expect(library.darkFrames.count == 1)
    }

    @Test func resetClearsEverything() {
        let library = CalibrationLibrary()
        _ = library.addDark(frame(), exposureMicroseconds: 1_000_000)
        _ = library.addFlat(frame(), exposureMicroseconds: 500_000)
        library.reset()
        #expect(library.darkFrames.isEmpty)
        #expect(library.flatFrames.isEmpty)
        #expect(library.activeDarkID == nil)
        #expect(library.activeFlatID == nil)
    }
}
