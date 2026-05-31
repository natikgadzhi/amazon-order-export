import Foundation

// MARK: - Scrub
//
// Pure, stateless helpers that decide what text is safe to forward to Sentry.
//
// KEY PRINCIPLE: these match value-bearing secrets, NOT type/symbol names.
// Our module is literally named "AmazonOrderExport" and a type is
// "AmazonSessionSecrets"; those strings appear in every crash's stack frames
// and MUST be treated as safe — otherwise we would drop every crash this app
// produces, defeating the feature entirely.
//
// Every detector below targets a precise encoding (hex run, base64 with
// structural chars, JWT prefix, Atza| cookie, Bearer header, x-amz- header,
// amazon.com URL) rather than a fuzzy heuristic, so word-like identifiers
// (SHA256, Base64Decoder, OAuth2SessionManager) and UUIDs are naturally
// excluded.

public enum Scrub {

  // MARK: - redactHomePaths

  /// Rewrite home-dir paths so the username (PII) doesn't leak.
  /// `/Users/<name>/…` and `Users/<name>/…` → `/Users/<redacted>/…`.
  /// A leading `~` alone is NOT treated as a path and is left unchanged.
  public static func redactHomePaths(_ s: String) -> String {
    // Match both `/Users/<segment>/` (absolute) and `Users/<segment>/`
    // appearing mid-string (e.g. log lines that omit the leading slash).
    // `\b` prevents matching inside longer words.
    // The replacement always uses the slash-prefixed canonical form.
    guard let re = try? NSRegularExpression(pattern: #"/?(?<!\w)Users/[^/\s]+/"#) else {
      return s
    }
    return re.stringByReplacingMatches(
      in: s,
      range: NSRange(s.startIndex..., in: s),
      withTemplate: "/Users/<redacted>/")
  }

  // MARK: - containsSecretValue

  /// True iff the string carries a value-bearing secret we must not send:
  /// - a URL whose host is (or ends in) `amazon.com` (case-insensitive),
  /// - an `Atza|…` Amazon session cookie value,
  /// - a `Bearer <token>` (case-insensitive),
  /// - an `x-amz-…` substring,
  /// - a contiguous hex run of ≥ 16 hex chars (catches 40-char hashes/tokens;
  ///   UUID hyphens break runs to ≤ 12, so UUIDs are excluded),
  /// - a base64 run of ≥ 24 chars that contains at least one of `+ / =`
  ///   (structural chars never appear in plain identifiers),
  /// - a JWT (`eyJ` followed by base64url chars).
  ///
  /// This matches VALUES, NOT symbol names like
  /// `AmazonOrderExport.ExportModel.start` or the `AmazonSessionSecrets` type.
  public static func containsSecretValue(_ s: String) -> Bool {
    containsAmazonURL(s)
      || containsAtzaCookie(s)
      || containsBearerToken(s)
      || containsXAmzValue(s)
      || containsHexToken(s)
      || containsBase64Token(s)
      || containsJWT(s)
  }

  // MARK: - sanitizeMessage

  /// Sanitize a value-bearing free-text field (e.g. an exception message):
  /// 1. redact home paths,
  /// 2. replace any URL with just `scheme://host`,
  /// 3. replace any Atza| cookie, Bearer token, x-amz value, or blob with
  ///    `<redacted>`.
  public static func sanitizeMessage(_ s: String) -> String {
    var result = redactHomePaths(s)
    result = redactURLsToSchemeHost(result)
    result = redactTokenBlobs(result)
    return result
  }
}

// MARK: - Private helpers

extension Scrub {

  // MARK: amazon.com URL detection

  // Known trade-off (MINOR-1): a TLS/cert error message that mentions
  // amazon.com (e.g. "certificate mismatch for amazon.com") will cause the
  // entire event to be dropped. This fail-closed behaviour is intentional —
  // the cert error itself is benign, and we accept losing that diagnostic
  // rather than risk leaking navigation context.
  private static func containsAmazonURL(_ s: String) -> Bool {
    // Use NSDataDetector to find URLs, then inspect their hosts
    // with case-insensitive comparison (CRITICAL-2).
    guard
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    else {
      // Fallback: regex for obvious amazon.com URLs (case-insensitive).
      return s.range(
        of: #"https?://[^/\s]*\.?amazon\.com"#,
        options: [.regularExpression, .caseInsensitive]) != nil
    }
    let range = NSRange(s.startIndex..., in: s)
    let matches = detector.matches(in: s, range: range)
    return matches.contains { match in
      guard let url = match.url, let host = url.host else { return false }
      let lower = host.lowercased()
      return lower == "amazon.com" || lower.hasSuffix(".amazon.com")
    }
  }

  // MARK: Atza| session cookie detection (CRITICAL-1)
  //
  // Amazon session cookies (at-main, sess-at-main, x-main) are formatted
  // `Atza|IQEB…`. The `|` separator breaks generic blob detectors, so we
  // match it explicitly.

