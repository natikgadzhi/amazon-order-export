import Foundation
import Testing

@testable import AmazonAuth

private func cookie(_ name: String, value: String = "v") -> HTTPCookie {
  HTTPCookie(properties: [
    .name: name, .value: value, .domain: ".amazon.com", .path: "/",
  ])!
}

@Suite("AmazonCookies")
struct AmazonCookiesTests {
  @Test("all required present → true, none missing")
  func allPresent() {
    let cookies = AmazonCookies.required.map { cookie($0.rawValue) }
    #expect(AmazonCookies.requiredCookiesPresent(in: cookies))
    #expect(AmazonCookies.missingRequiredNames(in: cookies).isEmpty)
  }

  @Test("missing at-main → not present, reported missing")
  func missingOne() {
    let cookies = AmazonCookies.required.filter { $0 != .atMain }.map { cookie($0.rawValue) }
    #expect(!AmazonCookies.requiredCookiesPresent(in: cookies))
    #expect(AmazonCookies.missingRequiredNames(in: cookies) == ["at-main"])
  }
}

@Suite("AmazonSessionSecrets")
struct AmazonSessionSecretsTests {
  @Test("json round-trip preserves cookie names and values")
  func roundTrip() throws {
    let secrets = AmazonSessionSecrets(cookies: [
      cookie("session-id", value: "abc"), cookie("at-main", value: "xyz"),
    ])
    let data = try secrets.encoded()
    let restored = try AmazonSessionSecrets.decoded(from: data)
    #expect(Set(restored.cookies.map(\.name)) == ["session-id", "at-main"])
    #expect(restored.cookies.first { $0.name == "at-main" }?.value == "xyz")
  }
}

@Suite("InMemoryAmazonSecretStore")
struct AmazonSecretStoreTests {
  @Test("write then read; clear empties")
  func writeReadClear() {
    let store = InMemoryAmazonSecretStore()
    #expect(store.read() == nil)
    store.write(secrets: AmazonSessionSecrets(cookies: [cookie("session-id")]))
    #expect(store.read()?.cookies.first?.name == "session-id")
    store.clear()
    #expect(store.read() == nil)
  }
}

@Suite("AmazonEndpoint")
struct AmazonEndpointTests {
  @Test("orders URL is amazon.com/your-orders/orders")
  func ordersURL() {
    let url = AmazonEndpoint.orders.url
    #expect(url.host() == "www.amazon.com")
    #expect(url.path() == "/your-orders/orders")
  }

  @Test("sign-in redirect detection")
  func signin() {
    #expect(
      AmazonEndpoint.isSignInRedirect(URL(string: "https://www.amazon.com/ap/signin?x=1")!))
    #expect(
      !AmazonEndpoint.isSignInRedirect(
        URL(string: "https://www.amazon.com/your-orders/orders")!))
  }
}

@Suite("AuthProbe.classify")
struct AuthProbeClassifyTests {
  @Test("orders page → valid; signin → expired")
  func classify() {
    #expect(
      AuthProbe.classify(finalURL: URL(string: "https://www.amazon.com/your-orders/orders")!)
        == .valid)
    #expect(
      AuthProbe.classify(finalURL: URL(string: "https://www.amazon.com/ap/signin")!)
        == .expired)
  }
}
