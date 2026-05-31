# amazon-order-export — working notes for Claude

Local macOS tool to export the user's own Amazon orders + transactions to CSV.
See `docs/superpowers/specs/2026-05-30-amazon-order-export-design.md` for the design,
and `docs/superpowers/plans/` for implementation plans.

## Architecture
- Engine: **offscreen WKWebView** navigates stable Amazon URLs, lets JS render,
  scrapes (Approach A). Direct URLSession against order HTML does NOT work —
  Amazon JS-renders the order pages (AZAD #309).
- Data model: **transactions-spine** — `/cpe/yourpayments/transactions` is the
  bank-matching source (charge date + amount + card last-4 + order id); orders
  and items join on `orderID`.
- macOS SwiftUI `.app` (XcodeGen), single window. `ExportModel` drives the
  phase (idle → authenticating → exporting → finished/failed). Login uses a
  visible WKWebView sheet; scraping uses an offscreen non-persistent WKWebView.

## Build / test
- `make generate`  — regenerate the Xcode project from `project.yml`
- `make test`      — run package unit tests (swift-testing)
- `make format` / `make lint-format` — swift-format (config copied from Scrapes)
- Pre-commit hook auto-formats staged Swift. Run `make install-hooks` once.

## Conventions
- Swift 6 strict concurrency; tests use `import Testing` (`@Suite`/`@Test`/`#expect`), not XCTest.
- Logic lives in `Packages/`; `App/` is a thin SwiftUI shell.
- Isolate Amazon DOM selectors in one file — they rot; they get the most tests.

## Which skill, when
- **swiftui-pro** — any SwiftUI view work (the login window).
- **swift-concurrency-pro** — async/actor/Sendable boundaries (auth manager ↔ networking).
- **swift-testing-pro** — writing `@Test`/`#expect` suites and fixtures.
- **release-macos-spm-packaging** (patrickserrano, install at P6) — `.app` bundling + notarization.
- **XcodeBuildMCP** — building/running the app and driving the WKWebView login.

## Validation rhythm
Every phase ends with a live-verify checkpoint (login, then eyeball CSV output,
then reconcile against a real bank statement). Capture real rendered HTML during
those runs and commit it (PII-scrubbed) as parser test fixtures.
