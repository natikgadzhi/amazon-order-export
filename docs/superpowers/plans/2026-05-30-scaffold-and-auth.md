# Scaffold + Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the buildable macOS project (XcodeGen + SwiftPM packages + tooling) and implement the authentication slice: `authenticate` logs in via a WKWebView and persists the Amazon session to Keychain; `check` reports whether the stored session is still valid.

**Architecture:** A macOS `.app` bundle (generated from `project.yml` via XcodeGen) acts as a CLI via swift-argument-parser. Logic lives in two local SwiftPM packages — `AmazonAuth` (WKWebView login, cookie capture, Keychain store) and `AmazonOrders` (engine; only stubbed in this plan). `authenticate` runs `NSApplication` with `.regular` activation and a SwiftUI login window; `check` runs `.prohibited` (headless) and probes an authenticated page, treating a redirect to `/ap/signin` as expired.

**Tech Stack:** Swift 6.3 (strict concurrency), SwiftPM, XcodeGen, WebKit (WKWebView), AppKit, SwiftUI, swift-argument-parser, swift-testing (`import Testing`), swift-format.

**Scope note:** This plan covers **P0 (scaffold)** and **P1 (auth)** from the design spec (`docs/superpowers/specs/2026-05-30-amazon-order-export-design.md`). The renderer and order/transaction sources (P2+) are deferred to a later plan written *after* the P1 live-verify gives us real rendered HTML to write parsers against. `AmazonOrders` is created here only as an empty, building package.

---

## File Structure

```
project.yml                                   # XcodeGen spec → AmazonOrderExport.xcodeproj
Makefile                                       # generate / format / lint-format / test / contrib
.swift-format                                  # copied verbatim from Scrapes
.githooks/pre-commit                           # copied verbatim from Scrapes
skills-lock.json                               # twostraws skills (created by `npx skills add`)
CLAUDE.md                                       # conventions + which-skill-when

Packages/
  AmazonAuth/
    Package.swift
    Sources/AmazonAuth/
      AmazonCookies.swift                       # required cookie name enum + helpers
      AmazonSessionSecrets.swift                # NSSecureCoding box around [HTTPCookie]
      AmazonSecretStore.swift                   # protocol + Keychain + InMemory impls
      AuthenticationState.swift                 # state enum
      AmazonAuthManager.swift                   # @MainActor @Observable login coordinator
      AmazonEndpoint.swift                      # URLs (signin, orders, account)
    Tests/AmazonAuthTests/
      AmazonCookiesTests.swift
      AmazonSessionSecretsTests.swift
      AmazonSecretStoreTests.swift
      AmazonAuthManagerTests.swift

  AmazonOrders/
    Package.swift
    Sources/AmazonOrders/AmazonOrders.swift     # empty placeholder (builds)
    Tests/AmazonOrdersTests/AmazonOrdersTests.swift

App/
  AmazonOrderExportApp.swift                    # @main arg-parser root command
  Commands/AuthenticateCommand.swift
  Commands/CheckCommand.swift
  AppRunLoop.swift                              # NSApplication bring-up helpers
  LoginWindow.swift                             # SwiftUI window + WKWebView wrapper
```

---

## Task 1: Bootstrap the two SwiftPM packages with smoke tests

**Files:**
- Create: `Packages/AmazonAuth/Package.swift`
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AmazonAuth.swift`
- Create: `Packages/AmazonAuth/Tests/AmazonAuthTests/SmokeTests.swift`
- Create: `Packages/AmazonOrders/Package.swift`
- Create: `Packages/AmazonOrders/Sources/AmazonOrders/AmazonOrders.swift`
- Create: `Packages/AmazonOrders/Tests/AmazonOrdersTests/SmokeTests.swift`

- [ ] **Step 1: Write `Packages/AmazonAuth/Package.swift`**

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AmazonAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmazonAuth", targets: ["AmazonAuth"]),
    ],
    targets: [
        .target(name: "AmazonAuth"),
        .testTarget(name: "AmazonAuthTests", dependencies: ["AmazonAuth"]),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 2: Write a trivial source + smoke test**

`Packages/AmazonAuth/Sources/AmazonAuth/AmazonAuth.swift`:

```swift
/// Marker for the AmazonAuth module. Real types live in sibling files.
public enum AmazonAuth {
    public static let moduleName = "AmazonAuth"
}
```

`Packages/AmazonAuth/Tests/AmazonAuthTests/SmokeTests.swift`:

```swift
import Testing

@testable import AmazonAuth

