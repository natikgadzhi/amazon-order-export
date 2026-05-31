import Testing

@testable import AmazonOrders

@Suite("AmazonOrders smoke")
struct SmokeTests {
    @Test("module is wired up")
    func moduleName() {
        #expect(AmazonOrders.moduleName == "AmazonOrders")
    }
}
