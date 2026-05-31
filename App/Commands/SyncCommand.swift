import AmazonAuth
import AmazonOrders
import ArgumentParser
import Foundation

/// `sync --year 2026 [--out DIR]` — render every orders-list page for the year
/// (reusing the stored session), parse them, and write `orders.csv` + `items.csv`.
struct SyncCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sync",
    abstract: "Render your orders for a year and write orders.csv + items.csv.")

  @Option(help: "Calendar year to export, e.g. 2026.") var year: Int
  @Option(help: "Directory to write the CSV files into.") var out: String = "."
  @Flag(
    name: .customLong("with-details"),
    help:
      "Also open each order's details page for card last-4 + transaction tag (writes transactions.csv; slower)."
  )
  var withDetails = false
  @Option(help: "Stop after N orders — handy for a quick, gentle first run.") var limit: Int?

  @MainActor
  func run() async throws {
    let (year, out, withDetails, limit) = (self.year, self.out, self.withDetails, self.limit)
    AppRunLoop.runHeadless {
      await Self.export(year: year, outDir: out, withDetails: withDetails, limit: limit)
    }
  }

  @MainActor
  private static func export(year: Int, outDir: String, withDetails: Bool, limit: Int?) async {
    guard let secrets = KeychainAmazonSecretStore().read() else {
      fail("no stored session — run `authenticate` first")
    }
    do {
      let renderer = await OrderPageRenderer(secrets: secrets)
      let orders = try await collectOrders(renderer, year: year, limit: limit)

      let dir = URL(fileURLWithPath: outDir, isDirectory: true)
      try OrdersCSV.ordersCSV(orders)
        .write(
          to: dir.appendingPathComponent("orders.csv"), atomically: true, encoding: .utf8)
      try OrdersCSV.itemsCSV(orders)
        .write(
          to: dir.appendingPathComponent("items.csv"), atomically: true, encoding: .utf8)
      print("Wrote \(orders.count) orders → \(dir.path)/orders.csv, items.csv")

      if withDetails {
        let details = try await collectDetails(renderer, orders: orders)
        try OrdersCSV.transactionsCSV(orders: orders, detailsByID: details)
          .write(
            to: dir.appendingPathComponent("transactions.csv"), atomically: true,
            encoding: .utf8)
        print("Wrote \(details.count) transaction rows → \(dir.path)/transactions.csv")
      }
    } catch is OrderPageRenderer.ExpiredSession {
      fail("session expired — run `authenticate` again")
    } catch {
      fail("sync failed: \(error)")
    }
  }

  /// Breadth-first over the pager: each page reveals more `startIndex` links;
  /// visiting all unvisited ones converges on every page for the year. Stops
  /// early once `limit` orders are collected.
  @MainActor
  private static func collectOrders(_ renderer: OrderPageRenderer, year: Int, limit: Int?)
    async throws -> [OrderSummary]
  {
    var orders: [OrderSummary] = []
    var seen = Set<String>()
    var visited = Set<Int>()
    var frontier = [0]
    while let start = frontier.first(where: { !visited.contains($0) }) {
      visited.insert(start)
      let html = try await renderer.renderedHTML(
        url: OrdersURL.page(year: year, startIndex: start), readySelector: ".order-card")
      let page = try OrdersListParser.parse(html: html)
      for order in page.orders where seen.insert(order.id).inserted { orders.append(order) }
      frontier.append(contentsOf: page.pageStartIndices.filter { !visited.contains($0) })
      print(
        "  page startIndex=\(start): +\(page.orders.count) (running total \(orders.count))")
      if let limit, orders.count >= limit { return Array(orders.prefix(limit)) }
    }
    return orders
  }

  /// Render + parse each order's details page for the transactions-spine fields.
  /// A short delay between pages keeps the access pattern un-botlike.
  @MainActor
  private static func collectDetails(_ renderer: OrderPageRenderer, orders: [OrderSummary])
    async throws -> [String: OrderDetail]
  {
    var byID: [String: OrderDetail] = [:]
    for order in orders {
      guard let path = order.detailPath, let url = OrdersURL.absolute(path) else { continue }
      let html = try await renderer.renderedHTML(
        url: url, readySelector: "[data-component=orderId]")
      let detail = try OrderDetailParser.parse(html: html)
      byID[order.id] = detail
      print(
        "  detail \(order.id): \(detail.grandTotal?.raw ?? "?") card ****\(detail.payment?.lastFour ?? "?")"
      )
      try? await Task.sleep(for: .milliseconds(400))
    }
    return byID
  }

  /// Print to stderr and exit non-zero. ArgumentParser only sets a failure exit
  /// code when `run()` throws, but our work runs inside the AppKit run loop and
  /// can't throw back out — so failures must set the code themselves, or scripts
  /// calling `sync` would see success on a failed export.
  fileprivate static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(EXIT_FAILURE)  // not ArgumentParser's Command.exit(_:)
  }
}

/// `dump-orders --year 2026 --out page.html [--start-index N]` — render one page
/// and write its raw HTML. Used to capture PII-scrubbed parser fixtures.
struct DumpOrdersCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dump-orders",
    abstract: "Render one orders page and write its HTML (for capturing fixtures).")

  @Option(help: "Calendar year, e.g. 2026.") var year: Int
  @Option(help: "File to write the rendered HTML to.") var out: String
  @Option(name: .customLong("start-index"), help: "Pagination offset (0, 10, 20, …).")
  var startIndex: Int = 0

  @MainActor
  func run() async throws {
    let (year, out, startIndex) = (self.year, self.out, self.startIndex)
    AppRunLoop.runHeadless {
      guard let secrets = KeychainAmazonSecretStore().read() else {
        SyncCommand.fail("no stored session — run `authenticate` first")
      }
      do {
        let renderer = await OrderPageRenderer(secrets: secrets)
        let html = try await renderer.renderedHTML(
          url: OrdersURL.page(year: year, startIndex: startIndex),
          readySelector: ".order-card")
        try html.write(toFile: out, atomically: true, encoding: .utf8)
        print("Wrote \(html.count) bytes → \(out)")
      } catch {
        SyncCommand.fail("dump-orders failed: \(error)")
      }
    }
  }
}
