# amazon-order-export

A local macOS tool to export your own Amazon order and transaction history to CSV,
for reconciling against bank transactions and budgeting (e.g. Copilot).

Authenticates via a SwiftUI WebView login (capturing your session), then fetches
your past orders. Exports a per-item CSV and a per-order/shipment totals CSV.

> Status: early design. See `docs/` for the design spec.

## Goals

- `authenticate` — log in via a WebView and persist the session locally (Keychain).
- `check` — verify the stored session is still valid.
- `sync --since <date> --limit <n>` — fetch orders and write CSV exports.

Personal-data export only — your own order history. Not a product scraper.
