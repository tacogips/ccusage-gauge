import AppCore
import ArgumentParser
import Testing
@testable import AppCLI

@Suite("CommandParsingTests")
struct CommandParsingTests {
  @Test func parsesVersionConfiguration() {
    #expect(RootCommand.configuration.version == Version.current)
    #expect(RootCommand.configuration.commandName == "ccusage-gauge")
  }

  @Test func generatedHelpDocumentsClientFeatures() {
    #expect(RootCommand.helpMessage().contains("client"))
    #expect(ClientCommand.helpMessage().contains("machines"))
    #expect(ClientCommand.helpMessage().contains("dashboard"))
    #expect(MachinesAddCommand.helpMessage().contains("--identity-file"))
    #expect(MachinesAddCommand.helpMessage().contains("--proxy-jump-host"))
    #expect(MachinesAddCommand.helpMessage().contains("--proxy-command-executable"))
    #expect(MachinesAddCommand.helpMessage().contains("contents are never read"))
    #expect(MachinesCommand.helpMessage().contains("test-connection"))
    #expect(MachinesCommand.helpMessage().contains("refresh"))
    #expect(DashboardCommand.helpMessage().contains("cost-series"))
    #expect(DashboardCommand.helpMessage().contains("machine-status"))
  }

  @Test func parsesServeOptions() throws {
    let command = try RootCommand.parseAsRoot(["serve", "--port", "19090", "--assets", "/tmp/web"])
    let serve = try #require(command as? ServeCommand)
    #expect(serve.port == 19_090)
    #expect(serve.assets == "/tmp/web")
  }

