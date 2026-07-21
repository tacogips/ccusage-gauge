import AppCore
import ArgumentParser

/// Shared validation for range-bearing dashboard commands.
enum RangeValidation {
  static func validate(isCustom: Bool, start: CalendarDay?, end: CalendarDay?) throws {
    if isCustom {
      guard start != nil, end != nil else {
        throw ValidationError("custom range requires both --start and --end (YYYY-MM-DD)")
      }
    } else if start != nil || end != nil {
      throw ValidationError("--start and --end are only valid with --range custom")
    }
  }
}

/// `ccusage-gauge client dashboard budget`
struct DashboardBudgetCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "budget", abstract: "Show budget status.")

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.budget(machine: machine.machine)
      return RenderedResponse(raw: response.raw, text: DashboardRenderer.budget(response.value))
    }
  }
}

/// `ccusage-gauge client dashboard recent`
struct DashboardRecentCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "recent", abstract: "Show recent cost points.")

  @Option(name: .long, help: "Number of recent points (1...500). Defaults to 48.")
  var limit: Int = 48

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func validate() throws {
    guard (1...500).contains(limit) else {
      throw ValidationError("--limit must be in 1...500")
    }
  }

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.recent(machine: machine.machine, limit: limit)
      return RenderedResponse(raw: response.raw, text: DashboardRenderer.recent(response.value))
    }
  }
}

/// `ccusage-gauge client dashboard day --date <YYYY-MM-DD>`
struct DashboardDayCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "day", abstract: "Show a single day's cost points.")

  @Option(name: .long, help: "Day to query (YYYY-MM-DD).")
  var date: CalendarDay

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.day(machine: machine.machine, date: date.text)
      return RenderedResponse(raw: response.raw, text: DashboardRenderer.day(response.value))
    }
  }
}

/// `ccusage-gauge client dashboard period`
struct DashboardPeriodCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "period", abstract: "Show cost for a period range.")

  @Option(name: .long, help: "Range: today, yesterday, week, month, or custom.")
  var range: DashboardPeriodRange = .today

  @Option(name: .long, help: "Custom range start (YYYY-MM-DD).")
  var start: CalendarDay?

  @Option(name: .long, help: "Custom range end (YYYY-MM-DD).")
  var end: CalendarDay?

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func validate() throws {
    try RangeValidation.validate(isCustom: range.requiresExplicitDates, start: start, end: end)
  }

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.period(machine: machine.machine, range: range, start: start?.text, end: end?.text)
      return RenderedResponse(raw: response.raw, text: DashboardRenderer.period(response.value))
    }
  }
}

/// `ccusage-gauge client dashboard metrics`
struct DashboardMetricsCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "metrics", abstract: "Show metric totals and rows.")

  @Option(name: .long, help: "Range: all, recent12h, today, yesterday, week, month, or custom.")
  var range: DashboardAnalyticsRange = .today

  @Option(name: .long, help: "Custom range start (YYYY-MM-DD).")
  var start: CalendarDay?

  @Option(name: .long, help: "Custom range end (YYYY-MM-DD).")
  var end: CalendarDay?

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func validate() throws {
    try RangeValidation.validate(isCustom: range.requiresExplicitDates, start: start, end: end)
  }

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.metrics(machine: machine.machine, range: range, start: start?.text, end: end?.text)
      return RenderedResponse(raw: response.raw, text: DashboardRenderer.metrics(response.value))
    }
  }
}

/// `ccusage-gauge client dashboard cost-series`
struct DashboardCostSeriesCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "cost-series", abstract: "Show a cost timeline.")

  @Option(name: .long, help: "Range: all, recent12h, today, yesterday, week, month, or custom.")
  var range: DashboardAnalyticsRange = .today

  @Option(name: .long, help: "Granularity: 15min, hourly, 6hour, or daily.")
  var granularity: DashboardGranularity = .hourly

  @Option(name: .long, help: "Custom range start (YYYY-MM-DD).")
  var start: CalendarDay?

  @Option(name: .long, help: "Custom range end (YYYY-MM-DD).")
  var end: CalendarDay?

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func validate() throws {
    try RangeValidation.validate(isCustom: range.requiresExplicitDates, start: start, end: end)
  }

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.costSeries(
        machine: machine.machine,
        range: range,
        granularity: granularity,
        start: start?.text,
        end: end?.text
      )
      return RenderedResponse(raw: response.raw, text: DashboardRenderer.costSeries(response.value))
    }
  }
}

/// `ccusage-gauge client dashboard machine-status`
struct DashboardMachineStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "machine-status", abstract: "Show per-machine collection status.")

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.machineStatus(machine: machine.machine)
      return RenderedResponse(raw: response.raw, text: MachineRenderer.status(response.value))
    }
  }
}

/// `ccusage-gauge client dashboard load-status`
struct DashboardLoadStatusCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "load-status", abstract: "Show per-machine load status.")

  @OptionGroup var machine: MachineOption
  @OptionGroup var options: ClientOptions

  func run() async throws {
    try await ClientRuntime.run(options: options) { client in
      let response = try await client.loadStatus(machine: machine.machine)
      return RenderedResponse(raw: response.raw, text: MachineRenderer.loadStatus(response.value))
    }
  }
}
