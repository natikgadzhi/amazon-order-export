# Amazon Order Export — SwiftUI app rework (design)

**Goal:** Turn the CLI prototype into a single-window, mac-only SwiftUI app that
signs in to Amazon, exports the chosen date range to CSV, and reveals the result
in Finder — distributable as a `.dmg` to non-technical users.

**Architecture:** Pure SwiftUI `@main` app (no CLI, no ArgumentParser). All logic
stays in the tested `Packages/`; the app is a thin SwiftUI shell over a new
`ExportService` that orchestrates the existing renderer + parsers + CSV writers.

**Tech stack:** Swift 6 strict concurrency, SwiftUI (macOS 26 "Tahoe"+), WebKit
(WKWebView), SwiftSoup, swift-testing. XcodeGen project, Developer ID signing.

---

## Context & decisions

The prototype is a CLI (`authenticate`/`check`/`sync`/`dump-orders`) that already
*has* to be a GUI app: WKWebView needs an `.app` bundle and an AppKit run loop,
and the Amazon login is inherently interactive (web form + 2FA). So the "CLI" is
a façade over something that already shows UI. We lean in.

Decisions locked during brainstorming:

- **GUI-only.** Drop the CLI subcommands and ArgumentParser entirely. No custom
  `@main` argument branching. (Trade-off: lose `dump-orders` fixture capture —
  refresh selectors later via a throwaway dev affordance or by saving page HTML
  from Safari. Acceptable.)
- **macOS 26 (Tahoe) minimum.** Lets us use current SwiftUI without back-compat.
- **Own, in-repo design layer.** A few tokens + one button style + one layout
  modifier over system fonts/colors — mirroring KindleExporter's tasteful-vanilla
  look. Explicitly **not** a dependency on Scrapes' closed-source `DesignSystem`.
- **Transactions always included.** Every export crawls order-detail pages and
  writes `transactions.csv` (the bank-reconciliation spine), behind a progress
  bar with Cancel.
- **Keychain stays app-private** (decided earlier): the session item is readable
  only by this Developer-ID-signed app; no broad ACL.

Defaults chosen here, easy to change at review:

- **Range options:** Last 30 days · Past 3 months · This year · All time.
- **App display name:** "Amazon Order Export".

## Architecture & lifecycle

SwiftUI `App` lifecycle replaces the ArgumentParser entry point and the
`AppRunLoop` AppKit shim — a GUI app already owns an NSApplication run loop, which
is all WKWebView needs. One window, fixed-ish width (~520pt), not aggressively
resizable.

Two WKWebViews, as today, with different cookie stores on purpose:

- **Login** (`AmazonAuthManager.loginWebView`): default *persistent* store so
  Amazon's "remember this device" reduces repeat 2FA. Shown in a sheet.
- **Scrape** (`OrderPageRenderer`): *non-persistent* store seeded from the
  Keychain session, offscreen. Never shown.

## Components

### `ExportService` (new — in `AmazonOrders`, so it's unit-testable)

Extracts the orchestration currently inlined in `SyncCommand`. Pure of WebKit and
auth: it depends on an injected `OrderPageRendering` protocol, not the concrete
renderer.

```
@MainActor
public protocol OrderPageRendering {
  func renderedHTML(url: URL, readySelector: String) async throws -> String
}

public struct ExpiredSessionError: Error {}  // thrown by the renderer, caught by callers

public enum ExportProgress: Sendable, Equatable {
  case fetchingOrders(collected: Int)          // BFS over the pager
  case crawlingDetails(done: Int, total: Int)  // per-order detail pages
  case writingFiles
}

@MainActor
public final class ExportService {
  public init(renderer: any OrderPageRendering)
  /// Walks `range`, parses, writes orders.csv + items.csv + transactions.csv into
  /// `outputDir`, reporting progress and honoring Task cancellation. Returns a
  /// small summary (order count, file URLs). Throws `ExpiredSessionError` on a
  /// sign-in bounce.
  public func run(range: TimeRange, outputDir: URL,
                  onProgress: @MainActor (ExportProgress) -> Void) async throws -> ExportSummary
}
```

