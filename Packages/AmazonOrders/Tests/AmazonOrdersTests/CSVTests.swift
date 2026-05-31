import Foundation
import Testing

@testable import AmazonOrders

@Suite("OrdersCSV")
struct OrdersCSVTests {
    private func parsedOrders() throws -> [OrderSummary] {
        let url = try #require(
            Bundle.module.url(
                forResource: "OrdersList", withExtension: "html", subdirectory: "Fixtures"))
        return try OrdersListParser.parse(html: String(contentsOf: url, encoding: .utf8)).orders
    }

    @Test("orders.csv: header + one row per order, ISO date, amount")
    func ordersCSV() throws {
        let csv = OrdersCSV.ordersCSV(try parsedOrders())
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(
            lines.first
                == "order_id,date_placed,total_amount,total_raw,recipient,item_count,and_more")
        let row = try #require(lines.first { $0.hasPrefix("112-8232817-9773001,") })
        #expect(row.contains("2026-05-24"))
        #expect(row.contains("6.92"))
    }

    @Test("items.csv: one row per line item")
    func itemsCSV() throws {
        let csv = OrdersCSV.itemsCSV(try parsedOrders())
        let dataLines = csv.split(separator: "\n").dropFirst()
        // Card A(1) + B(2) + C(2 grid) + D(2) = 7 items across the fixture.
        #expect(dataLines.count == 7)
        #expect(csv.contains("112-2809022-2262647,B01HI7WP0U,1,"))
    }

    @Test("fields with commas are quoted (RFC 4180)")
    func quoting() {
        let order = OrderSummary(
            id: "1-2-3", orderPlaced: nil, orderPlacedRaw: "May 1, 2026",
            total: Money("$1.00"), recipient: "Doe, Jane", detailPath: nil,
            items: [], andMoreCount: 0)
        let csv = OrdersCSV.ordersCSV([order])
        #expect(csv.contains("\"Doe, Jane\""))
        #expect(csv.contains("\"May 1, 2026\""))
    }
}
