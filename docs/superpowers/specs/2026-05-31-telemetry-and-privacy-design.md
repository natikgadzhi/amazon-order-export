# Telemetry & privacy — crash-only, opt-out, single-chokepoint (design)

**Goal:** Add the *minimum* outbound telemetry an open-source maintainer needs —
crash and explicit-error reports, nothing else — behind one auditable file, an
opt-out toggle, and a privacy doc a reviewer can read in two minutes to know
exactly what can ever leave the machine. This app holds Amazon session cookies
and order/transaction data; leakage prevention is the whole point.

**Architecture:** A single `App/Telemetry.swift` enum owns Sentry init and the
only `report(_:)` wrapper; *nothing else in the app touches `SentrySDK`
directly.* A persisted opt-out toggle gates whether Sentry is initialized at
all. A new SwiftUI `Settings` scene (Cmd-,) hosts the toggle; a one-time
first-run notice tells the user it's on and how to turn it off. `SECURITY.md` +
a README "Privacy & Security" section, anchored on a "What leaves your Mac"
table, document the boundary.

**Tech stack:** Swift 6 strict concurrency, SwiftUI (macOS 26 "Tahoe"+),
`sentry-cocoa` (SPM), swift-testing. XcodeGen project; `SENTRY_DSN` injected into
`Info.plist` via an `INFOPLIST_KEY_*` build setting.

---

## Context & decisions

The maintainer ships this as a `.dmg` to non-technical users and needs to learn
about crashes without asking the user to reproduce. The sibling app **Scrapes**
(`~/src/natikgadzhi/Scrapes/Scrapes/App/ScrapesApp.swift`) already wires Sentry:
it reads `SENTRY_DSN` from `Info.plist`, calls `SentrySDK.start { … }`, sets
`enableAutoSessionTracking = false`, `enableSpotlight = false`, and
`tracesSampleRate = 0.2` in prod. We **mirror that shape** (DSN-from-Info.plist,
one explicit `start` call) and **tighten far beyond it**: Scrapes still allows
network/auto breadcrumbs, performance traces, and has *no* `beforeSend` scrub and
*no* opt-out. This app is far more sensitive, so we lock down every channel that
could carry a cookie, a URL, or order data.

Decisions locked during brainstorming — **design to these; do not reopen**:

- **Crash & explicit-error reports ONLY.** No usage/analytics events, no screen
  views, no timing. The only things we ever send are an unhandled crash and a
  call we deliberately make to `Telemetry.report(_:)`.
- **No anonymous install ID.** Crashes carry no user id, no install id, no device
  id we set. We never call `SentrySDK.setUser`. `sendDefaultPii = false` keeps
  the SDK from attaching its own.
- **Opt-out, default ON.** One persisted `Bool` in `UserDefaults`
  (`telemetry.crashReportsEnabled`, absent ⇒ `true`). If `false`, **Sentry is
  never initialized** — not started-then-muted, but `SentrySDK.start` is never
  called. This is the strongest possible guarantee: when off, the SDK does
  nothing because it isn't running.
- **One chokepoint.** `App/Telemetry.swift`. It is the *only* file that imports
  `Sentry`. A grep for `import Sentry` or `SentrySDK` returning exactly one file
  is a reviewable invariant (enforced by a test, see Testing).
- **DSN in the open-source build is intended.** A Sentry DSN is an ingest key,
  not a secret — it lets anyone *send* events to the project, not read them. We
  commit the wiring in the open and say so in `SECURITY.md`. Abuse is rate-limit
  / spam, not a data-leak vector.

This spec **owns**: telemetry, the Settings scene, the first-run notice,
`SECURITY.md`, and the README privacy section.

**Boundary with the release/provenance spec**
(`2026-05-31-release-and-provenance-design.md`, written in parallel): *that* spec
owns the release workflow, SLSA/provenance, SHA-256 publishing, `gh attestation
verify`, and the commit-SHA-in-About display. This spec **references** those as
the "Verifying the build" story but does **not** design them. Where the two
meet — `SECURITY.md`'s verification section, the About panel — each spec links
the other; neither duplicates.

## Architecture & lifecycle

```
AmazonOrderExportApp.init
  └─ Telemetry.start()                 // no-op if toggle is OFF
        ├─ read crashReportsEnabled (UserDefaults)  → false ⇒ return, SDK never starts
        ├─ read SENTRY_DSN (Info.plist)             → missing/empty ⇒ return
        └─ SentrySDK.start { options in <locked-down config> }

…anywhere a caught error is worth knowing about…
  └─ Telemetry.report(error)           // no-op if SDK never started

Settings scene (Cmd-,)
  └─ Toggle "Send anonymous crash reports"  ⇄  crashReportsEnabled
        (flipping it takes effect next launch; see Error handling)

First launch only
  └─ one-time notice: "Crash reports are on — no orders or cookies ever
     leave your Mac. Turn off in Settings."  + link to privacy doc
```

