import Foundation
import Testing
@testable import skyformac

struct RatingAndFavoriteTests {
    @Test func unratedIsZero() {
        #expect(Rating.unrated == 0)
    }

    @Test func clampedKeepsValuesInRange() {
        #expect(Rating.clamped(3) == 3)
        #expect(Rating.clamped(0) == 0)
        #expect(Rating.clamped(5) == 5)
    }

    @Test func clampedClipsBelowZeroToZero() {
        #expect(Rating.clamped(-2) == 0)
    }

    @Test func clampedClipsAboveFiveToFive() {
        #expect(Rating.clamped(9) == 5)
    }

    @Test func projectDefaultsToUnratedAndNotFavorite() {
        let project = Project.newProject(name: "P")
        #expect(project.rating == .unrated)
        #expect(!project.isFavorite)
    }

    @Test func sessionDefaultsToUnratedAndNotFavorite() {
        let session = Session.newSession(name: "S")
        #expect(session.rating == .unrated)
        #expect(!session.isFavorite)
    }

    @Test func captureRecordDefaultsToUnrated() {
        let capture = CaptureRecord(date: Date(), fileName: "a.fits", kind: .fits)
        #expect(capture.rating == .unrated)
    }

    @Test func projectRatingAndFavoriteRoundTripThroughJSON() throws {
        var project = Project.newProject(name: "P")
        project.rating = 4
        project.isFavorite = true

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        #expect(decoded.rating == 4)
        #expect(decoded.isFavorite)
    }

    @Test func sessionRatingAndFavoriteRoundTripThroughJSON() throws {
        var session = Session.newSession(name: "S")
        session.rating = 5
        session.isFavorite = true

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        #expect(decoded.rating == 5)
        #expect(decoded.isFavorite)
    }

    @Test func decodingAnOlderProjectJSONWithoutRatingOrFavoriteDefaultsBoth() throws {
        // Simulates a `project.json` written before these fields existed — missing keys should
        // decode the same as `.unrated`/`false`, not fail to load an existing project.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old Project","goal":"","createdDate":\(Date().timeIntervalSinceReferenceDate),
         "tags":[],"notes":[],"sessions":[],"isArchived":false,"folderName":"old-project"}
        """
        let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(decoded.rating == .unrated)
        #expect(!decoded.isFavorite)
    }

    @Test func decodingAnOlderSessionJSONWithoutRatingOrFavoriteDefaultsBoth() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old Session","goal":"","plannedObjects":[],
         "createdDate":\(Date().timeIntervalSinceReferenceDate),"tags":[],"notes":[],"captures":[],
         "isArchived":false,"folderName":"old-session"}
        """
        let decoded = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(decoded.rating == .unrated)
        #expect(!decoded.isFavorite)
    }

    @Test func decodingAnOlderCaptureRecordJSONWithoutRatingDefaultsToUnrated() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":\(Date().timeIntervalSinceReferenceDate),"fileName":"old.fits","kind":"fits"}
        """
        let decoded = try JSONDecoder().decode(CaptureRecord.self, from: Data(json.utf8))
        #expect(decoded.rating == .unrated)
    }
}
