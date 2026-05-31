import Foundation

/// Builds the stable orders-list URLs we navigate. Kept pure + tested because
/// the query-param shape (`timeFilter=year-YYYY`, `startIndex=N`) is Amazon's
/// and worth pinning down in one place.
public enum OrdersURL {
  public static func page(year: Int, startIndex: Int = 0) -> URL {
    var c = URLComponents(string: "https://www.amazon.com/your-orders/orders")!
    c.queryItems = [
      URLQueryItem(name: "timeFilter", value: "year-\(year)"),
      URLQueryItem(name: "startIndex", value: "\(startIndex)"),
    ]
    return c.url!
  }

  /// Absolutize a relative `detailPath` scraped from a card (e.g.
  /// `/your-orders/order-details?orderID=…`).
  public static func absolute(_ path: String) -> URL? {
    if path.hasPrefix("http") { return URL(string: path) }
    return URL(string: "https://www.amazon.com" + path)
  }
}
