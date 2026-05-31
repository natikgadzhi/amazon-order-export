import Foundation
import os

/// Renders a logged-in Amazon page to its post-JavaScript HTML. The concrete
/// implementation (WKWebView) lives in the app; this protocol lets `ExportService`
/// be unit-tested with a stub. `@MainActor` because the only real implementation
/// drives a WKWebView, which is main-actor-bound.
@MainActor
public protocol OrderPageRendering {
  func renderedHTML(url: URL, readySelector: String) async throws -> String
}

/// Thrown when Amazon bounces a render to the sign-in page (session expired).
public struct ExpiredSessionError: Error {
  public init() {}
}

/// Coarse progress for the UI. `crawlingDetails` is determinate and carries the
/// order currently being fetched (so the UI can show it); `fetchingOrders` is not
/// (page count is unknown until the pager is walked).
public enum ExportProgress: Sendable, Equatable {
  case fetchingOrders(collected: Int)
  case crawlingDetails(done: Int, total: Int, current: OrderSummary?)
  case writingFiles
}

public struct ExportSummary: Sendable, Equatable {
  public let orderCount: Int
  public let outputDir: URL
}

/// Orchestrates an export: walk the orders pager for the range, crawl each
/// order's detail page, and write the three CSVs. Reports progress and honors
/// `Task` cancellation. Pure of WebKit/auth — the renderer is injected.
@MainActor
public final class ExportService {
  private let renderer: any OrderPageRendering
  private let log = Logger(subsystem: "io.respawn.AmazonOrderExport", category: "export")

  public init(renderer: any OrderPageRendering) {
    self.renderer = renderer
  }

  public func run(
    range: TimeRange, outputDir: URL, onProgress: @MainActor (ExportProgress) -> Void
  ) async throws -> ExportSummary {
    let orders = try await collectOrders(range: range, onProgress: onProgress)
    let details = try await collectDetails(orders: orders, onProgress: onProgress)
    onProgress(.writingFiles)
    try write(orders: orders, details: details, to: outputDir)
    return ExportSummary(orderCount: orders.count, outputDir: outputDir)
  }

  /// `.allTime` walks years backward from the current year, stopping at the first
  /// year with no orders. Every other range is a single year/window.
  private func collectOrders(
    range: TimeRange, onProgress: @MainActor (ExportProgress) -> Void
  ) async throws -> [OrderSummary] {
    var all: [OrderSummary] = []
    var seen = Set<String>()

    if case .allTime = range {
      var year = Calendar.current.component(.year, from: Date())
      while true {
        let rawCount = try await collectRange(
          .year(year), seen: &seen, into: &all, onProgress: onProgress)
        if rawCount == 0 { break }  // Amazon returned no orders for this year — done.
        year -= 1
      }
    } else {
      _ = try await collectRange(range, seen: &seen, into: &all, onProgress: onProgress)
    }
    return all
  }

  /// Breadth-first over the pager for one concrete range: each page reveals more
  /// `startIndex` links; visiting all unvisited ones converges on every page.
  /// Returns the raw number of orders Amazon returned for this range (before
  /// cross-range dedup), so the caller can tell a truly empty year from one whose
  /// orders were all already seen via pager overlap.
  private func collectRange(
    _ range: TimeRange, seen: inout Set<String>, into all: inout [OrderSummary],
    onProgress: @MainActor (ExportProgress) -> Void
  ) async throws -> Int {
    var rawCount = 0
    var visited = Set<Int>()
    var frontier = [0]
    while let start = frontier.first(where: { !visited.contains($0) }) {
      try Task.checkCancellation()
      visited.insert(start)
      let html = try await renderer.renderedHTML(
        url: OrdersURL.page(range: range, startIndex: start), readySelector: ".order-card")
      let page = try OrdersListParser.parse(html: html)
      rawCount += page.orders.count
      for order in page.orders where seen.insert(order.id).inserted {
        all.append(order)
      }
      frontier.append(contentsOf: page.pageStartIndices.filter { !visited.contains($0) })
      // Diagnostic: does Amazon honor this timeFilter? Compare the header count
      // (Amazon's own "N orders") and the pager across last-30 / months-3 / year.
      log.info(
        """
        fetch timeFilter=\(range.timeFilter ?? "all", privacy: .public) start=\(start): \
        header=\(page.orderCount ?? -1) cards=\(page.orders.count) \
        pager=\(page.pageStartIndices.map(String.init).joined(separator: ","), privacy: .public) \
        total=\(all.count)
        """)
      onProgress(.fetchingOrders(collected: all.count))
    }
    return rawCount
  }

  /// Render + parse each order's detail page for the transactions-spine fields.
  /// A short delay between pages keeps the access pattern un-botlike.
  private func collectDetails(
    orders: [OrderSummary], onProgress: @MainActor (ExportProgress) -> Void
  ) async throws -> [String: OrderDetail] {
    let targets = orders.compactMap { order -> (OrderSummary, URL)? in
      guard let path = order.detailPath, let url = OrdersURL.absolute(path) else { return nil }
      return (order, url)
    }
    var byID: [String: OrderDetail] = [:]
    for (index, (order, url)) in targets.enumerated() {
      try Task.checkCancellation()
      onProgress(.crawlingDetails(done: index, total: targets.count, current: order))
      do {
        let html = try await renderer.renderedHTML(
          url: url, readySelector: "[data-component=orderId]")
        byID[order.id] = try OrderDetailParser.parse(html: html)
      } catch is CancellationError {
        throw CancellationError()
      } catch is ExpiredSessionError {
        // Session died — abort the whole crawl so the app routes to re-login.
        throw ExpiredSessionError()
      } catch {
        // One detail page failed (a stalled/blocked render, a dead WebContent
        // process, or a Whole Foods `/fopo` layout with no orderId selector).
        // Skip it and keep going — the order still appears in orders.csv; only
        // its transactions.csv row is missing.
      }
      try? await Task.sleep(for: .milliseconds(400))
    }
    onProgress(.crawlingDetails(done: targets.count, total: targets.count, current: nil))
    return byID
  }

  private func write(
    orders: [OrderSummary], details: [String: OrderDetail], to dir: URL
  ) throws {
    // Create the destination (e.g. the default ~/Desktop/amazon-orders) if it
    // doesn't exist yet. Idempotent — no-op when the folder is already there.
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try OrdersCSV.ordersCSV(orders).write(
      to: dir.appendingPathComponent("orders.csv"), atomically: true, encoding: .utf8)
    try OrdersCSV.itemsCSV(orders).write(
      to: dir.appendingPathComponent("items.csv"), atomically: true, encoding: .utf8)
    try OrdersCSV.transactionsCSV(orders: orders, detailsByID: details).write(
      to: dir.appendingPathComponent("transactions.csv"), atomically: true, encoding: .utf8)
  }
}
