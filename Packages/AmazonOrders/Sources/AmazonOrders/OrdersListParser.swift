import Foundation
import SwiftSoup

/// Parses the `/your-orders/orders` list page into `OrderSummary` rows.
///
/// The list page is the cheap bulk source: every order's id, placed-date, total,
/// recipient and items, ten per page. Pagination `startIndex` values are returned
/// so a caller can walk all pages without re-deriving them.
public enum OrdersListParser {
  public static func parse(html: String) throws -> OrdersPage {
    let doc = try SwiftSoup.parse(html)

    let orderCount = try doc.firstText(Sel.numOrders).flatMap(Parse.firstInt(in:))

    let selectedYear = try doc.select(Sel.yearOptionSelected).first()?
      .attr("value").replacingOccurrences(of: "year-", with: "")

    var starts = Set<Int>()
    for link in try doc.select(Sel.pagerLink).array() {
      if let value = Parse.queryValue("startIndex", inHref: try link.attr("href")),
        let n = Int(value)
      {
        starts.insert(n)
      }
    }

    let orders = try doc.select(Sel.orderCard).array().map(parseCard)

    return OrdersPage(
      orderCount: orderCount, selectedYear: selectedYear, orders: orders,
      pageStartIndices: starts.sorted())
  }

  private static func parseCard(_ card: Element) throws -> OrderSummary {
    // Order id: prefer the visible "Order #" value; fall back to the slot id.
    let id = try card.firstText(Sel.orderIdValue) ?? slotID(card) ?? ""

    var placedRaw = ""
    var total: Money?
    for li in try card.select(Sel.headerListItem).array() {
      let label = try li.firstText(Sel.capsLabel) ?? ""
      switch label.lowercased() {
      case "order placed":
        placedRaw = try li.firstText(Sel.baseValue) ?? ""
      case "total":
        total = try li.firstText(Sel.baseValue).map(Money.init)
      default:
        break
      }
    }

    let recipient = try card.firstText(Sel.recipientTrigger)
    let detailPath = try card.firstAttr(Sel.orderDetailsLink, "href")
    let andMore = try card.firstText(Sel.andMore).flatMap(Parse.firstInt(in:)) ?? 0

    return OrderSummary(
      id: id, orderPlaced: Parse.date(placedRaw), orderPlacedRaw: placedRaw,
      total: total, recipient: recipient, detailPath: detailPath,
      items: try parseItems(card), andMoreCount: andMore)
  }

  private static func parseItems(_ card: Element) throws -> [OrderItem] {
    var items: [OrderItem] = []

    // Detailed rows (title + image + optional quantity badge).
    for box in try card.select(Sel.listItemDetailed).array() {
      let href = try box.firstAttr(Sel.dpLink, "href")
      let title = try box.firstText(Sel.productTitleLink) ?? imgAlt(box)
      let qty = try box.firstText(Sel.qtyBadge).flatMap(Parse.firstInt(in:)) ?? 1
      items.append(
        OrderItem(
          asin: href.flatMap(Parse.asin(fromHref:)), title: title,
          quantity: qty, imageURL: try imgSrc(box)))
    }

    // Image-only grocery grid tiles.
    for tile in try card.select(Sel.listItemGridImage).array() {
      let href = try tile.firstAttr(Sel.dpLink, "href")
      items.append(
        OrderItem(
          asin: href.flatMap(Parse.asin(fromHref:)), title: imgAlt(tile),
          quantity: 1, imageURL: try imgSrc(tile)))
    }

    return items
  }

  private static func slotID(_ card: Element) -> String? {
    let slot = (try? card.attr("data-csa-c-slot-id")) ?? ""
    return slot.split(separator: ".").last.map(String.init)
  }

  private static func imgAlt(_ el: Element) -> String? {
    let alt = (try? el.firstAttr("img", "alt")) ?? nil
    return (alt?.isEmpty == false) ? alt : nil
  }

  private static func imgSrc(_ el: Element) throws -> String? {
    try el.firstAttr("img", "src")
  }
}
