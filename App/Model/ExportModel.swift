import AmazonAuth
import AmazonOrders
import Foundation
import Observation

/// What the single window is currently showing.
enum ExportPhase: Equatable {
  case idle
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
    exportTask?.cancel()
  }

  func reset() {
    phase = .idle
  }

  private var exportTask: Task<Void, Never>?

  private func startExport() {
    exportTask?.cancel()  // Cancel any in-flight export before starting a new one.
    guard let outputDir, let secrets = authManager.secrets else {
      phase = .failed(message: "Missing session or output folder.", canReauth: false)
      return
    }
    phase = .exporting(.fetchingOrders(collected: 0))
    exportTask = Task {
      do {
        let renderer = await OrderPageRenderer(secrets: secrets)
        let service = ExportService(renderer: renderer)
        let summary = try await service.run(range: range, outputDir: outputDir) { progress in
          self.phase = .exporting(progress)
        }
        phase = .finished(summary)
      } catch is CancellationError {
        phase = .idle
      } catch is ExpiredSessionError {
        authManager.reset()
        phase = .failed(message: "Your Amazon session expired.", canReauth: true)
      } catch {
        phase = .failed(message: error.localizedDescription, canReauth: false)
      }
    }
  }
}