`Telemetry.start()` is called once, first thing in the app's `init()` (before
auth/session recovery), mirroring Scrapes' "init Sentry before anything else so a
crash during startup still has a trace" ordering.

## Components

### `App/Telemetry.swift` (new — the chokepoint, the *only* `import Sentry`)

A `@MainActor enum` (namespace, no instances). Public surface is exactly two
methods plus the toggle key.

```
import Sentry  // <-- the one and only place this import appears

@MainActor
enum Telemetry {
  /// UserDefaults key. Absent ⇒ ON (opt-out default).
  static let enabledKey = "telemetry.crashReportsEnabled"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  /// Called once at launch. No-op (SDK never starts) when disabled or when no
  /// DSN is baked into the build.
  static func start() {
    guard isEnabled else { return }
    guard let dsn = Bundle.main.infoDictionary?["SENTRY_DSN"] as? String,
          !dsn.isEmpty else { return }
    SentrySDK.start { options in configure(options, dsn: dsn) }
  }

  /// The ONLY way the rest of the app sends anything. No-op if start() didn't run.
  static func report(_ error: Error) {
    guard isEnabled else { return }
    SentrySDK.capture(error: error)
  }

  // configure(_:dsn:), scrub(_:) below
}
```

There is intentionally **no** `capture(message:)`, no breadcrumb API, no
`setUser`, no analytics method. If a caller wants something sent, it goes through
`report(_:)` and is therefore an `Error` that flows through the scrub.

### Sentry configuration (`configure(_:dsn:)`) — the lockdown

Every option below is in scope; the implementer **verifies each name against the
installed `sentry-cocoa` version** (the SDK renames options between majors) and,
if a name has changed, applies the equivalent that achieves the same *off* state.
Default posture: **off**. We only turn on crash capture.

```
options.dsn = dsn

#if DEBUG
  options.environment = "development"
#else
  options.environment = "production"
#endif

// --- Performance: fully off (perf spans capture URLs / request data) ---
options.tracesSampleRate = 0

// --- Auto-instrumentation: off (it's the main accidental-data channel) ---
options.enableSwizzling = false               // no method swizzling at all
options.enableAutoBreadcrumbTracking = false  // no UI/system breadcrumbs
options.enableNetworkBreadcrumbs = false      // no request breadcrumbs
options.enableNetworkTracking = false         // no auto HTTP spans
options.enableCaptureFailedRequests = false   // never capture HTTP failures (URLs/bodies)
options.enableAutoSessionTracking = false     // no session pings
options.enableSpotlight = false               // no local Spotlight sidecar

// --- Attachments: off (could carry the login WebView / order screen) ---
options.attachScreenshot = false
options.attachViewHierarchy = false

// --- PII: off (no IP, no auto user, no device identifiers we don't set) ---
options.sendDefaultPii = false

// --- Breadcrumbs: drop ALL of them, belt-and-suspenders over the toggles above ---
options.beforeBreadcrumb = { _ in nil }

// --- The scrub: last line of defense on every event we do send ---
options.beforeSend = { event in Telemetry.scrub(event) }
```

Rationale notes carried into code comments: `tracesSampleRate = 0` because perf
spans record URLs (would include `amazon.com` order URLs); `enableSwizzling =
false` disables the mechanism behind most auto-breadcrumbs and network capture in
one move; `beforeBreadcrumb = { _ in nil }` guarantees an empty breadcrumb trail
even if some future SDK default re-enables a source.

### The scrub (`scrub(_:)`) — `beforeSend`

Runs on **every** outgoing event (the only events being crashes and
`report(_:)` errors). Philosophy: **redact aggressively in *value-bearing*
fields; never let our own symbol names trigger a drop.**

**Critical distinction — symbol metadata vs. captured values.** A crash's stack
frames are *symbol names*: `function`/`module`/`package`/`filename` like
`AmazonOrderExport.ExportModel.startExport` or the `AmazonSessionSecrets` type.
These carry **no data** and must NOT be treated as secrets. Our module is
literally named `AmazonOrderExport`, so a naive "drop any event whose strings
contain `amazon`/`secret`/`session`/`token`" would drop *every crash this app
produces* — zero reports, feature defeated. The scrub therefore targets
**value-bearing fields**, not symbol names. (By default `sentry-cocoa` does not
capture local-variable values into frames, so the real data surfaces are the
exception *message*, file *paths*, and request/URL data — all handled below.)

