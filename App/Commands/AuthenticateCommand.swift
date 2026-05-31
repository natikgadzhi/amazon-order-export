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
    // Blocks in the AppKit run loop; returns only when the app terminates
    // (which LoginWindowContent triggers on successful auth).
    AppRunLoop.runLogin(manager: manager)
  }
}
