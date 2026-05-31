# Amazon Order Export — SwiftUI app rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CLI prototype with a single-window, mac-only SwiftUI app that signs in to Amazon, exports the chosen date range to CSV (orders + items + transactions), and reveals the result in Finder.

**Architecture:** All orchestration moves into a testable `ExportService` in the `AmazonOrders` package (depends on an injected `OrderPageRendering` protocol, not WebKit). `App/` becomes a thin SwiftUI shell — a `@main` SwiftUI app, an `@Observable` view-model, a handful of views, the concrete WKWebView renderer, and a tiny in-repo design layer. The ArgumentParser CLI, its commands, and the AppKit run-loop shim are deleted.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI (macOS 26 "Tahoe"+ for the app target; packages stay `.macOS(.v14)`), WebKit, SwiftSoup, swift-testing, XcodeGen.

**Reference design:** `docs/superpowers/specs/2026-05-31-amazon-order-export-gui-design.md`.

**Conventions reminder:** 2-space indent (`.swift-format`); `import Testing` (`@Suite`/`@Test`/`#expect`/`#require`), not XCTest; commit messages end with the `Co-Authored-By` trailer below. Run `make format` before each commit; the pre-commit hook also auto-formats.

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

---

## File Structure

**New (package — `AmazonOrders`):**
- `Packages/AmazonOrders/Sources/AmazonOrders/TimeRange.swift` — the export range enum + `timeFilter` mapping.
- `Packages/AmazonOrders/Sources/AmazonOrders/ExportService.swift` — orchestration: `OrderPageRendering` protocol, `ExpiredSessionError`, `ExportProgress`, `ExportSummary`, `ExportService`.
- `Packages/AmazonOrders/Tests/AmazonOrdersTests/TimeRangeTests.swift`
- `Packages/AmazonOrders/Tests/AmazonOrdersTests/ExportServiceTests.swift`

**New (app):**
- `App/DesignSystem/DSTokens.swift`, `App/DesignSystem/PrimaryButtonStyle.swift`, `App/DesignSystem/ScreenLayout.swift`
- `App/Model/ExportModel.swift` (includes the `ExportPhase` enum)
- `App/Views/RootView.swift`, `IdleView.swift`, `ExportingView.swift`, `FinishedView.swift`, `FailedView.swift`

**Modified:**
- `Packages/AmazonOrders/Sources/AmazonOrders/OrdersURL.swift` — add `page(range:startIndex:)`; remove `page(year:)` in Task 6.
- `App/OrderPageRenderer.swift` — conform to `OrderPageRendering`; throw `ExpiredSessionError` (Task 6).
- `App/AmazonOrderExportApp.swift` — replaced by the SwiftUI `@main App` (Task 6).
- `project.yml`, `.github/workflows/ci.yml`, `README.md`.

**Deleted (Task 6):**
- `App/Commands/AuthenticateCommand.swift`, `CheckCommand.swift`, `SyncCommand.swift`, `DumpOrdersCommand.swift`
- `App/AppRunLoop.swift`

**Reused as-is:** `App/LoginWindow.swift` (`LoginWebView` + `LoginWindowContent`) — presented in a `.sheet`. `AmazonAuth` package (`AmazonAuthManager`, Keychain store). Parsers + `OrdersCSV`.

**Note on tasks 3–5:** these only *add* files. The old ArgumentParser `@main` stays the entry point and the app keeps building. Task 6 is the single commit that flips the entry point to SwiftUI and deletes the CLI.

---

### Task 1: `TimeRange` + range-based `OrdersURL`

**Files:**
- Create: `Packages/AmazonOrders/Sources/AmazonOrders/TimeRange.swift`
- Modify: `Packages/AmazonOrders/Sources/AmazonOrders/OrdersURL.swift`
- Test: `Packages/AmazonOrders/Tests/AmazonOrdersTests/TimeRangeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/AmazonOrders/Tests/AmazonOrdersTests/TimeRangeTests.swift`:

```swift
import Foundation
import Testing

@testable import AmazonOrders

@Suite("TimeRange → orders URL")
struct TimeRangeURLTests {
  @Test("each range maps to Amazon's timeFilter token")
  func timeFilterTokens() {
    #expect(TimeRange.last30.timeFilter == "last-30")
    #expect(TimeRange.months3.timeFilter == "months-3")
    #expect(TimeRange.year(2026).timeFilter == "year-2026")
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/AmazonOrders --filter TimeRange`
Expected: FAIL to build — `Cannot find 'TimeRange' in scope` / `page(range:` not found.