@Suite("AmazonAuth smoke")
struct SmokeTests {
    @Test("module is wired up")
    func moduleName() {
        #expect(AmazonAuth.moduleName == "AmazonAuth")
    }
}
```

- [ ] **Step 3: Repeat for `AmazonOrders`** (same shape)

`Packages/AmazonOrders/Package.swift`:

```swift
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AmazonOrders",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmazonOrders", targets: ["AmazonOrders"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.11.2"),
    ],
    targets: [
        .target(name: "AmazonOrders", dependencies: ["SwiftSoup"]),
        .testTarget(name: "AmazonOrdersTests", dependencies: ["AmazonOrders"]),
    ],
    swiftLanguageModes: [.v6]
)
```

`Packages/AmazonOrders/Sources/AmazonOrders/AmazonOrders.swift`:

```swift
/// Marker for the AmazonOrders engine module. Sources/parsers land here in P2+.
public enum AmazonOrders {
    public static let moduleName = "AmazonOrders"
}
```

`Packages/AmazonOrders/Tests/AmazonOrdersTests/SmokeTests.swift`:

```swift
import Testing

@testable import AmazonOrders

@Suite("AmazonOrders smoke")
struct SmokeTests {
    @Test("module is wired up")
    func moduleName() {
        #expect(AmazonOrders.moduleName == "AmazonOrders")
    }
}
```

- [ ] **Step 4: Run both package test suites**

Run: `swift test --package-path Packages/AmazonAuth && swift test --package-path Packages/AmazonOrders`
Expected: both build and PASS (1 test each).

- [ ] **Step 5: Commit**

```bash
git add Packages
git commit -m "P0: bootstrap AmazonAuth and AmazonOrders SwiftPM packages"
```

---

## Task 2: Tooling — Makefile, swift-format, git hook

**Files:**
- Create: `.swift-format`
- Create: `.githooks/pre-commit`
- Create: `Makefile`

- [ ] **Step 1: Create `.swift-format`** — copy the exact file from `/Users/natikgadzhi/src/natikgadzhi/Scrapes/.swift-format` (4-space indent, 100 col, OrderedImports, etc.). Reproduce its full JSON contents verbatim.

- [ ] **Step 2: Create `.githooks/pre-commit`** — copy the exact file from `/Users/natikgadzhi/src/natikgadzhi/Scrapes/.githooks/pre-commit` (zsh script that formats staged `*.swift` in place and re-stages). Make it executable: `chmod +x .githooks/pre-commit`.

- [ ] **Step 3: Create `Makefile`**

```makefile
.PHONY: contrib install-hooks generate format lint-format test

SWIFT_FORMAT_PATHS = App Packages

contrib:
	@echo "Installing development dependencies..."
	brew install xcodegen
	brew install --head xcode-build-server || true
	brew install xcbeautify || true
	@$(MAKE) install-hooks
	@$(MAKE) generate

install-hooks:
	@git config core.hooksPath .githooks
	@echo "Configured git hooks to use .githooks/"

generate:
	xcodegen generate

format:
	swift-format format --in-place --recursive --configuration .swift-format $(SWIFT_FORMAT_PATHS)

lint-format:
	swift-format lint --strict --recursive --configuration .swift-format $(SWIFT_FORMAT_PATHS)

test:
	swift test --package-path Packages/AmazonAuth
	swift test --package-path Packages/AmazonOrders
```

- [ ] **Step 4: Install the hook and verify formatting runs clean**

Run: `make install-hooks && make lint-format`
Expected: `git config` succeeds; `lint-format` exits 0 (no violations) — there is no Swift outside `Packages` yet, and the package sources are already formatted.

- [ ] **Step 5: Commit**

```bash
git add .swift-format .githooks Makefile
git commit -m "P0: add swift-format config, pre-commit hook, Makefile"
```

---

## Task 3: XcodeGen project + app target skeleton (arg-parser hello)

**Files:**
- Create: `project.yml`
- Create: `App/AmazonOrderExportApp.swift`
- Modify: `.gitignore` (ignore generated `*.xcodeproj`)

- [ ] **Step 1: Add swift-argument-parser to the app via `project.yml`**

`project.yml`:

```yaml
name: AmazonOrderExport
options:
  bundleIdPrefix: io.respawn
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
packages:
  AmazonAuth:
    path: Packages/AmazonAuth
  AmazonOrders:
    path: Packages/AmazonOrders
  ArgumentParser:
    url: https://github.com/apple/swift-argument-parser
    from: 1.5.0
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
targets:
  AmazonOrderExport:
    type: tool        # command-line tool that still links AppKit/WebKit
    platform: macOS
    sources:
      - App
    dependencies:
      - package: AmazonAuth
      - package: AmazonOrders
      - package: ArgumentParser
        product: ArgumentParser
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.respawn.AmazonOrderExport
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
```

> Note: `type: tool` builds a CLI binary that can still `import AppKit`/`WebKit` and bring up an `NSApplication`. We package it into a `.app` for notarization in P6; for development we run the tool binary directly.

- [ ] **Step 2: Write a minimal arg-parser root that builds**

`App/AmazonOrderExportApp.swift`:

```swift
import ArgumentParser

