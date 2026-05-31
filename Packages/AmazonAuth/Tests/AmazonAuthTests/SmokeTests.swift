import Testing

@testable import AmazonAuth

@Suite("AmazonAuth smoke")
struct SmokeTests {
    @Test("module is wired up")
    func moduleName() {
        #expect(AmazonAuth.moduleName == "AmazonAuth")
    }
}
