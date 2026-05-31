import Foundation
import Testing

@testable import AmazonOrders

/// Loads a captured-page fixture committed under `Fixtures/`.
private func fixture(_ name: String) throws -> String {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func dec(_ s: String) -> Decimal { Decimal(string: s)! }

@Suite("Money")
struct MoneyTests {
    @Test("parses $ and negative amounts; keeps raw")
    func parse() {
        #expect(Money("$29.83").amount == dec("29.83"))
        #expect(Money("-$1.50").amount == dec("-1.50"))
        #expect(Money("($5.00)").amount == dec("-5.00"))  // accounting-format credit
        #expect(Money(" $6.92 ").raw == "$6.92")
        #expect(Money("—").amount == nil)
    }
}

@Suite("OrdersListParser")
struct OrdersListParserTests {
    @Test("page-level: count, year, pagination")
    func pageMeta() throws {
        let page = try OrdersListParser.parse(html: fixture("OrdersList"))
        #expect(page.orderCount == 95)
        #expect(page.selectedYear == "2026")
        #expect(page.orders.count == 4)
        #expect(page.pageStartIndices.contains(0))
        #expect(page.pageStartIndices.contains(10))
        #expect(page.pageStartIndices.contains(90))
    }

    @Test("first card: header fields + single item with quantity")
    func firstCard() throws {
        let page = try OrdersListParser.parse(html: fixture("OrdersList"))
        let o = page.orders[0]
        #expect(o.id == "112-8232817-9773001")
        #expect(o.total?.amount == dec("6.92"))
        #expect(o.recipient == "Test Buyer")
        #expect(o.detailPath?.contains("order-details") == true)

        let placed = try #require(o.orderPlaced)
        let c = Calendar(identifier: .gregorian)
        var cal = c
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(cal.component(.year, from: placed) == 2026)
        #expect(cal.component(.month, from: placed) == 5)
        #expect(cal.component(.day, from: placed) == 24)

        #expect(o.items.count == 1)
        #expect(o.items[0].asin == "B08KXFY9CP")
        #expect(o.items[0].quantity == 2)
        #expect(o.items[0].title?.contains("MadeGood") == true)
    }

    @Test("multi-item card keeps both ASINs")
    func multiItem() throws {
        let page = try OrdersListParser.parse(html: fixture("OrdersList"))
        let o = try #require(page.orders.first { $0.id == "112-2809022-2262647" })
        #expect(o.total?.amount == dec("29.83"))
        #expect(Set(o.items.compactMap(\.asin)) == ["B00LAI9OM6", "B01HI7WP0U"])
    }

    @Test("grocery grid: image-only items + 'and N more' badge")
    func groceryGrid() throws {
        let page = try OrdersListParser.parse(html: fixture("OrdersList"))
        let o = try #require(page.orders.first { $0.id == "113-1083090-6951403" })
        #expect(o.recipient == "Test Market")
        #expect(o.andMoreCount == 12)
        #expect(o.items.contains { $0.asin == "B0F48L6WKC" })
    }

    @Test("multi-shipment card flattens items across delivery boxes")
    func multiShipment() throws {
        let page = try OrdersListParser.parse(html: fixture("OrdersList"))
        let o = try #require(page.orders.first { $0.id == "112-4640402-7541814" })
        #expect(Set(o.items.compactMap(\.asin)) == ["B0FG7RZ5LJ", "B0FG7WX27Z"])
    }
}

@Suite("OrderDetailParser")
struct OrderDetailParserTests {
    @Test("transactions-spine fields: id, total, card last-4, tag")
    func spine() throws {
        let d = try OrderDetailParser.parse(html: fixture("OrderDetail"))
        #expect(d.id == "112-2809022-2262647")
        #expect(d.grandTotal?.amount == dec("29.83"))
        #expect(d.payment?.description.contains("Amazon Visa") == true)
        #expect(d.payment?.lastFour == "1119")
        #expect(d.transactionsTag == "112-2809022-2262647")

        let placed = try #require(d.orderPlaced)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(cal.component(.day, from: placed) == 24)
    }

    @Test("charge breakdown lines parse to money")
    func charges() throws {
        let d = try OrderDetailParser.parse(html: fixture("OrderDetail"))
        let subtotal = try #require(d.charges.first { $0.label.contains("Item(s) Subtotal") })
        #expect(subtotal.amount.amount == dec("27.46"))
        let tax = try #require(d.charges.first { $0.label.contains("Estimated tax") })
        #expect(tax.amount.amount == dec("2.37"))
    }

    @Test("items carry unit price + sold-by + asin")
    func items() throws {
        let d = try OrderDetailParser.parse(html: fixture("OrderDetail"))
        #expect(d.items.count == 2)
        let bags = try #require(d.items.first { $0.asin == "B00LAI9OM6" })
        #expect(bags.unitPrice?.amount == dec("14.99"))
        #expect(bags.soldBy == "Earth Rated")
        let tylenol = try #require(d.items.first { $0.asin == "B01HI7WP0U" })
        #expect(tylenol.unitPrice?.amount == dec("12.47"))
        #expect(tylenol.soldBy == "Amazon.com")
    }
}