- [ ] **Step 3: Create `TimeRange.swift`**

```swift
import Foundation

/// The date range the user exports. Cases map to Amazon's own order-history
/// `timeFilter` query values (the dropdown on the orders page), except
/// `.allTime`, which `ExportService` expands by walking `.year(n)` backward.
/// `Hashable` so it can tag a SwiftUI `Picker`.
public enum TimeRange: Sendable, Equatable, Hashable {
  case last30
  case months3
  case year(Int)
  case allTime

  /// The `timeFilter` query value, or nil for `.allTime` (which has no single
  /// Amazon filter — it's a loop over years).
  public var timeFilter: String? {
    switch self {
    case .last30: return "last-30"
    case .months3: return "months-3"
    case .year(let y): return "year-\(y)"
    case .allTime: return nil
    }
  }
}
```

- [ ] **Step 4: Add `page(range:startIndex:)` to `OrdersURL.swift`**

Insert this method into `enum OrdersURL`, directly above the existing `page(year:startIndex:)`:

```swift
  /// Orders-list URL for a concrete range. `.allTime` is not a valid argument
  /// here — the caller expands it into `.year(n)` requests.
  public static func page(range: TimeRange, startIndex: Int = 0) -> URL {
    guard let filter = range.timeFilter else {
      preconditionFailure("OrdersURL.page(range:) requires a concrete range, not .allTime")
    }
    var c = URLComponents(string: "https://www.amazon.com/your-orders/orders")!
    c.queryItems = [
      URLQueryItem(name: "timeFilter", value: filter),
      URLQueryItem(name: "startIndex", value: "\(startIndex)"),
    ]
    return c.url!
  }
```

