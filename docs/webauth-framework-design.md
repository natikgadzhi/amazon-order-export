# webauth — web-login token-capture framework (design / requirements / constraints)

Status: proposal. Author: Natik (+ Claude). Date: 2026-05-30.

## 1. Problem statement
Several small local tools authenticate to undocumented web APIs by reusing the
user's logged-in browser session: pop a real login webview, let the human do the
OAuth/2FA dance, then intercept the secrets that authorize later headless
requests. Today each tool reinvents the webview-drive + intercept + persist loop.
We want **one abstraction** that, given a login URL and a per-site interception
hook, drives a WKWebView to completion and hands back a normalized, Keychain-
persisted JSON secret bundle that any tool (Swift, Go, Python) can read.

## 2. Core abstraction
The framework owns the WKWebView, the navigation lifecycle, and Keychain I/O. A
site implements only the policy: where to log in, what to extract, and when it's
done or stale. Capture happens after every navigation commit; the hook can read
cookies and run JS in the page (for localStorage / IndexedDB), and returns either
"not yet" or a finished bundle.

```swift
public protocol AuthSite: Sendable {
    /// Keychain service id, e.g. "io.respawn.AmazonOrderExport".
    var service: String { get }
    /// Where to send the webview; site redirects to its login if unauthenticated.
    var startURL: URL { get }

    /// Run after each navigation commit. `page` exposes cookies + evaluateJS.
    /// Return a bundle when every required secret is present, else nil (keep going).
    func capture(from page: AuthPage) async -> SecretBundle?

    /// Expiry signal, evaluated on a headless replay (e.g. final URL is /ap/signin,
    /// or an API probe returns 401).
    func isExpired(_ probe: ExpiryProbe) -> Bool
}

public protocol AuthPage: Sendable {              // provided by the framework
    var url: URL { get }
    func cookies() async -> [HTTPCookie]
    func evaluateJS(_ source: String) async throws -> Any?   // localStorage/IndexedDB
}

/// Normalized output. One Keychain item per site, JSON-encoded.
public struct SecretBundle: Codable, Sendable {
    public var cookies: [CookieField]   // name/value/domain/path/secure/expiresAt
    public var values: [String: String] // named scalars (xoxc, copilot tokens, ...)
    public var capturedAt: Date
}
```

This is a faithful generalization of the working Amazon code: `startURL` =
`AmazonEndpoint.orders`, `capture` = `requiredCookiesPresent` + `AmazonSessionSecrets`,
`isExpired` = `isSignInRedirect`, and the bundle's `cookies` is exactly today's
`Wire` shape. The only new surface is `values` (scalars) and `evaluateJS`.

## 3. Secret-type matrix

| Site (consumer)            | Secret kinds                                   | Completion signal (capture done)                          | Expiry signal                              |
|----------------------------|------------------------------------------------|-----------------------------------------------------------|--------------------------------------------|
| amazon-order-export (Swift)| 5 cookies: session-id, ubid-main, x-main, at-main, sess-at-main | all 5 cookies present in store                            | headless GET lands on `/ap/signin`         |
| slack-cli (Go)             | `xoxc` token (localStorage/IndexedDB) + `xoxd` cookie | `xoxd` cookie present AND JS read of localStorage yields an `xoxc-…` token | `auth.test` API returns `invalid_auth`     |
| copilot-python (Python)    | two tokens (mechanism TBD: header/storage)     | both token slots non-empty                                | token endpoint returns 401 / token expired |

## 4. Cross-language strategy
WKWebView is inherently macOS/AppKit/Swift and requires an app bundle; Go and
Python cannot host it. Two options:

- **(a) Swift lib + thin `webauth` helper CLI.** One Swift package implements
  `AuthSite`/`AuthPage` and the WKWebView driver, plus a tiny bundled `.app`/CLI
  (`webauth login <site>`, `webauth check <site>`) that writes the JSON bundle to
  Keychain. Go/Python consumers shell out to it and read Keychain via
  `security … | jq`. Site definitions for Slack/Copilot ship as small Swift files
  (or a declarative JSON describing required cookies + a JS snippet).
- **(b) Per-language reimplementations** sharing only a written spec — each tool
  bundles its own webview shim.

**Recommendation: (a).** The webview/intercept/2FA logic is the hard, fragile
part and is identical across sites; reimplementing it three times in three
languages triples the maintenance and the security-review surface. A single
notarized helper binary is the smallest thing that covers all three. Consumers
already converge on this shape: slack-cli reads Keychain through a shared
`cli-kit/auth` Go module, and Amazon already persists browser-readable JSON for
exactly this reuse. The helper just becomes the writer that `cli-kit/auth` reads.

## 5. Persistence + interop contract
- **Keychain item:** class `genericPassword`, one item per site.
  - `service` = reverse-DNS app id, e.g. `io.respawn.AmazonOrderExport`,
    `io.respawn.slack-cli`, `io.respawn.copilot`.
  - `account` = `webauth-session` (single user per machine; `write` deletes any
    prior item first, as Amazon does today).
- **Value:** the `SecretBundle` JSON (pretty-printed, sorted keys) — auditable by
  eye and by `jq`. Schema = `{ cookies:[{name,value,domain,path,secure,expiresAt}],
  values:{<name>:<string>}, capturedAt:<epoch> }`.
- **Read path (any language):**
  `security find-generic-password -s io.respawn.<app> -w | jq -r '.values.xoxc'`
  or `… | jq '.cookies[] | select(.name=="xoxd")'`.
  Note: slack-cli currently stores two separate items (`slack-xoxc-token`,
  `slack-xoxd-token`); adopting the bundle means one item — `cli-kit/auth` gains a
  thin bundle reader, or keeps env-var overrides for the paste path.
