import Foundation
import Testing

@testable import AmazonOrders

@Suite("TimeRange → orders URL")
struct TimeRangeURLTests {
  @Test("each range maps to Amazon's timeFilter token")
  func timeFilterTokens() {
    #expect(TimeRange.last30.timeFilter == "last30")
    #expect(TimeRange.months3.timeFilter == "months-3")
    #expect(TimeRange.year(2026).timeFilter == "year-2026")
    #expect(TimeRange.allTime.timeFilter == nil)
  }

  @Test("page(range:startIndex:) builds the orders URL with both query items")
  func pageURL() throws {
    let url = OrdersURL.page(range: .year(2025), startIndex: 20)
    let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(comps.path == "/your-orders/orders")
    let items = Dictionary(
      uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
    #expect(items["timeFilter"] == "year-2025")
    #expect(items["startIndex"] == "20")
  }
}
