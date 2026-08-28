import Foundation
import Testing
@testable import skyformac

struct KeychainStoreTests {
    @Test func setAndReadRoundTripsAValue() {
        let key = "test-\(UUID().uuidString)"
        defer { KeychainStore.set(nil, forKey: key) }
        KeychainStore.set("sk-test-12345", forKey: key)
        #expect(KeychainStore.string(forKey: key) == "sk-test-12345")
    }

    @Test func readingAnUnsetKeyReturnsNil() {
        #expect(KeychainStore.string(forKey: "never-set-\(UUID().uuidString)") == nil)
    }

    @Test func settingNilDeletesAnExistingValue() {
        let key = "test-\(UUID().uuidString)"
        KeychainStore.set("something", forKey: key)
        KeychainStore.set(nil, forKey: key)
        #expect(KeychainStore.string(forKey: key) == nil)
    }

    @Test func settingAnEmptyStringDeletesRatherThanStoresBlank() {
        let key = "test-\(UUID().uuidString)"
        KeychainStore.set("something", forKey: key)
        KeychainStore.set("", forKey: key)
        #expect(KeychainStore.string(forKey: key) == nil)
    }

    @Test func settingTwiceUpdatesRatherThanFailing() {
        let key = "test-\(UUID().uuidString)"
        defer { KeychainStore.set(nil, forKey: key) }
        KeychainStore.set("first", forKey: key)
        KeychainStore.set("second", forKey: key)
        #expect(KeychainStore.string(forKey: key) == "second")
    }
}
