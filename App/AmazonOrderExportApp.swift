import ArgumentParser

@main
struct AmazonOrderExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "amazon-order-export",
        abstract: "Export your own Amazon order and transaction history to CSV.",
        version: "0.1.0",
        subcommands: []
    )
}
