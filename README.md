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
process requires one).

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

1. `make run` — or `make build` then `open .build-xcode/Build/Products/Debug/AmazonOrderExport.app`, or just double-click the `.app` in Finder.
2. In the window, click **Choose Folder** and pick where the CSVs should land.
3. Pick a date range: **Last 30 days**, **Past 3 months**, **This year**, or **All time**.
4. Click **Sign in & Export**. An Amazon sign-in sheet appears; log in normally.
5. The app scrapes your orders headlessly and writes the CSVs to the chosen folder.

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
