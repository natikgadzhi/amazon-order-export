import Foundation

/// A price string scraped from Amazon, e.g. `"$29.83"` or `"-$1.50"`.
///
/// We keep the `raw` text verbatim (so a human reviewing the CSV can always see
/// exactly what Amazon showed) alongside a best-effort parsed `amount`. Parsing
/// is intentionally lenient: strip everything that isn't a digit, dot, or minus.
public struct Money: Equatable, Sendable {
    public let raw: String
    public let amount: Decimal?

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.raw = trimmed
        let kept = trimmed.filter { $0.isNumber || $0 == "." || $0 == "-" }
        self.amount = kept.isEmpty ? nil : Decimal(string: kept)
    }
}
