import Foundation
import Sentry
import TelemetryScrub

/// The one and only place this app talks to Sentry. Everything outbound goes
/// through here, so a reviewer reads one file to know what can ever leave the
/// machine. Crash reports only — no analytics, no breadcrumbs, no user/install id.
@MainActor
enum Telemetry {
  static let enabledKey = "telemetry.crashReportsEnabled"

  /// Absent ⇒ ON (opt-out default).
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  /// Call once at launch. No-op (the SDK never starts) when disabled or when no
  /// DSN was baked into the build (open-source/local builds ship an empty DSN).
  static func start() {
    guard isEnabled else { return }
    guard let dsn = Bundle.main.infoDictionary?["SENTRY_DSN"] as? String, !dsn.isEmpty
    else { return }
    SentrySDK.start { options in configure(options, dsn: dsn) }
  }

  /// The ONLY way the rest of the app sends anything. No-op if start() didn't run.
  ///
  /// Note: `guard isEnabled` only gates explicit `report(_:)` calls. Once the SDK
  /// is started (in `start()`), the crash handler remains active until the app is
  /// relaunched — toggling telemetry off takes effect on next launch, not mid-run.
  static func report(_ error: Error) {
    guard isEnabled else { return }
    SentrySDK.capture(error: error)
  }

  nonisolated private static func configure(_ options: Options, dsn: String) {
    options.dsn = dsn
    #if DEBUG
      options.environment = "development"
    #else
      options.environment = "production"
    #endif

    // Performance + auto-instrumentation: fully OFF — these are the accidental
    // data channels (perf spans record URLs, network breadcrumbs record requests).
    options.tracesSampleRate = 0
    options.enableSwizzling = false
    options.enableAutoBreadcrumbTracking = false
    options.enableNetworkBreadcrumbs = false
    options.enableNetworkTracking = false
    options.enableCaptureFailedRequests = false
    options.enableAutoSessionTracking = false
    options.enableSpotlight = false

    // note: attachScreenshot and attachViewHierarchy are declared under
    // #if SENTRY_UIKIT_AVAILABLE (iOS/tvOS/visionOS only) and therefore do not
    // exist in a macOS build. Both default to NO on every platform, so no action
    // is needed here; the comment records the intent for future reviewers.

    options.sendDefaultPii = false

    // Drop ALL breadcrumbs, belt-and-suspenders over the toggles above.
    options.beforeBreadcrumb = { _ in nil }

    // The scrub: last line of defense on every event we send.
    // scrub is nonisolated so it is safe to call from this SDK-managed closure.
    options.beforeSend = { event in scrub(event) }
  }

  // MARK: - scrub(_:)
  //
  // Runs on every outgoing event (crashes + explicit report(_:) calls).
  // Uses TelemetryScrub for ALL string decisions — no new pattern logic here.
  //
  // KEY INVARIANT: we redact VALUE-BEARING fields only. Stack-frame symbol names
  // (function/module/package) are safe and must NOT be treated as secrets —
  // our module is literally named "AmazonOrderExport" and types include
  // "AmazonSessionSecrets". Touching those would drop every crash this app
  // produces and defeat the feature entirely.
  //
  // Field walking:
  //   event.request          → nil (URL, headers, cookies, query, body)
  //   event.message          → replace with sanitized SentryMessage (formatted is
  //                            readonly, so we construct a new Message object)
  //   exception.value        → sanitized in-place (mutable NSString copy property)
  //   frame.fileName         → redactHomePaths (contains /Users/<username>/…;
  //                            NOT sanitizeMessage — filenames have no tokens)
  //   frame.function/module/package → untouched (safe symbol names)
  //
  // Fail-closed backstop: if any value-bearing field still triggers
  // Scrub.containsSecretValue after sanitization, the whole event is dropped.

  nonisolated private static func redactFrameFileNames(_ frames: [Frame]?) {
    guard let frames else { return }
    for frame in frames where frame.fileName != nil {
      frame.fileName = Scrub.redactHomePaths(frame.fileName!)
    }
  }

  nonisolated private static func scrub(_ event: Event) -> Event? {
    // 1. Drop request data unconditionally (URL, headers, query, body, cookies).
    event.request = nil

    // Defensive: clear fields we never set but that could carry PII if a future
    // SDK version or scope change populates them automatically.
    event.user = nil  // we never set a user; sendDefaultPii=false too. Defensive.
    event.extra = nil  // we never set extra context. Defensive.
    event.breadcrumbs = nil  // beforeBreadcrumb already drops all; belt-and-suspenders.
    // event.context is intentionally kept — it carries OS version + app version,
    // which we send deliberately (see "What leaves your Mac" in the design doc).

    // 2. Sanitize the event message (value-bearing free text).
    if let msg = event.message {
      // formatted is readonly; build a fresh SentryMessage from the sanitized text.
      let sanitized = Scrub.sanitizeMessage(msg.formatted)
      event.message = SentryMessage(formatted: sanitized)
      // Also sanitize the optional raw template string if present.
      if let raw = event.message?.message {
        event.message?.message = Scrub.sanitizeMessage(raw)
      }
    }

    // 3. Sanitize each exception's value (the human-readable error description).
    //    Leave exception.type and .module alone — those are class/symbol names.
    if let exceptions = event.exceptions {
      for exception in exceptions {
        exception.value = Scrub.sanitizeMessage(exception.value)
        // Redact home-dir paths in every frame filename; leave function/module/package.
        redactFrameFileNames(exception.stacktrace?.frames)
      }
    }

    // Also walk a top-level stacktrace if present (e.g. on message events).
    redactFrameFileNames(event.stacktrace?.frames)

    // Walk thread stacktraces — crash/app-hang events put frames here too.
    if let threads = event.threads {
      for thread in threads {
        redactFrameFileNames(thread.stacktrace?.frames)
      }
    }

    // 4. Fail-closed backstop: drop the event if any value-bearing field still
    //    contains a recognizable secret after sanitization.
    if let msg = event.message {
      if Scrub.containsSecretValue(msg.formatted) { return nil }
      if let raw = msg.message, Scrub.containsSecretValue(raw) { return nil }
    }
    if let exceptions = event.exceptions {
      for exception in exceptions {
        if Scrub.containsSecretValue(exception.value) { return nil }
      }
    }

    return event
  }
}
