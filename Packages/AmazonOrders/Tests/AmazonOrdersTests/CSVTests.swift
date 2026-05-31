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

    @Test("transactions.csv: joins list-page date to detail-page total + card last-4")
    func transactionsCSV() throws {
        let detailURL = try #require(
            Bundle.module.url(
                forResource: "OrderDetail", withExtension: "html", subdirectory: "Fixtures"))
        let detail = try OrderDetailParser.parse(
            html: String(contentsOf: detailURL, encoding: .utf8))
        let csv = OrdersCSV.transactionsCSV(
            orders: try parsedOrders(), detailsByID: [detail.id!: detail])
        let row = try #require(
            csv.split(separator: "\n").first { $0.hasPrefix("112-2809022-2262647,") })
        // order_id, date_placed(from list), grand_total, raw, card_last4, txn_tag
        #expect(row.contains("2026-05-24"))
        #expect(row.contains("29.83"))
        #expect(row.contains(",1119,"))
        #expect(row.hasSuffix(",112-2809022-2262647"))
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
