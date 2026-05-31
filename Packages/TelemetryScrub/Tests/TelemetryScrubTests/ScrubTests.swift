import Foundation
import Testing

@testable import TelemetryScrub

// MARK: - redactHomePaths

@Suite("Scrub.redactHomePaths")
struct RedactHomePathsTests {
  @Test("replaces username in /Users/<name>/… path")
  func redactsUsername() {
    let result = Scrub.redactHomePaths("/Users/natik/Desktop/amazon-orders/x.csv")
    #expect(result.contains("/Users/<redacted>/"))
    #expect(!result.contains("natik"))
  }

  @Test("handles multiple occurrences in a single string")
  func multipleOccurrences() {
    let result = Scrub.redactHomePaths(
      "from /Users/natik/a.csv to /Users/natik/b.csv")
    #expect(result.components(separatedBy: "/Users/<redacted>/").count == 3)
    #expect(!result.contains("natik"))
  }

  @Test("passes through string with no /Users/ path unchanged")
  func noPath() {
    let input = "Fatal error: Index out of range"
    #expect(Scrub.redactHomePaths(input) == input)
  }

  @Test("does not treat a bare ~ as a path")
  func tilde() {
    let input = "flag ~ value"
    #expect(Scrub.redactHomePaths(input) == input)
  }
}

// MARK: - containsSecretValue

@Suite("Scrub.containsSecretValue")
struct ContainsSecretValueTests {
  // --- Things that ARE secrets ---

  @Test("amazon.com URL is a secret")
  func amazonURL() {
    #expect(Scrub.containsSecretValue("https://www.amazon.com/your-orders/orders?x=1"))
  }

  @Test("Bearer token is a secret")
  func bearerToken() {
    #expect(
      Scrub.containsSecretValue(
        "Authorization: Bearer eyJhbGciOi.JIUzI1NiIsInR5cCI6.IkpXVCJ9abcdef"))
  }

  @Test("x-amz header value is a secret")
  func xAmzHeader() {
    #expect(Scrub.containsSecretValue("x-amz-security-token: AQoDYXdz..."))
  }

  @Test("40-char hex blob is a secret")
  func hexBlob() {
    #expect(Scrub.containsSecretValue("a3f9c0e8b71d4a26f0d9c8b7a6e5f4d3c2b1a098"))
  }

  // --- THE CRITICAL GUARD: symbol / message strings must NOT be flagged ---

  @Test("Swift symbol AmazonOrderExport.ExportModel.startExport() is NOT a secret")
  func symbolExportModel() {
    #expect(!Scrub.containsSecretValue("AmazonOrderExport.ExportModel.startExport()"))
  }

  @Test("Swift type AmazonAuth.AmazonSessionSecrets is NOT a secret")
  func symbolSessionSecrets() {
    #expect(!Scrub.containsSecretValue("AmazonAuth.AmazonSessionSecrets"))
  }

  @Test("benign error message is NOT a secret")
  func benignError() {
    #expect(!Scrub.containsSecretValue("Fatal error: Index out of range"))
  }

  @Test("plain package symbol path is NOT a secret")
  func packageSymbol() {
    #expect(
      !Scrub.containsSecretValue(
        "AmazonOrderExport.ExportModel.start(completion:)"))
  }
}

// MARK: - containsSecretValue (adversarial hardening)

@Suite("Scrub.containsSecretValue — adversarial")
struct ContainsSecretValueAdversarialTests {

  // CRITICAL-2: uppercase / mixed-case amazon.com host must be caught
  @Test("AMAZON.COM host (all-caps) is a secret")
  func amazonURLAllCaps() {
    #expect(Scrub.containsSecretValue("https://AMAZON.COM/your-orders"))
  }

  @Test("Amazon.com host (title-case) is a secret")
  func amazonURLTitleCase() {
    #expect(Scrub.containsSecretValue("https://Amazon.com/your-orders"))
  }

  @Test("www.AMAZON.COM host is a secret")
  func amazonURLWwwCaps() {
    #expect(Scrub.containsSecretValue("https://www.AMAZON.COM/your-orders"))
  }

  @Test("http:// scheme amazon.com URL is a secret")
  func amazonURLHttp() {
    #expect(Scrub.containsSecretValue("http://amazon.com/gp/css/order-history"))
  }

