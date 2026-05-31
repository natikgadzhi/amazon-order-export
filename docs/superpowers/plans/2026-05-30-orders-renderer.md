# P2: Offscreen Orders Renderer + HTML dump

**Goal:** Render a logged-in Amazon orders page (JS-executed) in an offscreen
WKWebView seeded with the stored session, and dump the resulting HTML — so we can
write P3 parsers against *real* markup instead of guessing selectors.

**Why this shape:** order pages are JS-rendered (AZAD #309), so we must let a real
WebView run the page's JS. WKWebView needs the app bundle (WebContent helper), so
`dump-orders`/`sync` are launched as the `.app` (via `open` or Xcode), writing to
files rather than stdout.

## Build (this branch)
- `Packages/AmazonOrders/Sources/AmazonOrders/OrdersURL.swift` — build
  `/your-orders/orders?timeFilter=year-YYYY&startIndex=N`. Unit-tested.
- `Packages/AmazonOrders/Sources/AmazonOrders/OrderPageRenderer.swift` —
  `@MainActor` WKWebView seeded with cookies; `renderedHTML(url:) async -> String`
  loads, waits for JS to settle, returns `document.documentElement.outerHTML`.
- `App/Commands/DumpOrdersCommand.swift` — `dump-orders --year --out [--start-index]`;
  reads Keychain cookies, renders, writes HTML to a file.
- `App/AppRunLoop.swift` — re-add headless (`.prohibited`) run-loop runner.
- Makefile `dump` target (YEAR/OUT vars); `fixtures-raw/` gitignored (raw HTML = PII).

## Human gate (verify tomorrow)
Run `make dump YEAR=2025` (or Xcode with args). Confirm `fixtures-raw/orders-2025.html`
is written and actually contains order rows (not a JS shell / signin page).

## Deferred to P3 (after we see the HTML)
- SwiftSoup parser → `Order`/`OrderItem` models, keyed on order id.
- `items.csv` + `orders.csv` writers (golden-file tested).
- Real render-wait selector (replace the fixed settle delay).
- Year discovery + pagination loop; `sync` command.
