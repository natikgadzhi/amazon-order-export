import Foundation
import Testing

@testable import AmazonAuth

@Suite("AmazonAuthManager")
@MainActor
struct AmazonAuthManagerTests {
    private func cookies(_ names: [String]) -> [HTTPCookie] {
        names.map {
            HTTPCookie(properties: [
                .name: $0, .value: "v", .domain: ".amazon.com", .path: "/",
            ])!
        }
    }

    @Test("complete cookie set authenticates and persists")
    func ingestComplete() {
        let store = InMemoryAmazonSecretStore()
        let manager = AmazonAuthManager(secretStore: store)
        manager.ingest(cookies: cookies(AmazonCookies.required.map(\.rawValue)))
        #expect(manager.state == .authenticated)
        #expect(store.read()?.cookies.count == AmazonCookies.required.count)
    }

    @Test("incomplete cookie set does not authenticate")
    func ingestIncomplete() {
        let store = InMemoryAmazonSecretStore()
        let manager = AmazonAuthManager(secretStore: store)
        manager.ingest(cookies: cookies(["session-id"]))
        #expect(manager.state != .authenticated)
        #expect(store.read() == nil)
    }

    @Test("initSessionFromSecureStorage restores a stored session")
    func restore() {
        let store = InMemoryAmazonSecretStore()
        store.write(
            secrets: AmazonSessionSecrets(cookies: cookies(AmazonCookies.required.map(\.rawValue))))
        let manager = AmazonAuthManager(secretStore: store)
        manager.initSessionFromSecureStorage()
        #expect(manager.state == .authenticated)
    }
}
