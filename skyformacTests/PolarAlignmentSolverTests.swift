import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct PolarAlignmentSolverTests {
    private func rotate(_ point: CGPoint, around center: CGPoint, byDegrees degrees: Double) -> CGPoint {
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(
            x: center.x + dx * cos(radians) - dy * sin(radians),
            y: center.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    @Test func solvesKnownRotationCenterFromExactCorrespondences() throws {
        let trueCenter = CGPoint(x: 320, y: 240)
        let stars: [CGPoint] = [
            CGPoint(x: 400, y: 200), CGPoint(x: 250, y: 350), CGPoint(x: 500, y: 500), CGPoint(x: 100, y: 150),
        ]
        let rotated = stars.map { rotate($0, around: trueCenter, byDegrees: 37) }

        let correspondences = zip(stars, rotated).map {
            PolarAlignmentSolver.StarCorrespondence(before: $0, after: $1)
        }
        let solved = try #require(PolarAlignmentSolver.solveRotationCenter(from: correspondences))
        #expect(abs(solved.x - trueCenter.x) < 0.01)
        #expect(abs(solved.y - trueCenter.y) < 0.01)
    }

    @Test func tooFewCorrespondencesReturnsNil() {
        let correspondences = [PolarAlignmentSolver.StarCorrespondence(before: .zero, after: .zero)]
        #expect(PolarAlignmentSolver.solveRotationCenter(from: correspondences) == nil)
    }

    @Test func matchesShuffledRotatedStarsAndSolvesCenter() throws {
        let trueCenter = CGPoint(x: 100, y: 100)
        let before: [CGPoint] = [
            CGPoint(x: 150, y: 120), CGPoint(x: 60, y: 180), CGPoint(x: 200, y: 250), CGPoint(x: 30, y: 40), CGPoint(x: 180, y: 60),
        ]
        // Same physical stars, rotated (simulating the mount rotating), and shuffled into a
        // different order (simulating that we don't know which detection is which star).
        let after = before.map { rotate($0, around: trueCenter, byDegrees: 90) }.shuffled()

        let correspondences = PolarAlignmentSolver.matchStars(before: before, after: after)
        #expect(correspondences.count == before.count) // every star should find its match

        let solved = try #require(PolarAlignmentSolver.solveRotationCenter(from: correspondences))
        #expect(abs(solved.x - trueCenter.x) < 0.5)
        #expect(abs(solved.y - trueCenter.y) < 0.5)
    }

    @Test func fewerThanTwoStarsProducesNoMatches() {
        #expect(PolarAlignmentSolver.matchStars(before: [CGPoint(x: 1, y: 1)], after: [CGPoint(x: 2, y: 2)]).isEmpty)
    }
}
