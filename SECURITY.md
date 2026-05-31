# Security & Privacy

This tool touches your Amazon account and your purchase history. You shouldn't
have to take the author's word that it keeps them on your machine — the source is
open, the egress is one small file you can read, and the release is verifiable.

## The one file to read

All outbound telemetry is in [`App/Telemetry.swift`](App/Telemetry.swift) — the
only file that imports Sentry (a CI check enforces this). Read it.

## What leaves your Mac

| Destination | When | What | Never |
|---|---|---|---|
| **amazon.com** | While you run an export | Your own Amazon session cookies + your order/transaction pages (you logging into your own account) | — |
| **Sentry** | Only in official releases, only if "Send anonymous crash reports" is ON | App version, OS version, scrubbed crash stack trace, environment | Orders, items, CSVs, cookies, URLs, screenshots, any user/install identifier |
| **Nothing else** | Ever | — | `orders.csv` / `items.csv` / `transactions.csv`, the Keychain session, and cookies never leave your Mac |

## Crash reports: what's in them, and how to turn them off

Crash reports contain crash stack traces only. No analytics, no install id, no
breadcrumbs, no screenshots. File paths are scrubbed, and any event that could
carry Amazon data or a secret is dropped before it's sent.

The Sentry DSN is a build-time secret, so **only official notarized releases can
send anything — local and source builds never report.**

To disable crash reports:

1. Open **Settings** (⌘,).
2. Turn off **"Send anonymous crash reports."**
3. Quit and reopen the app.

## Keychain storage

Your Amazon session is stored app-private using the default Keychain ACL. It is
readable only by this Developer-ID-signed app — no other app and no other process
can read it.

## Verifying the build

These features land with the release pipeline (see
`docs/superpowers/specs/2026-05-31-release-and-provenance-design.md`); this is the
verification story.

1. **Checksum.** Confirm the download matches the published hash:

   ```sh
   shasum -a 256 "Amazon Order Export.dmg"
   ```

   The result must match the SHA-256 in the release notes.

2. **Provenance.** Confirm GitHub Actions built it from this repo at a specific
   commit:

   ```sh
   gh attestation verify "Amazon Order Export.dmg" --repo natikgadzhi/amazon-order-export
   ```

3. **Commit.** The app's About panel shows `Version X (build N) · <shortSHA>`.
   Compare that short SHA to the release tag's commit.

Note: notarized macOS builds aren't byte-reproducible, so we provide verifiable
*provenance* — proof of who built what from which commit — rather than
byte-for-byte reproducibility.
