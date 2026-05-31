import AmazonAuth
import ArgumentParser
import Foundation

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check whether the stored Amazon session is still valid.")

    @MainActor
    func run() async throws {
        let store = KeychainAmazonSecretStore()
        // Fast path: when there's nothing stored we can answer without spinning up
        // AppKit/WebKit — keeps `check` scriptable in a plain shell. Only the
        // valid/expired probe needs a real WebView (and a GUI session).
        guard store.read() != nil else {
            print("no stored session — run `authenticate` first")
            Foundation.exit(2)
        }
        AppRunLoop.runHeadless {
            switch await AuthProbe.run(secretStore: store) {
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