The scrub performs, in order:

1. **Strip request/URL/span data.** Set `event.request = nil` (no URL, headers,
   query, body). Clear any transaction/span data (`tracesSampleRate = 0` means
   there should be none, but we null it defensively).
2. **Redact home-dir / username paths in every string field** (message,
   exception value, frame `filename`): `/Users/<name>/…` → `/Users/<redacted>/…`
   (and `~`-expanded forms). The username is itself PII / an account hint.
3. **Sanitize value-bearing text** — the exception *message/value* and any
   extra/context strings, **but not** `frame.function`/`module`/`package` (safe
   symbol names): replace any URL with `scheme://host` only (or `<url
   redacted>`), and replace any token/cookie-shaped blob (long high-entropy
   base64/hex, `Bearer …`, `x-amz-…` values) with `<redacted>`.
4. **Fail-closed backstop.** If, after sanitizing, a *value-bearing* field still
   matches a recognizable secret pattern (an `amazon.com` URL host, a
   token-shaped blob), **return `nil`** (drop the whole event). This keys on
   value patterns in messages/values, **never on symbol names**, so ordinary
   crashes survive while a genuine leak is dropped.

The scrub is a **pure function over the event** so it is unit-testable without
the network or the SDK runtime (see Testing). The value-pattern lists (URL host,
token/cookie shapes) live as constants at the top of `Telemetry.swift` next to
the scrub, with a comment that they match *values*, not type/symbol names.

### `Settings` scene + `App/Views/SettingsView.swift` (new)

The app currently has **no** Settings scene — this design adds one. In
`AmazonOrderExportApp.body`, add a `Settings { SettingsView() }` scene, which
gives the standard macOS **Cmd-,** menu item for free.

```
Settings { SettingsView() }
```

`SettingsView` (small, native):

- `@AppStorage(Telemetry.enabledKey) var crashReportsEnabled = true` — drives a
  `Toggle("Send anonymous crash reports", isOn:)`.
- Caption under the toggle: "Crash traces only — your orders and Amazon cookies
  never leave your Mac. See the privacy notes." with a `Link` to the published
  `SECURITY.md` (and/or a "Reveal SECURITY.md" affordance — content link only,
  no new doc).