(Leave `page(year:startIndex:)` in place for now; it's removed in Task 6 once the CLI is gone.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path Packages/AmazonOrders --filter TimeRange`
Expected: PASS (2 tests).

- [ ] **Step 6: Format + commit**

```bash
make format
git add Packages/AmazonOrders/Sources/AmazonOrders/TimeRange.swift \
        Packages/AmazonOrders/Sources/AmazonOrders/OrdersURL.swift \
        Packages/AmazonOrders/Tests/AmazonOrdersTests/TimeRangeTests.swift
git commit -m "AmazonOrders: add TimeRange + range-based OrdersURL.page"
```

---

### Task 2: `ExportService` (orchestration, testable with a stub renderer)

**Files:**
- Create: `Packages/AmazonOrders/Sources/AmazonOrders/ExportService.swift`
- Test: `Packages/AmazonOrders/Tests/AmazonOrdersTests/ExportServiceTests.swift`

This task ports the BFS pager + detail crawl that currently live in `App/Commands/SyncCommand.swift` into a reusable service that reports progress and honors cancellation, driven by an injected renderer protocol.

- [ ] **Step 1: Write the failing test**

Create `Packages/AmazonOrders/Tests/AmazonOrdersTests/ExportServiceTests.swift`:

```swift
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
    #expect(progress.contains { if case .fetchingOrders = $0 { return true } else { return false } })
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
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Packages/AmazonOrders --filter ExportService`
Expected: FAIL to build — `Cannot find 'OrderPageRendering' / 'ExportService' / 'ExportProgress' in scope`.

- [ ] **Step 3: Create `ExportService.swift`**

```swift
import Foundation

/// Renders a logged-in Amazon page to its post-JavaScript HTML. The concrete
/// implementation (WKWebView) lives in the app; this protocol lets `ExportService`
/// be unit-tested with a stub. `@MainActor` because the only real implementation
/// drives a WKWebView, which is main-actor-bound.
@MainActor
public protocol OrderPageRendering {
  func renderedHTML(url: URL, readySelector: String) async throws -> String
}

/// Thrown when Amazon bounces a render to the sign-in page (session expired).
public struct ExpiredSessionError: Error {}

/// Coarse progress for the UI. `crawlingDetails` is determinate; `fetchingOrders`
/// is not (page count is unknown until the pager is walked).
public enum ExportProgress: Sendable, Equatable {
  case fetchingOrders(collected: Int)
  case crawlingDetails(done: Int, total: Int)
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
        let added = try await collectRange(
          .year(year), seen: &seen, into: &all, onProgress: onProgress)
        if added == 0 { break }
        year -= 1
      }
    } else {
      _ = try await collectRange(range, seen: &seen, into: &all, onProgress: onProgress)
    }
    return all
  }

  /// Breadth-first over the pager for one concrete range: each page reveals more
  /// `startIndex` links; visiting all unvisited ones converges on every page.
  /// Returns how many new orders this range contributed.
  private func collectRange(
    _ range: TimeRange, seen: inout Set<String>, into all: inout [OrderSummary],
    onProgress: @MainActor (ExportProgress) -> Void
  ) async throws -> Int {
    var added = 0
    var visited = Set<Int>()
    var frontier = [0]
    while let start = frontier.first(where: { !visited.contains($0) }) {
      try Task.checkCancellation()
      visited.insert(start)
      let html = try await renderer.renderedHTML(
        url: OrdersURL.page(range: range, startIndex: start), readySelector: ".order-card")
      let page = try OrdersListParser.parse(html: html)
      for order in page.orders where seen.insert(order.id).inserted {
        all.append(order)
        added += 1
      }
      frontier.append(contentsOf: page.pageStartIndices.filter { !visited.contains($0) })
      onProgress(.fetchingOrders(collected: all.count))
    }
    return added
  }

  /// Render + parse each order's detail page for the transactions-spine fields.
  /// A short delay between pages keeps the access pattern un-botlike.
  private func collectDetails(
    orders: [OrderSummary], onProgress: @MainActor (ExportProgress) -> Void
  ) async throws -> [String: OrderDetail] {
    let targets = orders.compactMap { order -> (String, URL)? in
      guard let path = order.detailPath, let url = OrdersURL.absolute(path) else { return nil }
      return (order.id, url)
    }
    var byID: [String: OrderDetail] = [:]
    for (index, (id, url)) in targets.enumerated() {
      try Task.checkCancellation()
      onProgress(.crawlingDetails(done: index, total: targets.count))
      let html = try await renderer.renderedHTML(
        url: url, readySelector: "[data-component=orderId]")
      byID[id] = try OrderDetailParser.parse(html: html)
      try? await Task.sleep(for: .milliseconds(400))
    }
    onProgress(.crawlingDetails(done: targets.count, total: targets.count))
    return byID
  }

  private func write(
    orders: [OrderSummary], details: [String: OrderDetail], to dir: URL
  ) throws {
    try OrdersCSV.ordersCSV(orders).write(
      to: dir.appendingPathComponent("orders.csv"), atomically: true, encoding: .utf8)
    try OrdersCSV.itemsCSV(orders).write(
      to: dir.appendingPathComponent("items.csv"), atomically: true, encoding: .utf8)
    try OrdersCSV.transactionsCSV(orders: orders, detailsByID: details).write(
      to: dir.appendingPathComponent("transactions.csv"), atomically: true, encoding: .utf8)
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Packages/AmazonOrders --filter ExportService`
Expected: PASS (2 tests).

- [ ] **Step 5: Run the whole package suite (no regressions)**

Run: `swift test --package-path Packages/AmazonOrders`
Expected: PASS (existing 13 + TimeRange 2 + ExportService 2 = 17).

- [ ] **Step 6: Format + commit**

```bash
make format
git add Packages/AmazonOrders/Sources/AmazonOrders/ExportService.swift \
        Packages/AmazonOrders/Tests/AmazonOrdersTests/ExportServiceTests.swift
git commit -m "AmazonOrders: add ExportService (orchestration + progress + cancel)"
```

---

### Task 3: In-repo design layer

**Files:**
- Create: `App/DesignSystem/DSTokens.swift`, `App/DesignSystem/PrimaryButtonStyle.swift`, `App/DesignSystem/ScreenLayout.swift`

Additive — these are unreferenced until the views land. The app still builds via the old `@main`.

- [ ] **Step 1: Create `DSTokens.swift`**

```swift
import SwiftUI

/// The whole "design system": a few spacing + sizing constants over system
/// fonts and colors. Deliberately tiny and self-contained — no external
/// dependency — so the look stays consistent without ceremony.
enum DS {
  enum Spacing {
    static let tight: CGFloat = 8
    static let standard: CGFloat = 16
    static let loose: CGFloat = 24
  }
  /// Max content width for the single window's screens.
  static let screenWidth: CGFloat = 520
  static let buttonHeight: CGFloat = 44
  static let cornerRadius: CGFloat = 10
}
```

- [ ] **Step 2: Create `PrimaryButtonStyle.swift`**

```swift
import SwiftUI

/// The prominent call-to-action button: full-width, accent-filled, rounded.
struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.body.bold())
      .frame(maxWidth: .infinity)
      .frame(height: DS.buttonHeight)
      .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1))
      .foregroundStyle(.white)
      .clipShape(RoundedRectangle(cornerRadius: DS.cornerRadius, style: .continuous))
  }
}
```

- [ ] **Step 3: Create `ScreenLayout.swift`**

```swift
import SwiftUI

/// Consistent screen chrome: left-aligned column, capped width, generous padding.
struct ScreenLayout: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: DS.screenWidth, alignment: .leading)
      .padding(DS.Spacing.loose)
  }
}

extension View {
  func screenLayout() -> some View { modifier(ScreenLayout()) }
}
```

- [ ] **Step 4: Format + commit**

```bash
make format
git add App/DesignSystem
git commit -m "App: add tiny in-repo design layer (tokens, button style, layout)"
```

---

### Task 4: `ExportModel` + `ExportPhase`

**Files:**
- Create: `App/Model/ExportModel.swift`

Additive. `ExportModel` is the view-model glue: it owns auth + export state and is deliberately thin (the logic it calls — `ExportService`, `AmazonAuthManager` — is already tested), so it is verified live rather than unit-tested.

- [ ] **Step 1: Create `ExportModel.swift`**

```swift
import AmazonAuth
import AmazonOrders
import Foundation
import Observation

/// What the single window is currently showing.
enum ExportPhase: Equatable {
  case idle
  case authenticating
  case exporting(ExportProgress)
  case finished(ExportSummary)
  case failed(message: String, canReauth: Bool)
}

/// Coordinates authentication and export for the one window. Thin glue over
/// `AmazonAuthManager` (login + Keychain) and `ExportService` (the crawl).
@MainActor
@Observable
final class ExportModel {
  let authManager: AmazonAuthManager
  var outputDir: URL?
  var range: TimeRange
  var phase: ExportPhase = .idle

  /// `true` while the login sheet should be shown.
  var isAuthenticating: Bool {
    if case .authenticating = phase { return true }
    return false
  }

  private static let outputDirKey = "outputDirPath"

  init(authManager: AmazonAuthManager) {
    self.authManager = authManager
    self.range = .year(Calendar.current.component(.year, from: Date()))
    if let path = UserDefaults.standard.string(forKey: Self.outputDirKey) {
      self.outputDir = URL(fileURLWithPath: path, isDirectory: true)
    }
    authManager.initSessionFromSecureStorage()
  }

  func setOutputDir(_ url: URL) {
    outputDir = url
    UserDefaults.standard.set(url.path, forKey: Self.outputDirKey)
  }

  /// Primary action. If unauthenticated, show the login sheet first; otherwise
  /// export immediately.
  func authenticateAndExport() {
    guard outputDir != nil else { return }
    if authManager.state == .authenticated {
      startExport()
    } else {
      phase = .authenticating
      authManager.startLogin()
    }
  }

  /// Called by the login sheet when cookies are captured.
  func didAuthenticate() {
    startExport()
  }

  func cancel() {
    exportTask?.cancel()
  }

  func reset() {
    phase = .idle
  }

  private var exportTask: Task<Void, Never>?

  private func startExport() {
    guard let outputDir, let secrets = authManager.secrets else {
      phase = .failed(message: "Missing session or output folder.", canReauth: false)
      return
    }
    phase = .exporting(.fetchingOrders(collected: 0))
    exportTask = Task {
      do {
        let renderer = await OrderPageRenderer(secrets: secrets)
        let service = ExportService(renderer: renderer)
        let summary = try await service.run(range: range, outputDir: outputDir) { progress in
          self.phase = .exporting(progress)
        }
        phase = .finished(summary)
      } catch is CancellationError {
        phase = .idle
      } catch is ExpiredSessionError {
        authManager.reset()
        phase = .failed(message: "Your Amazon session expired.", canReauth: true)
      } catch {
        phase = .failed(message: error.localizedDescription, canReauth: false)
      }
    }
  }
}
```

- [ ] **Step 2: Format + commit**

(The app target still builds via the old `@main`; `ExportModel` references `OrderPageRenderer`, which already exists. `OrderPageRenderer` does not yet conform to `OrderPageRendering` — that happens in Task 6 — but `ExportService(renderer:)` requires conformance. To keep this task compiling on its own, the conformance is added here as a one-line extension and the full switch-over stays in Task 6.)

Two edits to `App/OrderPageRenderer.swift` now: (a) add `import AmazonOrders` to the imports (needed for the `OrderPageRendering` protocol), and (b) add this extension at the bottom — the single protocol conformance. The existing nested `ExpiredSession` type and its throw site are left untouched until Task 6.

```swift
extension OrderPageRenderer: OrderPageRendering {
  func renderedHTML(url: URL, readySelector: String) async throws -> String {
    try await renderedHTML(url: url, readySelector: readySelector, timeout: .seconds(20))
  }
}
```

Then:

```bash
make build
# Expected: ** BUILD SUCCEEDED ** (app still launches as the old CLI for now)
make format
git add App/Model/ExportModel.swift App/OrderPageRenderer.swift
git commit -m "App: add ExportModel/ExportPhase + renderer protocol conformance"
```

---

### Task 5: Views

**Files:**
- Create: `App/Views/IdleView.swift`, `ExportingView.swift`, `FinishedView.swift`, `FailedView.swift`, `RootView.swift`

Additive; verified with `#Preview` (the old `@main` is still the entry point, so these don't show at runtime yet).

- [ ] **Step 1: Create `IdleView.swift`**

```swift
import AmazonAuth
import AppKit
import SwiftUI

/// The resting screen: pick a folder + range, then export.
struct IdleView: View {
  @Bindable var model: ExportModel

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Export your Amazon orders")
        .font(.title).bold()
      Text("Choose a folder and a date range. Amazon Order Export signs you in, "
        + "then writes orders.csv, items.csv, and transactions.csv.")
        .foregroundStyle(.secondary)

      folderRow
      Picker("Range", selection: $model.range) {
        Text("Last 30 days").tag(TimeRange.last30)
        Text("Past 3 months").tag(TimeRange.months3)
        Text("This year").tag(TimeRange.year(Calendar.current.component(.year, from: Date())))
        Text("All time").tag(TimeRange.allTime)
      }
      .pickerStyle(.menu)

      Button(buttonTitle) { model.authenticateAndExport() }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.outputDir == nil)
    }
    .screenLayout()
  }

  private var buttonTitle: String {
    model.authManager.state == .authenticated ? "Export" : "Sign in & Export"
  }

  private var folderRow: some View {
    HStack(spacing: DS.Spacing.tight) {
      Image(systemName: "folder")
      Text(model.outputDir?.path ?? "No folder chosen")
        .foregroundStyle(model.outputDir == nil ? .secondary : .primary)
        .lineLimit(1).truncationMode(.middle)
      Spacer()
      Button("Choose…") { chooseFolder() }
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      model.setOutputDir(url)
    }
  }
}
```

- [ ] **Step 2: Create `ExportingView.swift`**

```swift
import AmazonOrders
import SwiftUI

/// Progress while the crawl runs. Indeterminate while fetching the order list,
/// determinate while crawling detail pages.
struct ExportingView: View {
  let progress: ExportProgress
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Exporting…").font(.title).bold()
      switch progress {
      case .fetchingOrders(let collected):
        ProgressView("Fetching orders… \(collected)")
      case .crawlingDetails(let done, let total):
        ProgressView(value: Double(done), total: Double(max(total, 1))) {
          Text("Order \(done) of \(total)")
        }
      case .writingFiles:
        ProgressView("Writing CSV files…")
      }
      Button("Cancel", role: .cancel) { cancel() }
    }
    .screenLayout()
  }
}
```

- [ ] **Step 3: Create `FinishedView.swift`**

```swift
import AmazonOrders
import AppKit
import SwiftUI

/// Success: report the count and offer to reveal the files or run again.
struct FinishedView: View {
  let summary: ExportSummary
  let exportAgain: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Done").font(.title).bold()
      Text("Exported \(summary.orderCount) orders to \(summary.outputDir.path).")
        .foregroundStyle(.secondary)
      HStack(spacing: DS.Spacing.standard) {
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelectingURLs([
            summary.outputDir.appendingPathComponent("orders.csv")
          ])
        }
        Button("Export Again", action: exportAgain)
      }
    }
    .screenLayout()
  }
}
```

- [ ] **Step 4: Create `FailedView.swift`**

```swift
import SwiftUI

/// A failed export. Offers re-authentication when the session expired.
struct FailedView: View {
  let message: String
  let canReauth: Bool
  let retry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Spacing.loose) {
      Text("Export failed").font(.title).bold()
      Text(message).foregroundStyle(.secondary)
      Button(canReauth ? "Sign in again" : "Back", action: retry)
        .buttonStyle(PrimaryButtonStyle())
    }
    .screenLayout()
  }
}
```

- [ ] **Step 5: Create `RootView.swift`**

```swift
import AmazonAuth
import SwiftUI

/// Switches the single window's content on the export phase, and presents the
/// login web view as a sheet while authenticating.
struct RootView: View {
  @Bindable var model: ExportModel

  var body: some View {
    content
      .sheet(isPresented: .constant(model.isAuthenticating)) {
        LoginWindowContent(manager: model.authManager) {
          model.didAuthenticate()
        }
      }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .idle:
      IdleView(model: model)
    case .authenticating:
      // The sheet is up; keep the idle screen behind it.
      IdleView(model: model)
    case .exporting(let progress):
      ExportingView(progress: progress) { model.cancel() }
    case .finished(let summary):
      FinishedView(summary: summary) { model.reset() }
    case .failed(let message, let canReauth):
      FailedView(message: message, canReauth: canReauth) {
        if canReauth { model.authenticateAndExport() } else { model.reset() }
      }
    }
  }
}
```

- [ ] **Step 6: Build (additive — old entry still active) + format + commit**

```bash
make build
# Expected: ** BUILD SUCCEEDED **
make format
git add App/Views
git commit -m "App: add SwiftUI views (idle/exporting/finished/failed/root)"
```

---

### Task 6: Flip to the SwiftUI app; delete the CLI

This is the single switch-over commit. After it, double-clicking the app shows the window; there are no subcommands.

**Files:**
- Modify: `App/AmazonOrderExportApp.swift` (replace contents), `App/OrderPageRenderer.swift`, `Packages/AmazonOrders/Sources/AmazonOrders/OrdersURL.swift`, `project.yml`
- Delete: `App/Commands/*.swift`, `App/AppRunLoop.swift`

- [ ] **Step 1: Replace `App/AmazonOrderExportApp.swift`**

```swift
import AmazonAuth
import SwiftUI

/// The app: one window over an `ExportModel`. WKWebView (login + scraping) works
/// because a SwiftUI app already runs an AppKit run loop — no manual shim needed.
@main
struct AmazonOrderExportApp: App {
  @State private var model = ExportModel(
    authManager: AmazonAuthManager(secretStore: KeychainAmazonSecretStore()))

  var body: some Scene {
    Window("Amazon Order Export", id: "main") {
      RootView(model: model)
        .frame(minWidth: DS.screenWidth, minHeight: 420)
    }
    .windowResizability(.contentSize)
  }
}
```

- [ ] **Step 2: Finish the renderer conformance in `App/OrderPageRenderer.swift`**

Make the renderer throw the package's `ExpiredSessionError` instead of its own nested type. The conformance extension and `import AmazonOrders` from Task 4 stay as-is. Concretely:

- Delete the line `struct ExpiredSession: Error {}` (the nested type).
- Change `throw ExpiredSession()` to `throw ExpiredSessionError()`.

- [ ] **Step 3: Remove `page(year:startIndex:)` from `OrdersURL.swift`**

Delete the entire `public static func page(year: Int, startIndex: Int = 0) -> URL { … }` method. Nothing references it after the commands are gone (verified in Step 6).

- [ ] **Step 4: Delete the CLI files**

```bash
git rm App/Commands/AuthenticateCommand.swift App/Commands/CheckCommand.swift \
       App/Commands/SyncCommand.swift App/Commands/DumpOrdersCommand.swift \
       App/AppRunLoop.swift
```

- [ ] **Step 5: Update `project.yml`**

- Remove the `ArgumentParser` entry under `packages:`.
- Remove the `- package: ArgumentParser` / `product: ArgumentParser` lines under the target's `dependencies:` (leave `AmazonAuth` and `AmazonOrders`).
- Change `deploymentTarget: macOS: "14.0"` to `deploymentTarget: macOS: "26.0"`.
- Delete the `scheme: commandLineArguments: "authenticate": true` block (no subcommands).

Resulting `targets.AmazonOrderExport.dependencies` and `packages` should reference only `AmazonAuth` and `AmazonOrders`; signing settings (`CODE_SIGN_STYLE`/`CODE_SIGN_IDENTITY`/`DEVELOPMENT_TEAM`) stay unchanged.

- [ ] **Step 6: Regenerate, build, verify it's a GUI app**

```bash
make build
# Expected: ** BUILD SUCCEEDED **  (a compile error here naming page(year:) or a
# Command type means a CLI reference was missed — grep and remove it.)
grep -rn "ArgumentParser\|AppRunLoop\|SyncCommand\|page(year:" App Packages || echo "clean"
# Expected: clean
"$(make where)" >/dev/null 2>&1 &   # launches the window; close it
```

- [ ] **Step 7: Run the package suites (no regressions)**

Run: `swift test --package-path Packages/AmazonOrders && swift test --package-path Packages/AmazonAuth`
Expected: PASS (17 + 10).

- [ ] **Step 8: Format + commit**

```bash
make format
git add -A
git commit -m "App: replace CLI with SwiftUI @main app; target macOS 26"
```

- [ ] **Step 9: Live-verify (manual checkpoint)**

Launch the app (`open "$(dirname "$(make where)")/../.."` or run the built `.app`). Confirm: window shows; "Choose…" picks a folder; "Sign in & Export" opens the Amazon login sheet; after login it exports and lands on the Done screen; "Reveal in Finder" opens the folder with the three CSVs. (Per the project's validation rhythm — capture any newly-rendered HTML, PII-scrubbed, if a selector needs updating.)

---

### Task 7: CI runner + README

**Files:**
- Modify: `.github/workflows/ci.yml`, `README.md`

- [ ] **Step 1: Bump the CI runner to a Tahoe SDK**

In `.github/workflows/ci.yml`, change `runs-on: macos-15` to `runs-on: macos-26`. (The app's 26.0 deployment target needs the Tahoe SDK / Xcode 26, which `macos-26` provides. `make test` + the unsigned `make build` are otherwise unchanged.)

- [ ] **Step 2: Rewrite the README usage section for the GUI**

Replace the "Build / Use / Outputs" sections of `README.md` with a GUI walkthrough: build with `make build`, run the `.app` (or `open` it), then in the window choose a folder, pick a range, click **Sign in & Export**, sign in to Amazon in the sheet, and find `orders.csv` / `items.csv` / `transactions.csv` in the chosen folder. Keep the "How it works" (render-don't-request, transactions spine, Keychain) and "Status" sections. Remove the `authenticate`/`check`/`sync`/`dump-orders` CLI references.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml README.md
git commit -m "CI: build on macos-26 (Tahoe SDK); README: GUI walkthrough"
```

---

## Final verification

- [ ] `swift test --package-path Packages/AmazonOrders` → 17 pass.
- [ ] `swift test --package-path Packages/AmazonAuth` → 10 pass.
- [ ] `make lint-format` → clean.
- [ ] `make build` → `** BUILD SUCCEEDED **`; launching the app shows the window.
- [ ] `grep -rn "ArgumentParser" App Packages project.yml` → no matches.
- [ ] Manual: full sign-in → export → reveal flow produces the three CSVs.

## Deferred (separate plan)

`.dmg` packaging, Release hardened-runtime signing (drop `get-task-allow`), notarization + stapling, and a tag-triggered release workflow — mirroring Scrapes' `scripts/build-kindleexporter-dmg.sh` and `.github/workflows/kindleexporter-release.yml`. Its own spec + plan.
