import AppCore
import ArgumentParser
import Foundation

/// Options shared by every client subcommand.
struct ClientOptions: ParsableArguments {
  @Option(name: .customLong("api-port"), help: "Loopback dashboard port. Defaults to the configured dashboardPort.")
  var apiPort: Int?

  @Flag(name: .long, help: "Emit the raw server JSON response without transforming its fields.")
  var json = false

  func validate() throws {
    if let apiPort, !(1...65_535).contains(apiPort) {
      throw ValidationError("Invalid api-port: \(apiPort)")
    }
  }
}

/// A machine-selection option (`--machine <id|all>`), defaulting to the `all`
/// aggregate.
struct MachineOption: ParsableArguments {
  @Option(name: .long, help: "Machine to query: all, local, or a canonical machine id.")
  var machine: MachineSelector = .all
}

// The closed CLI/wire domains are exposed to ArgumentParser here so the parser
// enforces their allowed values. `ArgumentParser` provides `init?(argument:)`
// and `allValueStrings` automatically for `String`-backed `CaseIterable` enums.
extension MachineSelector: ExpressibleByArgument {}
extension DashboardPeriodRange: ExpressibleByArgument {}
extension DashboardAnalyticsRange: ExpressibleByArgument {}
extension DashboardGranularity: ExpressibleByArgument {}

/// A strict `YYYY-MM-DD` calendar day argument.
struct CalendarDay: ExpressibleByArgument, Sendable {
  let text: String

  init?(argument: String) {
    guard CalendarDay.isStrictDay(argument) else { return nil }
    text = argument
  }

  static var defaultValueDescription: String { "YYYY-MM-DD" }

  private static func isStrictDay(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
      return false
    }
    var components = DateComponents()
    components.year = Int(parts[0])
    components.month = Int(parts[1])
    components.day = Int(parts[2])
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar.date(from: components).map { date in
      let normalized = calendar.dateComponents([.year, .month, .day], from: date)
      return normalized.year == components.year
        && normalized.month == components.month
        && normalized.day == components.day
    } ?? false
  }
}
