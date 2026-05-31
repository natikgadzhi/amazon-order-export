import Foundation
import Testing

@testable import AmazonOrders

/// Returns the orders-list fixture for startIndex=0 and an empty page otherwise
/// (so the BFS pager terminates), and the order-details fixture for any
/// order-details URL. Records progress is done by the caller, not here.
@MainActor
final class StubRenderer: OrderPageRendering {
  let listHTML: String
  let detailHTML: String
  private(set) var requested: [URL] = []

  init(listHTML: String, detailHTML: String) {
    self.listHTML = listHTML
    self.detailHTML = detailHTML
  }

  func renderedHTML(url: URL, readySelector: String) async throws -> String {
    requested.append(url)
    if url.absoluteString.contains("order-details") { return detailHTML }
    let start =
      URLComponents(url: url, resolvingAgainstBaseURL: false)?
      .queryItems?.first { $0.name == "startIndex" }?.value
    return (start == "0" || start == nil) ? listHTML : "<html><body></body></html>"
  }
}

@MainActor
private func fixture(_ name: String) throws -> String {
  let url = try #require(
    Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"))
  return try String(contentsOf: url, encoding: .utf8)
}

@Suite("ExportService")
@MainActor
struct ExportServiceTests {
  private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("aox-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test("writes orders.csv, items.csv, transactions.csv with progress")
  func writesAllThree() async throws {
    let renderer = StubRenderer(
      listHTML: try fixture("OrdersList"), detailHTML: try fixture("OrderDetail"))
    let service = ExportService(renderer: renderer)
    let dir = try tempDir()

    var progress: [ExportProgress] = []
    let summary = try await service.run(range: .year(2026), outputDir: dir) { progress.append($0) }

    let orders = try String(
      contentsOf: dir.appendingPathComponent("orders.csv"), encoding: .utf8)
    let items = try String(contentsOf: dir.appendingPathComponent("items.csv"), encoding: .utf8)
    let txns = try String(
      contentsOf: dir.appendingPathComponent("transactions.csv"), encoding: .utf8)

    #expect(orders.hasPrefix("order_id,date_placed,total_amount"))
    #expect(items.contains("112-2809022-2262647,B01HI7WP0U,1,"))
    // The detail fixture joins on its order id with grand total + card last-4.
    #expect(txns.contains("112-2809022-2262647,") && txns.contains(",1119,"))
    #expect(summary.orderCount > 0)
    #expect(progress.contains(.writingFiles))
    #expect(
      progress.contains { if case .fetchingOrders = $0 { return true } else { return false } })
  }

  @Test("cancellation stops the export")
  func cancels() async throws {
    let renderer = StubRenderer(
      listHTML: try fixture("OrdersList"), detailHTML: try fixture("OrderDetail"))
    let service = ExportService(renderer: renderer)
    let dir = try tempDir()

    let task = Task { try await service.run(range: .year(2026), outputDir: dir) { _ in } }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    // Cancellation happens before write(), so no files should exist.
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("orders.csv").path))
  }

  @Test("creates the output directory when it doesn't exist yet")
  func createsOutputDirectory() async throws {
    let renderer = StubRenderer(
      listHTML: try fixture("OrdersList"), detailHTML: try fixture("OrderDetail"))
    let service = ExportService(renderer: renderer)
    // A not-yet-existing nested path, like the default ~/Desktop/amazon-orders.
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("aox-test-\(UUID().uuidString)/amazon-orders", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: dir.path))

    _ = try await service.run(range: .year(2026), outputDir: dir) { _ in }

    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("orders.csv").path))
  }
}
