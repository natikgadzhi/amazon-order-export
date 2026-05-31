import Foundation
import SwiftSoup

extension Element {
    /// Text of the first descendant matching `selector`, or nil if none.
    /// Collapses the repeated `select(sel).first().map { try $0.text() }` dance.
    func firstText(_ selector: String) throws -> String? {
        try select(selector).first().map { try $0.text() }
    }

    /// Value of `attribute` on the first descendant matching `selector`, or nil.
    func firstAttr(_ selector: String, _ attribute: String) throws -> String? {
        try select(selector).first().map { try $0.attr(attribute) }
    }
}

/// **All** Amazon DOM coupling lives here, on purpose.
///
/// These class names and `data-component` hooks are Amazon's private markup —
/// they change without notice. Centralizing them means a layout change is a
/// one-file fix, and these constants get the most direct test coverage (the
/// fixtures in `Tests/.../Fixtures` are captured real pages).
enum Sel {
    // Orders-list page
    static let orderCard = "div.order-card.js-order-card"
    static let numOrders = ".num-orders"
    static let yearOptionSelected = "#time-filter option[selected]"
    static let pagerLink = "ul.a-pagination a[href*=startIndex]"

    static let headerListItem = "li.order-header__header-list-item"
    static let capsLabel = ".a-text-caps"
    static let baseValue = "span.a-size-base"
    static let recipientTrigger = ".yohtmlc-recipient .insert-encrypted-trigger-text"
    static let orderIdValue = ".yohtmlc-order-id span[dir=ltr]"
    static let orderDetailsLink = "a.a-link-normal[href*=order-details]"

    static let listItemDetailed = "div.a-fixed-left-grid.item-box"
    static let listItemGridImage = "div.product-grid-image"
    static let productTitleLink = ".yohtmlc-product-title a"
    static let qtyBadge = ".product-image__qty"
    static let andMore = ".and-more-message-box__and-more-message-text-container"
    static let dpLink = "a[href*=/dp/]"

    // Order-details page
    static let orderDetailsRoot = "#orderDetails"
    static let component = "data-component"  // attribute, queried as [data-component=...]
    static let chargeRow = ".od-line-item-row"
    static let chargeLabel = ".od-line-item-row-label"
    static let chargeContent = ".od-line-item-row-content"
    static let paymentInstrumentRow = ".pmts-payments-instrument-detail-box-paystationpaymentmethod"
    static let transactionsLink = ".pmts-view-your-transactions-button a"

    static func component(_ name: String) -> String { "[data-component=\(name)]" }
}

/// Shared parsing helpers (also Amazon-flavored: date format, ASIN shape).
enum Parse {
    /// `/dp/B00LAI9OM6?...` → `"B00LAI9OM6"`. `_ASINLESS_` and the like → nil.
    static func asin(fromHref href: String) -> String? {
        guard let range = href.range(of: "/dp/") else { return nil }
        let after = href[range.upperBound...]
        let candidate = String(after.prefix(10))
        let isAsin =
            candidate.count == 10
            && candidate.allSatisfy { $0.isUppercase && $0.isLetter || $0.isNumber }
        return isAsin ? candidate : nil
    }

    /// `"May 24, 2026"` → a `Date` (UTC, POSIX), or nil if Amazon changes the format.
    static func date(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMMM d, yyyy"
        return f.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// First run of digits in `s` as an Int (e.g. `"95 orders"` → 95).
    static func firstInt(in s: String) -> Int? {
        let digits = s.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Value of query item `name` from a possibly-relative href. Takes everything
    /// after the *first* `?` (not the last), so a value that itself contains `?`
    /// can't drop the parameter we want. SwiftSoup has already decoded `&amp;`.
    static func queryValue(_ name: String, inHref href: String) -> String? {
        guard let q = href.firstIndex(of: "?") else { return nil }
        let query = String(href[href.index(after: q)...])
        return URLComponents(string: "https://x/?" + query)?
            .queryItems?.first { $0.name == name }?.value
    }

    /// 4-digit group following "ending in" (card last-4), if present.
    static func lastFour(in s: String) -> String? {
        guard let r = s.range(of: "ending in ") else { return nil }
        let digits = s[r.upperBound...].prefix { $0.isNumber }
        return digits.count == 4 ? String(digits) : nil
    }
}
