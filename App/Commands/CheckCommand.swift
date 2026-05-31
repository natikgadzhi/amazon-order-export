import AmazonAuth
import ArgumentParser

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check whether the stored Amazon session is still valid.")

    // No GUI/run-loop: AuthProbe is a plain HTTP request, so this is a normal
    // async CLI command.
    func run() async throws {
        switch await AuthProbe.run(secretStore: KeychainAmazonSecretStore()) {
        case .valid:
            print("authenticated")
        case .expired:
            print("expired — run `authenticate` again")
            throw ExitCode(1)
        case .noStoredSession:
            print("no stored session — run `authenticate` first")
            throw ExitCode(2)
        }
    }
}