Behavior is the BFS pager + detail crawl that already exists (`collectOrders` /
`collectDetails`), with `print` replaced by `onProgress`, and an explicit
`try Task.checkCancellation()` between page/detail fetches so Cancel is prompt.

### `TimeRange` (new — in `AmazonOrders`) + `OrdersURL` (modified)

```
public enum TimeRange: Sendable, Equatable {
  case last30, months3, year(Int), allTime
}
```

`OrdersURL.page(range:startIndex:)` maps to Amazon's native `timeFilter`:
`last-30`, `months-3`, `year-YYYY`. `.allTime` is handled by `ExportService`
iterating `year(n)` from the current year backward, stopping after a year yields
zero orders. Replaces today's year-only `page(year:startIndex:)`. The exact
`timeFilter` tokens are verified against a live page during implementation
(project validation rhythm).

### `OrderPageRenderer` (modified — stays in App)

Unchanged behavior; add conformance to `OrderPageRendering` via a forwarding
`renderedHTML(url:readySelector:)` that calls the existing
`renderedHTML(url:readySelector:timeout:)` with the default timeout (a defaulted
parameter does not by itself satisfy the protocol requirement). Throw the
package's `ExpiredSessionError` instead of the current nested `ExpiredSession`.
Concrete WebKit lives in the app; the package sees only the protocol.

### `ExportModel` (new — `@MainActor @Observable`, in App)

The view-model coordinating auth + export. Holds:

- `authManager: AmazonAuthManager` (existing).
- `outputDir: URL?` — persisted in `UserDefaults` (non-sandboxed app → a plain
  path, no security-scoped bookmarks).
- `range: TimeRange` (default `.year(<current year>)`, shown as "This year").
- `phase: ExportPhase` — `idle | authenticating | exporting(ExportProgress) |
  finished(ExportSummary) | failed(message:String, canReauth:Bool)`.

Flow: tapping **Authenticate & Export** → if `authManager.state != .authenticated`,
set `.authenticating` and present the login sheet (`authManager.startLogin()`); on
`.authenticated`, dismiss and start export. If already authenticated, export
directly. Export builds `OrderPageRenderer(secrets:)` from `authManager.secrets`
and runs `ExportService`, mapping progress into `phase`. `ExpiredSession` →
`.failed(canReauth: true)`, which offers re-login (`authManager.reset()` then
`startLogin()`).

### Views (new — native SwiftUI, mirroring KindleExporter)

- `RootView` — switches on `model.phase` (cf. `ExporterRootView`).
- `IdleView` — title + subtitle; output-folder row (folder icon + path +
  "Choose…" via `NSOpenPanel`, `canChooseDirectories`); range `Picker`; primary
  button. Button disabled until an output dir is chosen.
- `ExportingView` — phase text ("Fetching orders… 30" / "Order 12 of 95"),
  determinate `ProgressView` for the detail crawl, **Cancel**.
- `FinishedView` — "Exported N orders to <folder>", **Reveal in Finder**
  (`NSWorkspace.activateFileViewer`), **Export Again**.
- `FailedView` — message + Retry; re-auth path when the session expired.
- `LoginSheet` — adapts the existing `LoginWindowContent` (embeds
  `authManager.loginWebView`, fires on `.authenticated`).

### In-repo design layer (new — App/DesignSystem, ~3 files)

- `DSTokens` — spacing + a couple of typography helpers (constants).
- `PrimaryButtonStyle` — the prominent action button (cf.
  `ExporterActionButtonStyle`).
- `.screenLayout()` — max-width + padding modifier (cf. `.exporterScreenLayout`).

No external dependency; system colors/fonts underneath.

## Data flow

