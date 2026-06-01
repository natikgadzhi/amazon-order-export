import Foundation

/// The date range the user exports. Cases map to Amazon's own order-history
/// `timeFilter` query values (the dropdown on the orders page), except
/// `.allTime`, which `ExportService` expands by walking `.year(n)` backward.
/// `Hashable` so it can tag a SwiftUI `Picker`.
public enum TimeRange: Sendable, Equatable, Hashable {
  case last30
  case months3
  case year(Int)
  case allTime

  /// The `timeFilter` query value, or nil for `.allTime` (which has no single
  /// Amazon filter — it's a loop over years).
  public var timeFilter: String? {
    switch self {
    case .last30: return "last30"
    case .months3: return "months-3"
    case .year(let y): return "year-\(y)"
    case .allTime: return nil
    }
  }
}
