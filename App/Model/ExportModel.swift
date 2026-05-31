import AmazonAuth
import AmazonOrders
import Foundation
import Observation

/// What the single window is currently showing.
enum ExportPhase: Equatable {
  case idle
  case verifying  // checking the stored session before committing to the export UI
  case authenticating
  case exporting(ExportProgress)
  case finished(ExportSummary)
  case failed(message: String, canReauth: Bool)
}

/// Coordinates authentication and export for the one window. Thin glue over
/// `AmazonAuthManager` (login + Keychain) and `ExportService` (the crawl).
@MainActor
@Observable
final class ExportModel {
  let authManager: AmazonAuthManager
  var outputDir: URL?
  var range: TimeRange
  var phase: ExportPhase = .idle

  /// `true` while the login sheet should be shown.
  var isAuthenticating: Bool {
    if case .authenticating = phase { return true }
    return false
  }

  private static let outputDirKey = "outputDirPath"

  init(authManager: AmazonAuthManager) {
    self.authManager = authManager
    self.range = .year(Calendar.current.component(.year, from: Date()))
    if let path = UserDefaults.standard.string(forKey: Self.outputDirKey) {
      self.outputDir = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      // Default destination; created at export time if it doesn't exist yet.
      self.outputDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/amazon-orders", isDirectory: true)
    }
    authManager.initSessionFromSecureStorage()
  }

  func setOutputDir(_ url: URL) {
    outputDir = url
    UserDefaults.standard.set(url.path, forKey: Self.outputDirKey)
  }

  /// Primary action. If unauthenticated, show the login sheet first; otherwise
  /// export immediately.
  func authenticateAndExport() {
    guard outputDir != nil else { return }
    if authManager.state == .authenticated {
      startExport()
    } else {
      phase = .authenticating
      authManager.startLogin()
    }
  }

  /// Called by the login sheet when cookies are captured.
  func didAuthenticate() {
    startExport()
  }

  func cancel() {
    // Return to idle immediately for instant feedback; the in-flight render
    // (WKWebView loads aren't interruptible mid-flight) finishes in the
    // background and its task is discarded. Bumping the run generation makes any
    // late callbacks from the cancelled run no-ops, so they can't clobber the UI.
    runGeneration += 1
    exportTask?.cancel()
    exportTask = nil
    phase = .idle
  }

  func reset() {
    phase = .idle
  }

  private var exportTask: Task<Void, Never>?
  /// Identifies the current export run. A cancelled or superseded run keeps its
  /// (now stale) generation, so its late callbacks are ignored.
  private var runGeneration = 0

  private func startExport() {
    exportTask?.cancel()
    runGeneration += 1
    let generation = runGeneration
    guard let outputDir, let secrets = authManager.secrets else {
      phase = .failed(message: "Missing session or output folder.", canReauth: false)
      return
    }
    // Start in `.verifying`: the first page render either succeeds (the first
    // progress event flips us to `.exporting`) or throws `ExpiredSessionError`,
    // which routes straight to the login sheet — so the user never sees an
    // "Exporting…" flash for a dead session.
    phase = .verifying
    exportTask = Task {
      // Only mutate `phase` if this run is still the current one — a run the
      // user cancelled keeps rendering briefly, and must not touch the UI.
      // (`@MainActor` because a nested func is otherwise nonisolated.)
      @MainActor func commit(_ newPhase: ExportPhase) {
        guard generation == runGeneration else { return }
        phase = newPhase
      }
      do {
        let renderer = await OrderPageRenderer(secrets: secrets)
        let service = ExportService(renderer: renderer)
        let summary = try await service.run(range: range, outputDir: outputDir) { progress in
          commit(.exporting(progress))
        }
        commit(.finished(summary))
      } catch is CancellationError {
        commit(.idle)
      } catch is ExpiredSessionError {
        guard generation == runGeneration else { return }
        // Session is dead — go straight to re-login instead of a dead-end screen.
        authManager.reset()
        phase = .authenticating
        authManager.startLogin()
      } catch {
        Telemetry.report(error)
        commit(.failed(message: error.localizedDescription, canReauth: false))
      }
    }
  }
}
