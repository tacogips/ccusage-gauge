import ArgumentParser

/// `ccusage-gauge client`
struct ClientCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "client",
    abstract: "Query the running loopback dashboard API on 127.0.0.1.",
    subcommands: [MachinesCommand.self, DashboardCommand.self]
  )
}

/// `ccusage-gauge client machines`
struct MachinesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "machines",
    abstract: "List, show, and add SSH machines.",
    subcommands: [
      MachinesListCommand.self,
      MachinesShowCommand.self,
      MachinesAddCommand.self
    ]
  )
}

/// `ccusage-gauge client dashboard`
struct DashboardCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "dashboard",
    abstract: "Read the same data exposed by the loopback dashboard.",
    subcommands: [
      DashboardBudgetCommand.self,
      DashboardRecentCommand.self,
      DashboardDayCommand.self,
      DashboardPeriodCommand.self,
      DashboardMetricsCommand.self,
      DashboardCostSeriesCommand.self,
      DashboardMachineStatusCommand.self,
      DashboardLoadStatusCommand.self
    ]
  )
}