  private static func containsAtzaCookie(_ s: String) -> Bool {
    s.range(of: #"(?i)Atza\|\S+"#, options: .regularExpression) != nil
  }

  // MARK: Bearer token detection

  private static func containsBearerToken(_ s: String) -> Bool {
    s.range(
      of: #"(?i)\bBearer\s+\S+"#,
      options: .regularExpression) != nil
  }

  // MARK: x-amz header detection

  private static func containsXAmzValue(_ s: String) -> Bool {
    s.range(
      of: #"(?i)x-amz-"#,
      options: .regularExpression) != nil
  }

  // MARK: Hex token detection (IMPORTANT-1/3)
  //
  // A contiguous run of [0-9a-fA-F] with length ≥ 16 is treated as a secret.
  // This naturally excludes:
  //   - UUIDs: hyphens break the run into segments of ≤ 12 chars.
  //   - Word-like identifiers (SHA256, OAuth2): letters like S, H, O, t, h, A,
  //     u are not hex chars, so the run ends at the first non-hex letter.

  private static func containsHexToken(_ s: String) -> Bool {
    s.range(
      of: #"[0-9a-fA-F]{16,}"#,
      options: .regularExpression) != nil
  }

  // MARK: Base64 token detection (IMPORTANT-1/3)
  //
  // A run from [A-Za-z0-9+/=] of length ≥ 24 that contains at least one of
  // the structural base64 chars (+, /, =) is a secret. Plain Swift identifiers
  // never contain +, /, or =, so this exclusively matches encoded data.

  private static func containsBase64Token(_ s: String) -> Bool {
    // Find all runs of base64 alphabet chars with length ≥ 24.
    guard let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/=]{24,}"#) else {
      return false
    }
    let ns = s as NSString
    let range = NSRange(location: 0, length: ns.length)
    let matches = re.matches(in: s, range: range)
    return matches.contains { match in
      let token = ns.substring(with: match.range)
      // Require at least one structural base64 char to distinguish from
      // long plain-text identifier runs.
      return token.contains("+") || token.contains("/") || token.contains("=")
    }
  }

  // MARK: JWT detection (IMPORTANT-1/3)
  //
  // JWTs start with `eyJ` (base64url of `{"`) followed by base64url chars.

  private static func containsJWT(_ s: String) -> Bool {
    s.range(
      of: #"eyJ[A-Za-z0-9_\-]+"#,
      options: .regularExpression) != nil
  }

  // MARK: URL → scheme://host replacement (for sanitizeMessage)

  private static func redactURLsToSchemeHost(_ s: String) -> String {
    guard
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    else {
      return s
    }
    let ns = s as NSString
    let range = NSRange(location: 0, length: ns.length)
    let matches = detector.matches(in: s, range: range)
    // Replace from the end so ranges stay valid.
    var result = s
    for match in matches.reversed() {
      guard let url = match.url,
        let scheme = url.scheme,
        let host = url.host,
        let matchRange = Range(match.range, in: result)
      else { continue }
      result.replaceSubrange(matchRange, with: "\(scheme)://\(host)")
    }
    return result
  }

  // MARK: Token blob / Bearer / Atza| / x-amz replacement (for sanitizeMessage)

  private static func redactTokenBlobs(_ s: String) -> String {
    var result = s

    // Redact Atza| session cookies (CRITICAL-1).
    if let re = try? NSRegularExpression(pattern: #"(?i)Atza\|\S+"#) {
      result = re.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "<redacted>")
    }

    // Redact Bearer tokens.
    if let re = try? NSRegularExpression(pattern: #"(?i)Bearer\s+\S+"#) {
      result = re.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "<redacted>")
    }

    // Redact x-amz-* header lines: everything after the colon.
    if let re = try? NSRegularExpression(pattern: #"(?i)(x-amz-[^\s:]*:\s*)\S+"#) {
      result = re.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "$1<redacted>")
    }

    // Redact base64 tokens: runs ≥ 24 chars containing + / =.
    if let re = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/=]{24,}"#) {
      let ns = result as NSString
      let matches = re.matches(in: result, range: NSRange(location: 0, length: ns.length))
      for match in matches.reversed() {
        let token = ns.substring(with: match.range)
        guard token.contains("+") || token.contains("/") || token.contains("="),
          let range = Range(match.range, in: result)
        else { continue }
        result.replaceSubrange(range, with: "<redacted>")
      }
    }

    // Redact hex tokens: contiguous runs of ≥ 16 hex chars.
    if let re = try? NSRegularExpression(pattern: #"[0-9a-fA-F]{16,}"#) {
      result = re.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "<redacted>")
    }

    // Redact JWT tokens.
    if let re = try? NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_\-]+"#) {
      result = re.stringByReplacingMatches(
        in: result,
        range: NSRange(result.startIndex..., in: result),
        withTemplate: "<redacted>")
    }

    return result
  }
}