- **Rotation owner:** the producing tool's `check`/`login` command owns refresh.
  `webauth check <site>` returns valid/expired/missing (exit code); on expired the
  user re-runs `webauth login <site>`. Consumers never refresh secrets they only
  read — they detect 401 and tell the user to re-login.

## 6. Constraints
- macOS-only; WKWebView needs an `.app` bundle (a WebContent helper process), so
  the helper ships as a bundled binary, not a bare SwiftPM executable.
- Swift 6 strict concurrency: `AuthSite`/page hooks are `Sendable`; the WKWebView
  driver stays `@MainActor` (as `AmazonAuthManager` is today).
- Secrets are **bearer credentials**: Keychain only, never written to logs, files,
  or argv. `capture`/`evaluateJS` results must not be logged. Log URLs/states only.
- Least-code / forget-it ethos: smallest protocol that covers all three sites;
  prefer declarative site definitions over bespoke code; strong "why" docs over
  abstraction ceremony.

## 7. Recommendation
**Write this requirements doc now; extract the framework after slack-cli becomes
the second consumer — don't extract yet.** Amazon is one data point and a single
data point can't prove an abstraction; the `values` + `evaluateJS` surface exists
only on paper until Slack's localStorage/IndexedDB capture forces its real shape
(and Copilot's two-token case stress-tests it again). Extracting now risks
freezing an interface around Amazon's cookie-only happy path. Concretely: keep
building Slack capture against the *protocol sketch above* (copying, not sharing,
~150 lines from AmazonAuth); when it works, the diff between the two
implementations is the true abstraction, and *then* lift it into a standalone
repo. Proposed home when that day comes: a satellite repo `~/src/natikgadzhi/webauth`
(Swift package + `webauth` helper binary; site defs and the `cli-kit/auth` reader
live alongside). Do not create that repo yet.

## Appendix A — Slack capture mechanism (verified)

Verified 2026-05-30 against the local `~/src/natikgadzhi/slack-cli` checkout and
public Slack-token-extraction docs. This pins down exactly what the framework's
`AuthSite` hook must produce for slack-cli to consume.

### slack-cli auth-check command + output

```sh
slack-cli auth check
```

With a live session it validates both credentials via the Slack `auth.test` API
(`internal/api/client.go` → `c.Call("auth.test", nil)`):

```
[INFO] xoxc: xoxc-215... (length 111)
[OK] xoxc: has expected prefix "xoxc-"
[INFO] xoxd: xoxd-qt7... (length 211)
[OK] xoxd: has expected prefix "xoxd-"
[OK] authenticated as natik.gadzhi on Lambda
```

With no credentials configured (no env vars, no Keychain items) it fails and
names exactly what it wants:

```
[FAIL] xoxc: no authentication token found. Set SLACK_XOXC, pass --token, or run your tool's auth login command: no authentication token found
[FAIL] xoxd: no authentication token found. Set SLACK_XOXD, pass --token, or run your tool's auth login command: no authentication token found
one or more tokens are not configured
```

### Where slack-cli reads xoxc / xoxd

Two **separate** credentials, each resolved env-first then Keychain
(`internal/auth/auth.go` via `cli-kit/auth.ResolveToken`; defaults in
`internal/config/config.go`). Env vars take precedence over Keychain.

| Credential | Env var      | Keychain service (default) | Keychain account (default) |
|------------|--------------|----------------------------|----------------------------|
| xoxc token | `SLACK_XOXC` | `slack-xoxc-token`         | current OS user (`whoami`) |
| xoxd cookie| `SLACK_XOXD` | `slack-xoxd-token`         | current OS user (`whoami`) |

Overridable via `SLACK_XOXC_SERVICE`, `SLACK_XOXD_SERVICE`,
`SLACK_KEYCHAIN_ACCOUNT`. The xoxd value is the raw `d` cookie value (`xoxd-…`),
URL-encoded on store and sent as the `d=` Cookie header on API calls; `auth.test`
is the validation call.

### Verified browser-capture recipe

- **xoxc** — lives in `localStorage`, key **`localConfig_v2`** (a JSON string).
  Parse it and read `teams[<TEAM_ID>].token`. Self-locating snippet:
  ```js
  JSON.parse(localStorage.localConfig_v2).teams[document.location.pathname.match(/^\/client\/([A-Z0-9]+)/)[1]].token
  ```
  Value begins with `xoxc-`. Requires running JS in the page context.
- **xoxd** — the cookie named **`d`** on domain **`.slack.com`**. Value begins
  with `xoxd-`. The `d` cookie is **HTTPOnly**, so `document.cookie` cannot read
  it — it must be pulled from the cookie store (WKWebView `WKHTTPCookieStore`),
  not via `evaluateJS`.

Sources:
- https://github.com/korotovsky/slack-mcp-server/blob/master/docs/01-authentication-setup.md
- https://docs.mau.fi/bridges/go/slack/authentication.html
- https://github.com/NoF0rte/slack-slurp

### Implication for the `AuthSite` hook

This confirms the design's `evaluateJS` + scalar-`values` surface is necessary,
not speculative: the hook MUST be able to (a) read a **named cookie** from the
WKWebView cookie store (`d` on `.slack.com`, HTTPOnly — JS can't see it) and
(b) `evaluateJS` to parse a value out of localStorage JSON (`localConfig_v2` →
`teams[teamID].token`) into `values["xoxc"]`. Cookie-only capture (Amazon's
happy path) is insufficient; both surfaces are required for the second consumer.
