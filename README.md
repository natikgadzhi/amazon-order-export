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

The app is a macOS `.app` bundle (WKWebView's helper process needs one) driven as
a CLI: `AmazonOrderExport.app/Contents/MacOS/AmazonOrderExport <subcommand>`.

## Build

Requires Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and [swift-format](https://github.com/swiftlang/swift-format).

```sh
make build        # xcodegen generate + xcodebuild into .build-xcode/
make where        # print the built binary's path
make test         # run the package unit tests
make format       # swift-format in place
make clean        # remove build artifacts
```

The binary lands at
`.build-xcode/Build/Products/Debug/AmazonOrderExport.app/Contents/MacOS/AmazonOrderExport`
(`make where` prints it). Run it directly, or use the `make` shortcuts below.

## Use

```sh
make authenticate                 # opens the Amazon login window; persists the session
make check                        # verify the stored session is still valid
make sync YEAR=2026               # write orders.csv + items.csv for the year

# Or drive the binary directly for the full interface:
"$(make where)" sync --year 2026 --with-details   # also writes transactions.csv (slower)
"$(make where)" sync --year 2026 --limit 5        # stop after N orders — quick first run
"$(make where)" dump-orders --year 2026 --out page.html   # capture raw HTML (fixtures)
```

### Outputs

| File | Grain | Columns |
|------|-------|---------|
| `orders.csv` | one row per order | order_id, date_placed, total, recipient, item_count, … |
| `items.csv` | one row per line item | order_id, asin, quantity, title |
| `transactions.csv` | one row per order (with `--with-details`) | order_id, date_placed, grand_total, card_last4, transactions_tag |

## Status

Working prototype. The Amazon DOM rots, so all selectors are isolated in one file
(`OrderSelectors.swift`) and get the most test coverage, against PII-scrubbed HTML
fixtures. Known gap: Whole Foods `/fopo/order-details` pages use a different layout,
so their detail fields come back blank (the order still appears in `orders.csv`).