  @Test func rejectsInvalidServePort() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["serve", "--port", "0"])
    }
  }

  @Test func parsesUsageSnapshotJSONFlag() throws {
    let command = try RootCommand.parseAsRoot(["usage-snapshot", "--json"])
    let snapshot = try #require(command as? UsageSnapshotCommand)
    #expect(snapshot.json)
  }

  @Test func parsesConfigCheck() throws {
    let command = try RootCommand.parseAsRoot(["config-check"])
    #expect(command is ConfigCheckCommand)
  }

  @Test func rejectsUnknownCommand() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["dashboard"])
    }
  }

  @Test func parsesMachinesAddWithDefaults() throws {
    let command = try RootCommand.parseAsRoot(["client", "machines", "add", "remote", "--host", "example.com", "--user", "ccusage"])
    let add = try #require(command as? MachinesAddCommand)
    #expect(add.id == "remote")
    #expect(add.host == "example.com")
    #expect(add.user == "ccusage")
    #expect(add.sshPort == 22)
    #expect(add.remoteCcusagePath == "ccusage")
    #expect(add.disabled == false)
    #expect(add.displayName == nil)
  }

  @Test func parsesMachinesAddRepeatedOptions() throws {
    let command = try RootCommand.parseAsRoot([
      "client", "machines", "add", "remote",
      "--host", "example.com", "--user", "ccusage",
      "--ssh-port", "2200", "--display-name", "Remote",
      "--identity-file", "/tmp/ccusage-gauge-test-id",
      "--ssh-option=-4", "--ssh-option=-o ConnectTimeout=10",
      "--remote-ccusage-path", "/usr/local/bin/ccusage", "--disabled"
    ])
    let add = try #require(command as? MachinesAddCommand)
    #expect(add.sshPort == 2200)
    #expect(add.displayName == "Remote")
    #expect(add.identityFile == "/tmp/ccusage-gauge-test-id")
    #expect(add.sshOptions == ["-4", "-o ConnectTimeout=10"])
    #expect(add.disabled)
  }

  @Test func parsesStructuredProxyAndActionCommands() throws {
    let jump = try #require(RootCommand.parseAsRoot([
      "client", "machines", "add", "remote",
      "--host", "target.example", "--user", "target",
      "--proxy-jump-host", "jump.example", "--proxy-jump-user", "jump",
      "--proxy-jump-port", "2200",
      "--proxy-jump-known-hosts-file", "/tmp/known-hosts"
    ]) as? MachinesAddCommand)
    #expect(jump.proxyJumpHost == "jump.example")
    #expect(jump.proxyJumpUser == "jump")
    #expect(jump.proxyJumpPort == 2200)
    #expect(jump.proxyJumpKnownHostsFile == "/tmp/known-hosts")

    let test = try RootCommand.parseAsRoot(["client", "machines", "test-connection", "remote"])
    let refresh = try RootCommand.parseAsRoot(["client", "machines", "refresh", "remote"])
    #expect(test is MachinesTestConnectionCommand)
    #expect(refresh is MachinesRefreshCommand)
  }

  @Test func rejectsConflictingOrIncompleteProxyOptions() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot([
        "client", "machines", "add", "remote",
        "--host", "target.example", "--user", "target",
        "--proxy-jump-host", "jump.example",
        "--proxy-command-executable", "/usr/local/bin/tunnel"
      ])
    }
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot([
        "client", "machines", "add", "remote",
        "--host", "target.example", "--user", "target",
        "--proxy-jump-host", "jump.example"
      ])
    }
  }

  @Test func rejectsMissingRequiredHost() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "machines", "add", "remote", "--user", "ccusage"])
    }
  }

  @Test func rejectsUnsafeOrReservedMachineIDs() {
    for id in ["../budget", "all"] {
      #expect(throws: (any Error).self) {
        _ = try RootCommand.parseAsRoot(["client", "machines", "show", id])
      }
    }
    for id in ["../budget", "all", "local"] {
      #expect(throws: (any Error).self) {
        _ = try RootCommand.parseAsRoot([
          "client", "machines", "add", id, "--host", "example.com", "--user", "ccusage"
        ])
      }
    }
  }

  @Test func rejectsInvalidSSHPort() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "machines", "add", "remote", "--host", "h", "--user", "u", "--ssh-port", "70000"])
    }
  }

  @Test func parsesMachineSelectorValues() throws {
    let all = try #require(RootCommand.parseAsRoot(["client", "dashboard", "budget"]) as? DashboardBudgetCommand)
    #expect(all.machine.machine == .all)
    let local = try #require(RootCommand.parseAsRoot(["client", "dashboard", "budget", "--machine", "local"]) as? DashboardBudgetCommand)
    #expect(local.machine.machine == .local)
    let id = try #require(RootCommand.parseAsRoot(["client", "dashboard", "budget", "--machine", "remote"]) as? DashboardBudgetCommand)
    #expect(id.machine.machine == .machine("remote"))
  }

  @Test func rejectsInvalidMachineSelector() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "budget", "--machine", "Not_Canonical"])
    }
  }

  @Test func enforcesRecentLimitBounds() throws {
    let ok = try #require(RootCommand.parseAsRoot(["client", "dashboard", "recent", "--limit", "500"]) as? DashboardRecentCommand)
    #expect(ok.limit == 500)
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "recent", "--limit", "501"])
    }
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "recent", "--limit", "0"])
    }
  }

  @Test func enforcesStrictDate() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "day", "--date", "2026-7-1"])
    }
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "day", "--date", "2026-13-01"])
    }
  }

  @Test func parsesStrictDate() throws {
    let command = try #require(RootCommand.parseAsRoot(["client", "dashboard", "day", "--date", "2026-07-21"]) as? DashboardDayCommand)
    #expect(command.date.text == "2026-07-21")
  }

  @Test func customRangeRequiresBothDates() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "period", "--range", "custom"])
    }
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "period", "--range", "custom", "--start", "2026-07-01"])
    }
  }

  @Test func nonCustomRangeRejectsDates() {
    #expect(throws: (any Error).self) {
      _ = try RootCommand.parseAsRoot(["client", "dashboard", "metrics", "--range", "today", "--start", "2026-07-01"])
    }
  }

  @Test func parsesCustomRangeWithDates() throws {
    let command = try #require(RootCommand.parseAsRoot([
      "client", "dashboard", "metrics", "--range", "custom", "--start", "2026-07-01", "--end", "2026-07-17"
    ]) as? DashboardMetricsCommand)
    #expect(command.range == .custom)
    #expect(command.start?.text == "2026-07-01")
    #expect(command.end?.text == "2026-07-17")
  }

  @Test func parsesGranularityWireValues() throws {
    let command = try #require(RootCommand.parseAsRoot([
      "client", "dashboard", "cost-series", "--granularity", "15min"
    ]) as? DashboardCostSeriesCommand)
    #expect(command.granularity == .min15)
    #expect(command.granularity.rawValue == "15min")
  }
}

@Suite("ExitStatusTests")
struct ExitStatusTests {
  @Test func mapsClientErrorsToDocumentedStatuses() {
    #expect(ClientRuntime.exitStatus(for: .unreachable("x")) == 3)
    #expect(ClientRuntime.exitStatus(for: .decoding("x")) == 1)
    #expect(ClientRuntime.exitStatus(for: .api(DashboardAPIError(httpStatus: 404, code: "not_found", message: "m"))) == 4)
    #expect(ClientRuntime.exitStatus(for: .api(DashboardAPIError(httpStatus: 503, code: "unavailable", message: "m"))) == 5)
  }

  @Test func mapsEntryPointFailuresToDocumentedStatuses() {
    struct RuntimeFailure: Error {}

    // Help and version requests are clean exits.
    #expect(RootCommand.terminationStatus(for: CleanExit.helpRequest(RootCommand.self)) == 0)
    // Usage and validation errors exit 2.
    do {
      _ = try RootCommand.parseAsRoot(["no-such-command"])
      Issue.record("Expected a usage error")
    } catch {
      #expect(RootCommand.terminationStatus(for: error) == 2)
    }
    do {
      _ = try RootCommand.parseAsRoot(["serve", "--port", "0"])
      Issue.record("Expected a validation error")
    } catch {
      #expect(RootCommand.terminationStatus(for: error) == 2)
    }
    // Any other runtime failure exits 1, never the usage status.
    #expect(RootCommand.terminationStatus(for: RuntimeFailure()) == 1)
  }
}
