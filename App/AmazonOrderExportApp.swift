import ArgumentParser
import Foundation

@main
struct AmazonOrderExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amazon-order-export",
        abstract: "Export your own Amazon order and transaction history to CSV.",
        version: "0.1.0",
        subcommands: [AuthenticateCommand.self, CheckCommand.self])

    /// Custom entry point so we can drop the launch arguments Xcode/AppKit inject
    /// (e.g. `-NSDocumentRevisionsDebugMode YES`, `-ApplePersistenceIgnoreState`),
    /// which argument-parser would otherwise reject as unknown options.
    static func main() async {
        do {
            var command = try parseAsRoot(userArguments())
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    private static func userArguments() -> [String] {
        var result: [String] = []
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                _ = iterator.next()  // skip the injected option's value
                continue
            }
            result.append(arg)
        }
        return result
    }
}