- A short line noting the change takes effect on next launch (see Error
  handling for why we don't hot-stop the SDK).

Uses the existing `App/DesignSystem` tokens; no new design primitives.

### First-run notice (`App/Views/CrashReportingNotice.swift` — new, small)

Shown **once**, only when telemetry is at its default-ON state and the user
hasn't seen the notice. Persistence:

- `@AppStorage("telemetry.firstRunNoticeSeen") var seen = false`.

Presentation: a **dismissible banner** at the top of `RootView`'s idle screen
(preferred over a modal alert — it doesn't block first use, matches the app's
calm tone). Copy:

> **Crash reports are on.** No orders or cookies ever leave your Mac. Turn off
> in Settings. — *Privacy & Security* (link)

Dismiss ("Got it") sets `seen = true`. The link opens `SECURITY.md`
(published URL) and/or opens Settings. If the user has already turned telemetry
**off** before first dismissal (edge case), the banner is suppressed — there's
nothing to disclose.

(Alternative considered: a one-time `.alert`. Rejected as more intrusive for a
purely informational, opt-out-already disclosure. The banner is the design;
the alert is the fallback if the banner crowds the idle layout.)

### `report(_:)` call sites (modify existing error paths)

`Telemetry.report(_:)` is wired into the *already-existing* failure points from
the GUI spec — it adds a side-channel, it does not change control flow:

- `ExportModel` failure path (`.failed(message:…)`): before/at the point we set
  `.failed`, call `Telemetry.report(error)` for **unexpected** errors only.
- **Explicitly excluded** from reporting (these are normal, not bugs, and may
  carry context): `ExpiredSessionError` (a sign-in bounce), user cancellation
  (`CancellationError`), and the known Whole Foods blank-detail gap. These are
  expected outcomes; sending them is noise *and* risks attaching scraped context.

The decision rule lives in `ExportModel` as a small `shouldReport(_:) -> Bool`
helper so "what we report" is itself readable in one place.

## Data flow — what can leave the machine

```
EXPORT (always, when you run it):
  app ⇄ amazon.com    your own session cookies + order/transaction HTML
                      (this is the product; it never goes anywhere else)

CRASH REPORTING (only if toggle ON):
  app → Sentry        app version, OS version, scrubbed stack trace,
                      environment ("production"). NO orders, NO cookies,
                      NO URLs, NO breadcrumbs, NO screenshots, NO user/install id.

EVERYTHING ELSE:
  orders.csv, items.csv, transactions.csv, the Keychain session, cookies
                      → stay on disk. Never transmitted.
```

## Error handling

- **Toggle flipped at runtime.** `start()` runs once at launch. Turning the
  toggle **off** mid-session does not stop an already-running SDK; turning it
  **on** does not start one. We surface "takes effect on next launch" in
  Settings and accept this. Rationale: a hot `SentrySDK.close()`/restart path is
  more code and more failure modes than the one-line restart guidance buys; the
  default-ON, opt-out posture means the risky direction (off→on) is the *less*
  privacy-sensitive one. (If a reviewer wants instant-off, the minimal addition
  is calling `SentrySDK.close()` from the toggle's off-transition — noted, not
  designed in.)
- **Missing DSN.** `start()` returns silently (open-source checkouts and CI
  builds have no DSN). No crash, no warning dialog — just no telemetry. Mirrors
  Scrapes' guard.
- **Scrub throws / unexpected event shape.** `beforeSend` must never crash the
  app; if the scrub can't confidently process an event, it returns `nil` (drop).
  Fail closed.
- **Sentry itself errors / offline.** The SDK queues/drops internally; we never
  block export on it and never show telemetry errors to the user.

## Testing

`Telemetry.scrub` is the high-value, rot-prone surface (like the DOM selectors —
it gets the most tests). Pull the scrub logic into a pure, SDK-light helper so
tests don't need a live `SentrySDK`.

- **Scrub table tests** (`AppTests` or a small `TelemetryTests`, swift-testing
  `@Test`/`#expect`): for representative event shapes, assert —
  - an exception **message/value** containing an `amazon.com` URL ⇒ URL redacted;
    if a raw token/cookie value remains ⇒ event dropped (`nil`).
  - a token/cookie-shaped blob or `Bearer …`/`x-amz-…` value in the **message** ⇒
    redacted (or dropped by the backstop).
  - **The critical false-positive guard:** a crash whose **frames** are our own
    symbols (`AmazonOrderExport.ExportModel…`, the `AmazonSessionSecrets` type)
    with a benign message ⇒ **survives** (NOT dropped). This is the test that
    proves the scrub doesn't nuke every real crash.
  - `/Users/natik/…` in a frame `filename` or message ⇒ rewritten to
    `/Users/<redacted>/…`.
  - `event.request` ⇒ `nil` after scrub.
  - a benign framework-only crash ⇒ survives, with no PII.
- **Opt-out invariant:** with `crashReportsEnabled = false`, `start()` does not
  call into the SDK (assert via an injected seam / by asserting `SentrySDK`
  isn't enabled). `report(_:)` is a no-op when disabled.
- **Chokepoint invariant (the reviewer's promise, as a test):** a test that
  scans the `App/` sources and asserts `import Sentry` / `SentrySDK` appears in
  **exactly one** file (`Telemetry.swift`). This makes "one file owns all
  egress" a CI-enforced fact, not a convention.
- **Default-ON:** absent key ⇒ `isEnabled == true`.
- First-run notice: `#Preview`; one smoke test that dismiss flips
  `firstRunNoticeSeen`.

## File structure

**Create**
- `App/Telemetry.swift` — the chokepoint: `start()`, `report(_:)`,
  `configure(_:dsn:)`, `scrub(_:)`, marker constants. Only `import Sentry`.
- `App/Views/SettingsView.swift` — the Cmd-, toggle + privacy link.
- `App/Views/CrashReportingNotice.swift` — one-time dismissible banner.
- `App/AppTests/TelemetryScrubTests.swift` (+ the chokepoint-grep test) —
  swift-testing.
- `SECURITY.md` (repo root) — see below.

**Modify**
- `App/AmazonOrderExportApp.swift` — call `Telemetry.start()` first in `init()`;
  add the `Settings { SettingsView() }` scene.
- `App/Model/ExportModel.swift` — `Telemetry.report(_:)` on the unexpected-error
  failure path; add `shouldReport(_:)` (exclude expired-session / cancellation /
  Whole Foods gap).
- `App/Views/RootView.swift` (or `IdleView.swift`) — host the first-run banner.
- `project.yml` —
  - add the `sentry-cocoa` SPM package under `packages:` and as a target
    `dependency` on `AmazonOrderExport`.
  - inject the DSN into Info.plist via build setting:
    `INFOPLIST_KEY_SENTRY_DSN: $(SENTRY_DSN)` (or an explicit `infoPlist` entry),
    with `SENTRY_DSN` supplied by an **xcconfig** (e.g.
    `Config/Secrets.xcconfig`, git-ignored locally; provided in release builds).
    Open-source/CI builds with no value ⇒ empty DSN ⇒ telemetry disabled by the
    `start()` guard. Note in `project.yml` comments that the released DSN is
    public-by-design.
- `README.md` — add the **Privacy & Security** section (table below).

**No new package.** Telemetry lives in `App/` (it's app-shell concern, depends on
`Bundle.main`/`UserDefaults`); `Packages/` stays free of Sentry so the tested
core has zero telemetry dependency.

## `SECURITY.md` + README "Privacy & Security" (this spec owns these)

Both anchor on the **"What leaves your Mac"** table — the single artifact a
reviewer reads to understand egress:

| Destination | When | What | Never |
|---|---|---|---|
| **amazon.com** | While you run an export | Your own Amazon session cookies + your order/transaction pages (you logging into your own account) | — |
| **Sentry** | Only if "Send anonymous crash reports" is ON | App version, OS version, scrubbed crash stack trace, environment | Orders, items, CSVs, cookies, URLs, screenshots, any user/install identifier |
| **Nothing else** | Ever | — | `orders.csv` / `items.csv` / `transactions.csv`, the Keychain session, and cookies **never** leave your Mac |

`SECURITY.md` sections:

- **The one file to read.** "All outbound telemetry is in `App/Telemetry.swift`.
  It is the only file that imports Sentry (a test enforces this). Read it."
- **What leaves your Mac** — the table above.
- **Crash reports: what's in them and how to turn them off.** The lockdown list
  in plain language (no analytics, no install id, no breadcrumbs, no
  screenshots, scrubbed paths, Amazon/secret-bearing events dropped). Steps:
  open Settings (Cmd-,) → turn off "Send anonymous crash reports". Note: off
  means the SDK is never even started.
- **The DSN is public on purpose.** A Sentry DSN is an ingest key, not a read
  key; we commit it in the open for transparency. Worst case is spam, which we
  rate-limit.
- **Keychain storage.** The Amazon session is stored app-private (default ACL),
  readable only by this Developer-ID-signed app; other tools must be granted
  access explicitly. (Cross-links the GUI/keychain decision.)
- **Verifying the build.** "Don't trust me — verify." A short pitch that you can
  confirm the `.dmg` you ran was built from the public source, **with the
  concrete steps (SHA-256, `gh attestation verify`, commit-SHA shown in About)
  provided by** `2026-05-31-release-and-provenance-design.md`. This section
  links there; it does **not** restate the steps.
- **Plain-language pitch.** "This tool touches your Amazon account and your
  purchase history. You shouldn't have to take my word that it keeps them on
  your machine — the source is open, the egress is one small file, and the
  release is verifiable."

The README "Privacy & Security" section is a 3–4 line summary of the same: the
"What leaves your Mac" table (or a tight prose version) + a link to `SECURITY.md`
+ the one-line how-to-disable.

## Out of scope

- **Release pipeline, SLSA/provenance, SHA-256 publishing, `gh attestation
  verify`, commit-SHA-in-About.** Owned by
  `2026-05-31-release-and-provenance-design.md`. We only *reference* it from
  `SECURITY.md`'s "Verifying the build" section.
- **Any analytics / usage events / funnels / install counts.** Explicitly never.
- **Hot enable/disable of the running SDK** (close-on-toggle-off). Noted as a
  one-line future addition; the design is "takes effect next launch".
- **iOS / non-mac targets.**
- **A self-hosted or alternate crash backend.** Sentry only.

## Open questions (for the human)

1. **DSN provisioning in release builds.** This spec assumes an xcconfig
   (`Config/Secrets.xcconfig`, value provided at release time / via CI secret).
   Confirm that's how you want it threaded vs. a checked-in public DSN constant.
   (Either is fine given "DSN is public-by-design"; xcconfig keeps CI/open
   checkouts telemetry-free with zero config.)
2. **Banner vs. alert for the first-run notice.** Designed as a dismissible
   banner on the idle screen. If you'd rather it be a one-time modal `.alert`,
   say so — both are spec'd, banner is the default.
3. **Instant-off.** Are you OK with "toggle takes effect next launch," or do you
   want the off-transition to call `SentrySDK.close()` immediately? (Adds a
   little code; everything else is unchanged.)
4. **`report(_:)` scope.** Confirmed call site is `ExportModel`'s unexpected-error
   path, excluding expired-session/cancellation/Whole-Foods-gap. Any other
   "explicit error" you want reported (e.g., a CSV-write failure)? It would just
   be another `shouldReport`-gated `report(_:)` call.