  // CRITICAL-1: Amazon session cookie Atza|… must be caught
  @Test("Atza| session cookie value is a secret")
  func atzaCookie() {
    #expect(
      Scrub.containsSecretValue(
        "Atza|IQEBLjAsAhRmHjNgHNDlznmBnfyMIZRqHgIVAQ"))
  }

  @Test("sanitizeMessage redacts Atza| cookie value")
  func atzaRedacted() {
    let result = Scrub.sanitizeMessage(
      "cookie: Atza|IQEBLjAsAhRmHjNgHNDlznmBnfyMIZRqHgIVAQ; path=/")
    #expect(!result.contains("IQEBLjAsAhRmHjNgHNDlznmBnfyMIZRqHgIVAQ"))
    #expect(result.contains("<redacted>"))
  }

  // IMPORTANT-1 + IMPORTANT-3: symbol names with digits must NOT be flagged
  @Test("SHA256 identifier is NOT a secret")
  func sha256Identifier() {
    #expect(!Scrub.containsSecretValue("SHA256"))
  }

  @Test("Base64Decoder identifier is NOT a secret")
  func base64DecoderIdentifier() {
    #expect(!Scrub.containsSecretValue("Base64Decoder"))
  }

  @Test("OAuth2SessionManager identifier is NOT a secret")
  func oauth2SessionManagerIdentifier() {
    #expect(!Scrub.containsSecretValue("OAuth2SessionManager"))
  }

  @Test("dotted symbol App.Base64Decoder.decode(data:) is NOT a secret")
  func base64DecoderDotted() {
    #expect(!Scrub.containsSecretValue("App.Base64Decoder.decode(data:)"))
  }

  @Test("UUID 550e8400-e29b-41d4-a716-446655440000 is NOT a secret")
  func uuidNotSecret() {
    #expect(!Scrub.containsSecretValue("550e8400-e29b-41d4-a716-446655440000"))
  }

  @Test("JWT eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 is a secret")
  func jwtSecret() {
    #expect(
      Scrub.containsSecretValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
  }
}

// MARK: - redactHomePaths (adversarial hardening)

@Suite("Scrub.redactHomePaths — adversarial")
struct RedactHomePathsAdversarialTests {

  // IMPORTANT-2: mid-string Users/<name>/ without leading slash
  @Test("mid-string Users/<name>/ without leading slash is redacted")
  func midStringUsersPath() {
    let result = Scrub.redactHomePaths("opened at Users/natik/Desktop/x")
    #expect(!result.contains("natik"))
  }
}

// MARK: - sanitizeMessage

@Suite("Scrub.sanitizeMessage")
struct SanitizeMessageTests {
  @Test("redacts home path, reduces URL to scheme://host, removes token in URL query")
  func fullSanitize() {
    let input =
      "export failed at https://amazon.com/foo?token=SEKRET for /Users/natik/x"
    let result = Scrub.sanitizeMessage(input)
    #expect(!result.contains("natik"))
    // URL should be reduced — no path or query
    #expect(!result.contains("/foo"))
    #expect(!result.contains("SEKRET"))
    // scheme://host is preserved
    #expect(result.contains("https://amazon.com"))
  }

  @Test("benign message passes through unchanged")
  func benignMessage() {
    let input = "Could not write file: permission denied"
    #expect(Scrub.sanitizeMessage(input) == input)
  }

  @Test("Bearer token in message is redacted")
  func bearerInMessage() {
    let result = Scrub.sanitizeMessage(
      "auth failed: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef1234")
    #expect(!result.contains("eyJ"))
    #expect(result.contains("<redacted>"))
  }

  @Test("x-amz value in message is redacted")
  func xAmzInMessage() {
    let result = Scrub.sanitizeMessage("header x-amz-security-token: AQoDYXdzvalue123456")
    #expect(result.contains("<redacted>"))
  }

  @Test("symbol names survive sanitizeMessage")
  func symbolsSurvive() {
    let input = "AmazonOrderExport.ExportModel.startExport() threw unexpectedly"
    let result = Scrub.sanitizeMessage(input)
    #expect(result.contains("AmazonOrderExport"))
    #expect(result.contains("ExportModel"))
  }
}
