# Design: amazon-order-export

**Date:** 2026-05-30
**Status:** Approved — ready for implementation planning
**Author:** natikgadzhi (with Claude)

## Goal

A local macOS tool to export the signed-in user's **own** Amazon order and
transaction history to CSV, for reconciling against bank transactions and
budgeting (Copilot sets categories from the line items). Personal-data export
only — not a product/listing/price scraper.

CLI surface:
- `authenticate` — log in via a WebView, persist the session locally (Keychain).
- `check` — verify the stored session is still valid.
- `sync --since <date> --limit <n> --scope <...> --out <dir>` — fetch orders +
  transactions and write CSV exports.

## Research findings that shaped this design

Five parallel investigations (2026-05-30) produced the decisions below. Key
evidence:

- **Amazon order pages are JS-rendered as of early 2025.** A raw `URLSession`
  GET returns a JS shell; the order list and the tokens needed to build the
  next request (`B2BGroupKey`) only materialize after JavaScript runs. Source:
  AZAD issue [#309](https://github.com/philipmulcahy/azad/issues/309). AZAD was
  forced to rewrite from fetch-and-parse (Approach C) to render-then-scrape
  (Approach A).
- **Every OSS tool that works in 2026 runs in a live browser context**
  (extension content-script, or Playwright/Selenium). The only pure
  direct-HTTP+cookie tool (Chrisso/Amazon-Scraper) is unmaintained since 2017.
- **The failure mode is rendering, not anti-bot/rate-limiting.** Personal,
  low-volume order export is unlikely to hit CAPTCHA walls the way price
  scrapers do — but that is irrelevant, because the data simply isn't in the
  initial HTML anymore.
- **`read.amazon.com` (KindleAPI) is different**: it exposes real JSON APIs, so
  the existing URLSession pattern works there. `amazon.com` orders has no clean
  JSON API and now requires rendering. Different surface, different rules.
- **Transactions are the best bank-reconciliation source.** The orders pages
  give order grand totals but **no card last-4 and no charge date**. The page
  `/cpe/yourpayments/transactions` is the only surface with the full tuple:
  charge date + amount charged + card last-4 + linked order ID.

### Architecture decision

- **Engine: Approach A — offscreen WKWebView.** Navigate Amazon's stable order
  and transaction URLs inside an invisible WKWebView, let Amazon's JS render,
  then extract via fetch-interception (reusing the Kindle `FetchMonitorJS` /
  `jsBridge` trick) with a SwiftSoup DOM-scrape fallback. This keeps the URL
  determinism the user wanted from Approach C while satisfying the rendering
  requirement that Approach A imposes.
- **Data model: transactions-spine.** Transactions drive bank matching; orders
  and items are joined onto them by `orderID`.

## Runtime shape

A macOS **`.app` bundle** built from an Xcode project, invoked as a **CLI** via
`swift-argument-parser`. WKWebView needs a live AppKit run loop even offscreen,
so every subcommand brings up `NSApplication`, with activation policy per
command:

- `authenticate` → `.regular` (Dock icon + SwiftUI window) for login + 2FA.
- `check` / `sync` → `.prohibited` (no Dock icon, no window) → invisible
  WKWebView. Feels like a CLI; is a headless browser underneath.

## Package layout (mirrors the Scrapes hybrid convention)

```
AmazonOrderExport.xcodeproj          # macOS app target (@main, arg-parser CLI)
Packages/
  AmazonAuth/        # WKWebView login, cookie capture, Keychain secret store
  AmazonOrders/      # renderer + sources + parsers + models (the engine)
Makefile  .swift-format  .githooks/pre-commit  skills-lock.json  CLAUDE.md
docs/superpowers/specs/
```

Logic lives in SPM packages (host-testable via `swift test`); the app target is
a thin CLI shell. Mirrors the KindleAPI / KindleAuthentication split.

## Components

### AmazonAuth (adapts KindleAuthenticationManager patterns)

- `AmazonAuthManager` (`@MainActor @Observable`): owns `loginWebView`, captures
  cookies once the authenticated set is present (`at-main`, `sess-at-main`,
  `session-id`, `ubid-main`, `x-main`), persists `AmazonSessionSecrets` to
  Keychain via `AmazonSecretStore` (NSSecureCoding cookie archiving, as in
  KindleAuthenticationSecretStore). `InMemoryAmazonSecretStore` for tests.
- Expiry detection: redirect to `/ap/signin` or missing auth cookies (the
  KindleAPI `dataWithHTTPValidation` 401/403 + signin-redirect approach).

### AmazonOrders (the engine)

- `OrderPageRenderer` (`@MainActor`): offscreen WKWebView seeded with session
  cookies. `render(url:) async throws -> RenderedPage` loads the URL, **waits
  for JS to populate** (poll `evaluateJavaScript` for a known selector /
  network-settle — not a fixed sleep), returns final `outerHTML` plus any JSON
  captured by the `FetchMonitor` / `jsBridge` user script (reused from Kindle
  auth).
- `OrderSource` protocol; implementations drive stable URLs through the
  renderer:
  - `PhysicalOrdersSource` — `/your-orders/orders?timeFilter=year-YYYY&startIndex=N`
    (page size 10), discovers available years from the page's year selector.
  - `DigitalOrdersSource` — `&orderFilter=digital` / legacy digital path.
  - `TransactionsSource` — `/cpe/yourpayments/transactions`, paginated by
    submitting the `ppw-widgetState` form inside the webview (click "Next Page"
    via JS, capture each rendered page). Extracts charge date, amount, payment
    method + last-4, linked order ID.
- Models: `Transaction`, `Order`, `OrderItem` (`Sendable` / `Codable`), joined
  on `orderID`.
- **All SwiftSoup selectors isolated in one file** — they rot when Amazon
  changes markup, so they get a tight module boundary and the most test
  coverage.

### App / CLI target

- `swift-argument-parser` subcommands: `authenticate`, `check`, `sync`.
- `authenticate`: `.regular`, SwiftUI window hosting the login WKWebView; on
  success persist secrets and exit.
- `check`: read secrets, offscreen-render an account page, report
  authed/expired via exit code.
- `sync`: `.prohibited`, offscreen renderer, run sources, write CSVs.

## Data flow & outputs

`sync` → load Keychain cookies → seed offscreen webview cookie store → run each
source → join on `orderID` → write three CSVs:

- `transactions.csv` — the bank-matching spine: charge date, amount, card
  last-4, order ID.
- `orders.csv` — order-level totals.
- `items.csv` — per-item rows (description, ASIN, qty, item price, order ID)
  for Copilot category hints.

Optionally a flattened `reconciliation.csv` view.

`sync` flags: `--since <date>`, `--limit <n>`,
`--scope physical,digital,transactions` (default all), `--out <dir>`.

**Backfill / fallback:** an importer for Amazon's official
`Retail.OrderHistory.1.csv` (Privacy Central "Request My Data"), for deep
history when live scraping is incomplete or breaks. Columns documented in the
endpoints research (Order ID, Order Date, Total Owed, Payment Instrument Type
[card brand + last-4], ASIN, Quantity, Ship Date, etc.); order-level only (no
true charge date).

## Error handling (built for DOM rot)

- Session expired → fail fast with "run `authenticate` again" + nonzero exit
  (no silent 2FA loop in headless mode).
- Render timeout / selector miss → retry once, then **dump rendered HTML to a
  debug file** and report which source/year failed, so updating selectors is a
  quick job, not a mystery.
- Robot/captcha interstitial → in `authenticate` the user solves it
  interactively; in `sync` we stop with guidance.
- Per-source / per-year isolation: one failure doesn't sink the whole run.
- Polite 1–3s delays between navigations.

## Testing & validation — repro at every step

| Layer | How | Runs via |
|---|---|---|
| URL builders | pure-function tests (param shapes, pagination) | `swift test` |
| HTML parsers | SwiftSoup against committed HTML fixtures (real pages captured on first login, PII-scrubbed) — the DOM-change tripwire | `swift test` |
| CSV writers | golden-file tests | `swift test` |
| Auth store / expiry | `InMemoryAmazonSecretStore` round-trips, redirect classification | `swift test` |
| Join logic | transactions↔orders by orderID | `swift test` |
| WebKit pipeline | load fixture HTML into offscreen WKWebView, assert FetchMonitor + extraction end-to-end | `xcodebuild test` (needs app run loop) |

**Test framework:** swift-testing (`import Testing`, `@Suite`/`@Test`/`#expect`),
matching Scrapes. Not XCTest.

**Live-verify checkpoints (stop and ask the user to run):**
1. After `AmazonAuth`: run `authenticate`, log in → `check` reports
   authenticated.
2. After `PhysicalOrdersSource`: `sync --scope physical --limit 5` → eyeball
   `items.csv`; snapshot the rendered HTML as a test fixture.
3. After `TransactionsSource`: `sync --scope transactions --since <date>` →
   spot-check 3 rows against the user's bank statement.
4. Final: full `sync` → reconcile a month + feed Copilot.

## Tooling & skills

Mirror the Scrapes convention (`npx skills add` → `skills-lock.json` →
`.agents/skills/`):

- **swift-concurrency-pro**, **swiftui-pro**, **swift-testing-pro** (twostraws)
  — Tier 1.
- **patrickserrano `ios-swift-skills`** → `release-macos-spm-packaging` for
  `.app` bundling + Developer ID notarization at open-source time.
- **XcodeBuildMCP** (already trusted in Scrapes) for build/run/driving the
  login flow.

Plus the Scrapes `.swift-format` config, `.githooks/pre-commit` (auto-format
staged Swift), `Makefile` (`contrib` / `format` / `lint-format` / `test`),
Swift 6.2 strict concurrency. `CLAUDE.md` documents which skill to use when.

## Phasing

- **P0** — scaffold: Xcode project + packages + Makefile + `.swift-format` +
  githooks + skills install + `CLAUDE.md`.
- **P1** — `AmazonAuth` + `authenticate` / `check`. Live-verify login.
- **P2** — `OrderPageRenderer` (offscreen render + FetchMonitor + render-wait).
  Fixture-based render test.
- **P3** — `PhysicalOrdersSource` + models + items/orders CSV. Live-verify,
  capture fixtures.
- **P4** — `TransactionsSource` + join + transactions CSV. Live-verify vs bank.
- **P5** — `DigitalOrdersSource` + official-export (`Retail.OrderHistory.1.csv`)
  importer for backfill.
- **P6** — polish, README, open-source prep (notarization).

## Reference: source-of-truth URLs (US amazon.com)

- Physical orders: `/your-orders/orders?timeFilter=year-YYYY&startIndex=N`
  (page size 10). `timeFilter` accepts `last30`, `months-3`, `year-YYYY`,
  `open`.
- Digital orders: append `&orderFilter=digital`, or legacy
  `/gp/legacy/order-history?...&digitalOrders=1`.
- Order details (per-item backfill):
  `/gp/your-account/order-details?orderID=...`.
- Transactions: `/cpe/yourpayments/transactions` (POST pagination via
  `ppw-widgetState` hidden form field).
- Required auth cookies: `session-id`, `ubid-main`, `x-main`, `at-main`,
  `sess-at-main`.
- Sign-in redirect (expiry signal): `/ap/signin`.
- Official export entry: `/gp/privacycentral/dsar/preview.html`.

## Out of scope

- Non-US marketplaces (`.ca`, `.de`, etc.) — single marketplace `amazon.com`
  for v1; URL templates are isolated so this can be added later.
- Product/catalog/price scraping.
- Automatic bank import — we emit CSVs; matching + Copilot categorization is the
  user's downstream workflow.
