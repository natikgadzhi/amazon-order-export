# amazon-order-export

A local macOS tool to export **your own** Amazon order and transaction history to
CSV, for reconciling against bank transactions and budgeting (e.g. Copilot).

You log in once through a real Amazon web view; the tool reuses that session to
render your order pages headlessly and scrape them into CSVs. Personal-data export
only — your own order history, on your own machine. Not a product scraper.

## How it works

- **Render, don't request.** Amazon JS-renders the order pages, so a plain HTTP
  fetch returns empty shells. The tool drives an offscreen `WKWebView` against
  stable Amazon URLs, lets the page render, then scrapes the DOM.
- **Transactions spine.** The order-details page yields the grand total, card
  last-4, and a `transactionTag` — the keys that let an order be matched to a
  bank-statement line. `orders.csv`/`items.csv` join to it on `order_id`.
- **Session in the Keychain.** Login cookies are bearer credentials, so they live
  in the macOS Keychain, not a file. See `docs/` for the design and security notes.

The app is a standard windowed macOS app (`.app` bundle — WKWebView's helper
process requires one). It's built with SwiftUI; the scraping + CSV logic lives in
`Packages/` (unit-tested against PII-scrubbed HTML fixtures) and `App/` is a thin
SwiftUI shell over it.

## Build

Requires Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and [swift-format](https://github.com/swiftlang/swift-format).

```sh
make build        # xcodegen generate + xcodebuild into .build-xcode/
make test         # run the package unit tests
make format       # swift-format in place
make clean        # remove build artifacts
```

## Use

1. **`make run`** — builds and launches the app. (Or `make build`, then open
   `.build-xcode/Build/Products/Debug/AmazonOrderExport.app`, or double-click it in Finder.)
2. The destination defaults to **`~/Desktop/amazon-orders/`** (created automatically on
   first export). Click **Choose…** to pick a different folder — the panel has a
   **New Folder** button.
3. Pick a date range: **Last 30 days**, **Past 3 months**, **This year**, or **All time**.
4. Click **Sign in & Export**. An Amazon sign-in sheet appears; sign in normally
   (or **Cancel** to back out). After login it exports automatically.
5. The app scrapes your orders headlessly, writes the three CSVs, and offers
   **Reveal in Finder**.

Standard macOS shortcuts work (⌘Q quit, ⌘W close, ⌘M minimize, ⌘H hide).

### Outputs

All three files are always written:

| File | Grain | Key columns |
|------|-------|-------------|
| `orders.csv` | one row per order | order_id, date_placed, total, recipient, item_count, … |
| `items.csv` | one row per line item | order_id, asin, quantity, title |
| `transactions.csv` | one row per order | order_id, date_placed, grand_total, card_last4, transaction_tag |

## Status

Working prototype. The Amazon DOM rots, so all selectors are isolated in one file
(`OrderSelectors.swift`) and get the most test coverage, against PII-scrubbed HTML
fixtures. Known gap: Whole Foods `/fopo/order-details` pages use a different layout,
so their detail fields come back blank (the order still appears in `orders.csv`).