```
launch → ExportModel.init → authManager.initSessionFromSecureStorage()
  ├─ authenticated   → IdleView (button: "Export")
  └─ unauthenticated → IdleView (button: "Sign in & Export")

button → [need auth?] → LoginSheet (persistent WKWebView) → .authenticated
       → build OrderPageRenderer(secrets) → ExportService.run(range, dir)
           emits fetchingOrders → crawlingDetails → writingFiles
       → FinishedView (Reveal in Finder)

any step → ExpiredSession → FailedView(canReauth) → reset + LoginSheet
```

## Error handling

- **Expired session** (`/ap/signin` bounce mid-scrape): `.failed(canReauth:true)`;
  user re-authenticates and retries.
- **No / dropped network:** renderer throws; `.failed` with the message; Retry.
- **Whole Foods `/fopo/order-details`** (known gap): detail fields come back blank;
  the order still appears in `orders.csv`. Not fatal — surfaced only as empty
  transaction columns, as today.
- **Cancel:** `Task.checkCancellation()` between fetches → returns to `idle`;
  partial files are written atomically per file, so a cancel leaves whole files,
  not truncated ones.

## Testing

- `ExportService` — unit tests in `AmazonOrdersTests` with a **stub**
  `OrderPageRendering` returning the existing fixture HTML keyed by URL (list page
  vs detail page) and a temp `outputDir`: assert the three CSVs' contents and the
  `ExportProgress` sequence (incl. a cancellation case).
- `TimeRange`/`OrdersURL` — table test of range → `timeFilter` URL.
- Parsers/CSV — already covered (13 tests), unchanged.
- GUI — `#Preview` per view; one light smoke test that the model transitions
  idle → finished against a stub service.

## File structure

**Create**
- `App/AmazonOrderExportApp.swift` — SwiftUI `@main App` (replaces the
  ArgumentParser entry of the same name).
- `App/Model/ExportModel.swift`, `App/Model/ExportPhase.swift`
- `App/Views/RootView.swift`, `IdleView.swift`, `ExportingView.swift`,
  `FinishedView.swift`, `FailedView.swift`, `LoginSheet.swift`
- `App/DesignSystem/DSTokens.swift`, `PrimaryButtonStyle.swift`, `ScreenLayout.swift`
- `Packages/AmazonOrders/Sources/AmazonOrders/TimeRange.swift`
- `Packages/AmazonOrders/Sources/AmazonOrders/ExportService.swift` (+
  `OrderPageRendering`, `ExportProgress`, `ExportSummary`)
- `Packages/AmazonOrders/Tests/AmazonOrdersTests/ExportServiceTests.swift`,
  `TimeRangeTests.swift`

**Modify**
- `App/OrderPageRenderer.swift` — conform to `OrderPageRendering`.
- `App/LoginWindow.swift` — fold into `LoginSheet` (or keep as the embedded view).
- `Packages/AmazonOrders/Sources/AmazonOrders/OrdersURL.swift` — range-based.
- `project.yml` — drop the ArgumentParser package dep; `deploymentTarget.macOS:
  "26.0"`; keep Developer ID signing.
- `Packages/*/Package.swift` — platforms `.macOS(.v26)`.
- `.github/workflows/ci.yml` — runner that has the Tahoe SDK (macos-26 / Xcode 26).
- `README.md` — replace CLI usage with the GUI walkthrough.

**Delete**
- `App/AmazonOrderExportApp.swift` (old ArgumentParser `@main` — superseded by the
  new SwiftUI app of the same name)
- `App/Commands/AuthenticateCommand.swift`, `CheckCommand.swift`,
  `SyncCommand.swift`, `DumpOrdersCommand.swift`
- `App/AppRunLoop.swift`

## Out of scope (separate follow-up phase)

- **Distribution:** `.dmg` packaging, Release signing with `--options runtime`
  (dropping `get-task-allow`, enabling hardened runtime), notarization + stapling,
  and a tag-triggered release GitHub Actions workflow — all mirroring Scrapes'
  `scripts/build-kindleexporter-dmg.sh` and `kindleexporter-release.yml`. Its own
  spec.
- iOS, telemetry/Sentry, export history, in-app CSV preview.