@main
struct AmazonOrderExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amazon-order-export",
        abstract: "Export your own Amazon order and transaction history to CSV.",
        version: "0.1.0",
        subcommands: []
    )
}
```

- [ ] **Step 3: Ignore the generated project**

Add to `.gitignore`:

```
# XcodeGen output (regenerate with `make generate`)
*.xcodeproj
```

- [ ] **Step 4: Generate, build, and run `--help`**

Run:
```bash
brew install xcodegen        # if `make contrib` not yet run
make generate
xcodebuild -project AmazonOrderExport.xcodeproj -scheme AmazonOrderExport -configuration Debug build
```
Expected: build succeeds. Then locate the binary and run help:
```bash
BIN=$(xcodebuild -project AmazonOrderExport.xcodeproj -scheme AmazonOrderExport -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{a=$2} / EXECUTABLE_PATH /{b=$2} END{print a"/"b}')
"$BIN" --help
```
Expected: prints the abstract and usage with no subcommands yet.

- [ ] **Step 5: Commit**

```bash
git add project.yml App .gitignore
git commit -m "P0: XcodeGen project + arg-parser app skeleton"
```

---

## Task 4: Install Claude skills + write CLAUDE.md

**Files:**
- Create: `skills-lock.json` (via `npx skills add`)
- Create: `.agents/skills/...` (materialized by the CLI; commit per Scrapes convention)
- Create: `CLAUDE.md`

- [ ] **Step 1: Install the Tier-1 skills (matches Scrapes' lockfile convention)**

Run:
```bash
npx skills add https://github.com/twostraws/swift-concurrency-agent-skill --skill swift-concurrency-pro
npx skills add https://github.com/twostraws/swift-testing-agent-skill   --skill swift-testing-pro
npx skills add https://github.com/twostraws/swiftui-agent-skill         --skill swiftui-pro
```
Expected: `skills-lock.json` created/updated; skills materialized under `.agents/skills/<id>/`.

- [ ] **Step 2: Write `CLAUDE.md`**

```markdown
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
- macOS `.app` (XcodeGen) used as a CLI via swift-argument-parser.
  `authenticate` shows a window (`.regular`); `check`/`sync` run headless
  (`.prohibited`) with an offscreen WKWebView.

## Build / test
- `make generate`  — regenerate the Xcode project from `project.yml`
- `make test`      — run package unit tests (swift-testing)
- `make format` / `make lint-format` — swift-format (config copied from Scrapes)
- Pre-commit hook auto-formats staged Swift. Run `make install-hooks` once.

## Conventions
- Swift 6 strict concurrency; tests use `import Testing` (`@Suite`/`@Test`/`#expect`), not XCTest.
- Logic lives in `Packages/`; `App/` is a thin CLI shell.
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
```

- [ ] **Step 3: Commit**

```bash
git add skills-lock.json .agents CLAUDE.md
git commit -m "P0: install twostraws skills + CLAUDE.md conventions"
```

---

## Task 5: Required-cookie model (`AmazonCookies`)

**Files:**
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AmazonCookies.swift`
- Create: `Packages/AmazonAuth/Tests/AmazonAuthTests/AmazonCookiesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@testable import AmazonAuth

@Suite("AmazonCookies")
struct AmazonCookiesTests {
    private func cookie(_ name: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name, .value: "v", .domain: ".amazon.com", .path: "/",
        ])!
    }

    @Test("all required cookies present → true")
    func allPresent() {
        let cookies = AmazonCookies.required.map { cookie($0.rawValue) }
        #expect(AmazonCookies.requiredCookiesPresent(in: cookies))
        #expect(AmazonCookies.missingRequiredNames(in: cookies).isEmpty)
    }

    @Test("missing at-main → not present, reported missing")
    func missingOne() {
        let cookies = AmazonCookies.required
            .filter { $0 != .atMain }
            .map { cookie($0.rawValue) }
        #expect(!AmazonCookies.requiredCookiesPresent(in: cookies))
        #expect(AmazonCookies.missingRequiredNames(in: cookies) == ["at-main"])
    }
}
```

- [ ] **Step 2: Run it — expect failure**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonCookies`
Expected: FAIL (`AmazonCookies` undefined).

- [ ] **Step 3: Implement `AmazonCookies`**

```swift
import Foundation

/// Names of the cookies that signal a fully-authenticated amazon.com session.
public enum AmazonCookies: String, CaseIterable, Sendable {
    case sessionId = "session-id"
    case ubidMain = "ubid-main"
    case xMain = "x-main"
    case atMain = "at-main"
    case sessAtMain = "sess-at-main"

    /// The subset that must all be present for us to consider the session usable.
    public static let required: [AmazonCookies] = allCases

    public static func requiredCookiesPresent(in cookies: [HTTPCookie]) -> Bool {
        required.allSatisfy { req in cookies.contains { $0.name == req.rawValue } }
    }

    public static func missingRequiredNames(in cookies: [HTTPCookie]) -> [String] {
        required.compactMap { req in
            cookies.contains { $0.name == req.rawValue } ? nil : req.rawValue
        }
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonCookies`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AmazonAuth
git commit -m "P1: AmazonCookies required-cookie model"
```

---

## Task 6: `AmazonSessionSecrets` (NSSecureCoding box for cookies)

**Files:**
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AmazonSessionSecrets.swift`
- Create: `Packages/AmazonAuth/Tests/AmazonAuthTests/AmazonSessionSecretsTests.swift`

- [ ] **Step 1: Write the failing test (archive round-trip)**

```swift
import Foundation
import Testing

@testable import AmazonAuth

@Suite("AmazonSessionSecrets")
struct AmazonSessionSecretsTests {
    private func sampleCookies() -> [HTTPCookie] {
        ["session-id", "at-main"].map {
            HTTPCookie(properties: [
                .name: $0, .value: "val-\($0)", .domain: ".amazon.com", .path: "/",
            ])!
        }
    }

    @Test("secure-coding archive then unarchive preserves cookies")
    func roundTrip() throws {
        let secrets = AmazonSessionSecrets(cookies: sampleCookies())
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: secrets, requiringSecureCoding: true)
        let restored = try #require(
            try NSKeyedUnarchiver.unarchivedObject(
                ofClass: AmazonSessionSecrets.self, from: data))
        let names = Set(restored.cookies.map(\.name))
        #expect(names == ["session-id", "at-main"])
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonSessionSecrets`
Expected: FAIL (`AmazonSessionSecrets` undefined).

- [ ] **Step 3: Implement `AmazonSessionSecrets`**

```swift
import Foundation

/// Persisted authentication secrets: the captured session cookies.
/// `@unchecked Sendable` because `HTTPCookie` is immutable in practice.
public final class AmazonSessionSecrets: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let cookies: [HTTPCookie]

    public init(cookies: [HTTPCookie]) {
        self.cookies = cookies
    }

    public func encode(with coder: NSCoder) {
        let props = cookies.compactMap(\.properties)
        coder.encode(props as NSArray, forKey: "cookieProperties")
    }

    public required init?(coder: NSCoder) {
        let classes = [NSArray.self, NSDictionary.self, NSString.self, NSDate.self, NSURL.self]
        guard
            let raw = coder.decodeObject(of: classes, forKey: "cookieProperties") as? [[String: Any]]
        else {
            return nil
        }
        self.cookies = raw.compactMap { dict in
            HTTPCookie(properties: dict.reduce(into: [:]) { acc, kv in
                acc[HTTPCookiePropertyKey(kv.key)] = kv.value
            })
        }
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonSessionSecrets`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AmazonAuth
git commit -m "P1: AmazonSessionSecrets NSSecureCoding cookie box"
```

---

## Task 7: `AmazonSecretStore` (protocol + InMemory + Keychain)

**Files:**
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AmazonSecretStore.swift`
- Create: `Packages/AmazonAuth/Tests/AmazonAuthTests/AmazonSecretStoreTests.swift`

- [ ] **Step 1: Write the failing test against the in-memory store**

```swift
import Foundation
import Testing

@testable import AmazonAuth

@Suite("AmazonSecretStore")
struct AmazonSecretStoreTests {
    private func secrets() -> AmazonSessionSecrets {
        AmazonSessionSecrets(cookies: [
            HTTPCookie(properties: [
                .name: "session-id", .value: "abc", .domain: ".amazon.com", .path: "/",
            ])!
        ])
    }

    @Test("write then read returns stored secrets; clear empties it")
    func writeReadClear() {
        let store = InMemoryAmazonSecretStore()
        #expect(store.read() == nil)
        store.write(secrets: secrets())
        #expect(store.read()?.cookies.first?.name == "session-id")
        store.clear()
        #expect(store.read() == nil)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonSecretStore`
Expected: FAIL (types undefined).

- [ ] **Step 3: Implement protocol + both stores**

```swift
import Foundation
import Security

public protocol AmazonSecretStoring: Sendable {
    func read() -> AmazonSessionSecrets?
    func write(secrets: AmazonSessionSecrets)
    func clear()
}

/// Test/double store. Not for production.
public final class InMemoryAmazonSecretStore: AmazonSecretStoring, @unchecked Sendable {
    private var stored: AmazonSessionSecrets?
    public init() {}
    public func read() -> AmazonSessionSecrets? { stored }
    public func write(secrets: AmazonSessionSecrets) { stored = secrets }
    public func clear() { stored = nil }
}

/// Keychain-backed store (generic password item).
public final class KeychainAmazonSecretStore: AmazonSecretStoring, @unchecked Sendable {
    public static let defaultServiceName = "io.respawn.AmazonOrderExport"
    private let serviceName: String

    public init(serviceName: String = KeychainAmazonSecretStore.defaultServiceName) {
        self.serviceName = serviceName
    }

    public func read() -> AmazonSessionSecrets? {
        var query = baseQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: AmazonSessionSecrets.self, from: data)
    }

    public func write(secrets: AmazonSessionSecrets) {
        guard
            let data = try? NSKeyedArchiver.archivedData(
                withRootObject: secrets, requiringSecureCoding: true)
        else {
            return
        }
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func baseQuery() -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: serviceName]
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonSecretStore`
Expected: PASS. (Only the in-memory store is unit-tested; the Keychain store is exercised in the live-verify checkpoint, Task 12.)

- [ ] **Step 5: Commit**

```bash
git add Packages/AmazonAuth
git commit -m "P1: AmazonSecretStore protocol + InMemory + Keychain"
```

---

## Task 8: `AuthenticationState` + `AmazonEndpoint`

**Files:**
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AuthenticationState.swift`
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AmazonEndpoint.swift`
- Create: `Packages/AmazonAuth/Tests/AmazonAuthTests/AmazonEndpointTests.swift`

- [ ] **Step 1: Write the failing test for endpoints**

```swift
import Foundation
import Testing

@testable import AmazonAuth

@Suite("AmazonEndpoint")
struct AmazonEndpointTests {
    @Test("orders URL points at amazon.com your-orders")
    func ordersURL() {
        let url = AmazonEndpoint.orders.url
        #expect(url.host() == "www.amazon.com")
        #expect(url.path() == "/your-orders/orders")
    }

    @Test("signin path detector matches /ap/signin redirects")
    func signinDetector() {
        #expect(AmazonEndpoint.isSignInRedirect(URL(string: "https://www.amazon.com/ap/signin?x=1")!))
        #expect(!AmazonEndpoint.isSignInRedirect(URL(string: "https://www.amazon.com/your-orders/orders")!))
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonEndpoint`
Expected: FAIL.

- [ ] **Step 3: Implement both files**

`AuthenticationState.swift`:

```swift
/// Lifecycle of the auth session as the login flow progresses.
public enum AuthenticationState: Sendable, Equatable {
    case new
    case unauthenticated
    case authenticating
    case authenticated
}
```

`AmazonEndpoint.swift`:

```swift
import Foundation

public enum AmazonEndpoint: Sendable {
    case signIn
    case orders
    case account

    public var url: URL {
        switch self {
        case .signIn:
            return URL(string: "https://www.amazon.com/ap/signin")!
        case .orders:
            return URL(string: "https://www.amazon.com/your-orders/orders")!
        case .account:
            return URL(string: "https://www.amazon.com/gp/css/homepage.html")!
        }
    }

    /// True when a URL is Amazon's sign-in page — our signal that the session expired.
    public static func isSignInRedirect(_ url: URL) -> Bool {
        url.path().hasPrefix("/ap/signin")
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonEndpoint`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AmazonAuth
git commit -m "P1: AuthenticationState + AmazonEndpoint"
```

---

## Task 9: `AmazonAuthManager` — cookie capture + persistence

**Files:**
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AmazonAuthManager.swift`
- Create: `Packages/AmazonAuth/Tests/AmazonAuthTests/AmazonAuthManagerTests.swift`

The manager owns the login `WKWebView` and persists secrets when all required
cookies appear. To keep it unit-testable without a live web view, capture logic
lives in a pure method `ingest(cookies:)` that the navigation delegate calls.

- [ ] **Step 1: Write the failing test for `ingest` + `initSessionFromSecureStorage`**

```swift
import Foundation
import Testing

@testable import AmazonAuth

@Suite("AmazonAuthManager")
@MainActor
struct AmazonAuthManagerTests {
    private func cookies(_ names: [String]) -> [HTTPCookie] {
        names.map {
            HTTPCookie(properties: [
                .name: $0, .value: "v", .domain: ".amazon.com", .path: "/",
            ])!
        }
    }

    @Test("ingesting a complete cookie set authenticates and persists")
    func ingestComplete() {
        let store = InMemoryAmazonSecretStore()
        let manager = AmazonAuthManager(secretStore: store)
        manager.ingest(cookies: cookies(AmazonCookies.required.map(\.rawValue)))
        #expect(manager.state == .authenticated)
        #expect(store.read()?.cookies.count == AmazonCookies.required.count)
    }

    @Test("incomplete cookie set does not authenticate")
    func ingestIncomplete() {
        let store = InMemoryAmazonSecretStore()
        let manager = AmazonAuthManager(secretStore: store)
        manager.ingest(cookies: cookies(["session-id"]))
        #expect(manager.state != .authenticated)
        #expect(store.read() == nil)
    }

    @Test("initSessionFromSecureStorage restores a stored session")
    func restore() {
        let store = InMemoryAmazonSecretStore()
        store.write(secrets: AmazonSessionSecrets(
            cookies: cookies(AmazonCookies.required.map(\.rawValue))))
        let manager = AmazonAuthManager(secretStore: store)
        manager.initSessionFromSecureStorage()
        #expect(manager.state == .authenticated)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonAuthManager`
Expected: FAIL.

- [ ] **Step 3: Implement `AmazonAuthManager`**

```swift
import Foundation
import Observation
import WebKit

@MainActor @Observable
public final class AmazonAuthManager: NSObject {
    private let secretStore: any AmazonSecretStoring

    public private(set) var state: AuthenticationState = .new
    public private(set) var secrets: AmazonSessionSecrets?

    private var webView: WKWebView?

    public init(secretStore: any AmazonSecretStoring) {
        self.secretStore = secretStore
        super.init()
    }

    /// Lazily-created login web view; the caller embeds this in a window.
    public var loginWebView: WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isInspectable = true
        self.webView = webView
        return webView
    }

    /// Begin login by loading the orders page; Amazon redirects to sign-in if needed.
    public func startLogin() {
        state = .authenticating
        loginWebView.load(URLRequest(url: AmazonEndpoint.orders.url))
    }

    /// Pure capture entry point — testable without a live web view.
    public func ingest(cookies: [HTTPCookie]) {
        guard AmazonCookies.requiredCookiesPresent(in: cookies) else { return }
        let secrets = AmazonSessionSecrets(cookies: cookies)
        secretStore.write(secrets: secrets)
        self.secrets = secrets
        state = .authenticated
    }

    public func initSessionFromSecureStorage() {
        guard let stored = secretStore.read(),
            AmazonCookies.requiredCookiesPresent(in: stored.cookies)
        else {
            state = .unauthenticated
            return
        }
        secrets = stored
        state = .authenticated
    }

    public func reset() {
        secretStore.clear()
        secrets = nil
        state = .unauthenticated
    }
}

extension AmazonAuthManager: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard state != .authenticated else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            self?.ingest(cookies: cookies)
        }
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --package-path Packages/AmazonAuth --filter AmazonAuthManager`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Packages/AmazonAuth
git commit -m "P1: AmazonAuthManager cookie capture + persistence"
```

---

## Task 10: Headless auth probe (`check` logic)

**Files:**
- Create: `Packages/AmazonAuth/Sources/AmazonAuth/AuthProbe.swift`
- Create: `Packages/AmazonAuth/Tests/AmazonAuthTests/AuthProbeTests.swift`

The probe seeds an offscreen `WKWebView` with stored cookies, loads the orders
page, and classifies the result. The classification of the *final URL* is a pure
function we unit-test; the web-view drive is integration-tested in the live
checkpoint.

- [ ] **Step 1: Write the failing test for the classifier**

```swift
import Foundation
import Testing

@testable import AmazonAuth

@Suite("AuthProbe.classify")
struct AuthProbeTests {
    @Test("landing on orders page → valid")
    func valid() {
        let result = AuthProbe.classify(finalURL: URL(string: "https://www.amazon.com/your-orders/orders")!)
        #expect(result == .valid)
    }

    @Test("redirected to sign-in → expired")
    func expired() {
        let result = AuthProbe.classify(finalURL: URL(string: "https://www.amazon.com/ap/signin?x=1")!)
        #expect(result == .expired)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `swift test --package-path Packages/AmazonAuth --filter AuthProbe`
Expected: FAIL.

- [ ] **Step 3: Implement `AuthProbe`**

```swift
import Foundation
import WebKit

public enum AuthProbeResult: Sendable, Equatable {
    case valid
    case expired
    case noStoredSession
}

public enum AuthProbe {
    /// Pure classification of where the probe navigation ended up.
    public static func classify(finalURL: URL) -> AuthProbeResult {
        AmazonEndpoint.isSignInRedirect(finalURL) ? .expired : .valid
    }

    /// Seed an offscreen web view with stored cookies, load orders, classify.
    @MainActor
    public static func run(secretStore: any AmazonSecretStoring) async -> AuthProbeResult {
        guard let secrets = secretStore.read() else { return .noStoredSession }

        let configuration = WKWebViewConfiguration()
        let store = configuration.websiteDataStore.httpCookieStore
        for cookie in secrets.cookies {
            await store.setCookie(cookie)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let driver = NavigationProbeDriver()
        webView.navigationDelegate = driver
        let finalURL = await driver.load(AmazonEndpoint.orders.url, in: webView)
        return classify(finalURL: finalURL)
    }
}

/// Drives a single navigation and resolves with the final URL.
@MainActor
private final class NavigationProbeDriver: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<URL, Never>?

    func load(_ url: URL, in webView: WKWebView) async -> URL {
        await withCheckedContinuation { cont in
            self.continuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(returning: webView.url ?? AmazonEndpoint.orders.url)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(returning: webView.url ?? AmazonEndpoint.signIn.url)
        continuation = nil
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `swift test --package-path Packages/AmazonAuth --filter AuthProbe`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/AmazonAuth
git commit -m "P1: AuthProbe headless session check + URL classifier"
```

---

## Task 11: SwiftUI login window + NSApplication bring-up

**Files:**
- Create: `App/LoginWindow.swift`
- Create: `App/AppRunLoop.swift`

- [ ] **Step 1: Write `App/LoginWindow.swift` (wrap the manager's web view)**

```swift
import AmazonAuth
import SwiftUI
import WebKit

/// NSViewRepresentable hosting the auth manager's login web view.
struct LoginWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
struct LoginWindowContent: View {
    let manager: AmazonAuthManager
    let onAuthenticated: () -> Void

    var body: some View {
        LoginWebView(webView: manager.loginWebView)
            .frame(minWidth: 480, minHeight: 720)
            .onChange(of: manager.state) { _, newValue in
                if newValue == .authenticated { onAuthenticated() }
            }
            .onAppear { manager.startLogin() }
    }
}
```

- [ ] **Step 2: Write `App/AppRunLoop.swift` (NSApplication helpers)**

```swift
import AppKit
import AmazonAuth
import SwiftUI

enum AppRunLoop {
    /// Run a regular (windowed) app that shows the login window until authenticated.
    @MainActor
    static func runLogin(manager: AmazonAuthManager) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let hosting = NSHostingController(
            rootView: LoginWindowContent(manager: manager) {
                NSApplication.shared.terminate(nil)
            })
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign in to Amazon"
        window.setContentSize(NSSize(width: 480, height: 720))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    /// Run a headless (no-UI) block on the main actor, then exit with `code`.
    @MainActor
    static func runHeadless(_ work: @escaping @MainActor () async -> Int32) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            let code = await work()
            exit(code)
        }
        app.run()
    }
}
```

- [ ] **Step 3: Build the app to verify it compiles**

Run: `make generate && xcodebuild -project AmazonOrderExport.xcodeproj -scheme AmazonOrderExport -configuration Debug build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add App
git commit -m "P1: SwiftUI login window + NSApplication run-loop helpers"
```

---

## Task 12: Wire `authenticate` and `check` subcommands

**Files:**
- Create: `App/Commands/AuthenticateCommand.swift`
- Create: `App/Commands/CheckCommand.swift`
- Modify: `App/AmazonOrderExportApp.swift` (register subcommands)

- [ ] **Step 1: Write `AuthenticateCommand`**

```swift
import AmazonAuth
import ArgumentParser
import Foundation

struct AuthenticateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authenticate",
        abstract: "Open a window to sign in to Amazon and store the session.")

    @MainActor
    func run() async throws {
        let manager = AmazonAuthManager(secretStore: KeychainAmazonSecretStore())
        AppRunLoop.runLogin(manager: manager)  // returns only when the app terminates
    }
}
```

- [ ] **Step 2: Write `CheckCommand`**

```swift
import AmazonAuth
import ArgumentParser
import Foundation

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check whether the stored Amazon session is still valid.")

    @MainActor
    func run() async throws {
        AppRunLoop.runHeadless {
            let result = await AuthProbe.run(secretStore: KeychainAmazonSecretStore())
            switch result {
            case .valid:
                print("authenticated")
                return 0
            case .expired:
                print("expired — run `authenticate` again")
                return 1
            case .noStoredSession:
                print("no stored session — run `authenticate` first")
                return 2
            }
        }
    }
}
```

- [ ] **Step 3: Register subcommands**

In `App/AmazonOrderExportApp.swift`, change `subcommands: []` to:

```swift
        subcommands: [AuthenticateCommand.self, CheckCommand.self]
```

- [ ] **Step 4: Build and verify subcommands are listed**

Run:
```bash
make generate && xcodebuild -project AmazonOrderExport.xcodeproj -scheme AmazonOrderExport -configuration Debug build
BIN=$(xcodebuild -project AmazonOrderExport.xcodeproj -scheme AmazonOrderExport -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{a=$2} / EXECUTABLE_PATH /{b=$2} END{print a"/"b}')
"$BIN" --help
"$BIN" check; echo "exit: $?"
```
Expected: `--help` lists `authenticate` and `check`. `check` prints `no stored session` and exits `2` (nothing stored yet).

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "P1: wire authenticate + check subcommands"
```

---

## Task 13: Live-verify checkpoint (human in the loop)

This task is **not** automated — it is the P1 acceptance gate. Stop and ask the user to run it.

- [ ] **Step 1: Authenticate**

Ask the user to run the built binary's `authenticate` subcommand, sign in to Amazon in the window (including any 2FA), and confirm the window closes on success.

- [ ] **Step 2: Check**

Ask the user to run `check`.
Expected: prints `authenticated` and exits `0`.

- [ ] **Step 3: Capture a fixture for P2/P3**

While authenticated, ask the user to run (or we add a temporary debug flag to) a one-off that saves the rendered `/your-orders/orders` HTML to `Packages/AmazonOrders/Tests/AmazonOrdersTests/Fixtures/orders-sample.html`. The user scrubs any PII they don't want committed. This fixture seeds the P3 parser tests.

- [ ] **Step 4: Record results**

Note pass/fail and any surprises (cookie names that differed, 2FA quirks, redirect behavior) in the next plan's preamble. Update `AmazonCookies.required` if the live cookie set differs from the assumed five.

---

## Self-Review

- **Spec coverage:** P0 scaffold (Tasks 1–4: packages, tooling, XcodeGen, skills+CLAUDE.md) and P1 auth (Tasks 5–13: cookies, secrets, store, state/endpoints, manager, probe, window, subcommands, live-verify) are all covered. P2+ (renderer, sources, CSV) are explicitly deferred per the scope note. ✓
- **Placeholder scan:** No TBD/TODO; every code step has complete code. The two config-file copies (`.swift-format`, `.githooks/pre-commit`) reference exact source paths in Scrapes with their contents already known. ✓
- **Type consistency:** `AmazonSecretStoring` / `AmazonSessionSecrets` / `AmazonAuthManager(secretStore:)` / `AmazonEndpoint` / `AuthProbeResult` are used consistently across tasks. `ingest(cookies:)` is the single capture entry point referenced by both the delegate and tests. ✓
- **Known risk:** `type: tool` linking AppKit/WebKit + `NSApplication` from an arg-parser command is the least-certain part; Task 11/12 build steps catch compile issues early, and the Task 13 live run validates the run loop. If `tool` proves unable to host a window, fall back to `type: application` in `project.yml` with a `LSUIElement`-style headless mode — note this in the next plan if hit.
```
