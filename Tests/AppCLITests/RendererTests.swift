import Foundation
import Testing
@testable import AppCLI
@testable import AppCore

@Suite("RendererTests")
struct RendererTests {
  @Test func rendersMachineListWithConnectionFields() {
    let descriptors = MachinesResponse(machines: [
      .local,
      MachineDescriptor(
        id: "remote",
        displayName: "Remote",
        kind: .ssh,
        enabled: false,
        ssh: SSHConnection(host: "example.com", port: 2200, user: "ccusage", identityFile: "/tmp/ccusage-gauge-test-id")
      )
    ])
    let text = MachineRenderer.list(descriptors)
    #expect(text.contains("local"))
    #expect(text.contains("remote  Remote  ssh  disabled  ccusage@example.com:2200"))
  }

  @Test func machineDetailNeverReadsIdentityFileContents() {
    let descriptor = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "h", port: 22, user: "u", identityFile: "/secret/key")
    )
    let text = MachineRenderer.show(descriptor)
    // The path is reported, but only as an opaque reference.
    #expect(text.contains("ssh.identityFile: /secret/key"))
  }

  @Test func rendersBudgetSummary() {
    let json = #"""
    {"activeBoundaryAt":"2026-07-21T00:00:00Z","budgetUSD":100,"overageUSD":0,
     "refreshIntervalSeconds":20,"remainingUSD":40,"resetCycle":"daily","spentUSD":60,
     "usagePercentage":60,"visualFraction":0.6,
     "scope":{"generatedAt":null,"includedMachineIds":["local"],"requested":"all",
              "staleMachineIds":[],"unavailableMachineIds":["remote"]}}
    """#
    let scoped = decode(ScopedResponse<BudgetResponse>.self, from: json)
    let text = DashboardRenderer.budget(scoped)
    #expect(text.contains("spent: $60"))
    #expect(text.contains("budget: $100"))
    #expect(text.contains("remaining: $40"))
    #expect(text.contains("resetCycle: daily"))
    // Partial aggregate scope must surface unavailable machines.
    #expect(text.contains("unavailable=[remote]"))
  }

  @Test func rendersPeriodScope() {
    let json = #"""
    {"range":"today","series":[],"totalUSD":0,
     "scope":{"generatedAt":null,"includedMachineIds":["local"],"requested":"all",
              "staleMachineIds":["stalebox"],"unavailableMachineIds":[]}}
    """#
    let scoped = decode(ScopedResponse<PeriodResponse>.self, from: json)
    let text = DashboardRenderer.period(scoped)
    #expect(text.contains("period today: total=$0 points=0"))
    #expect(text.contains("stale=[stalebox]"))
  }

  private func decode<Value: Decodable>(_ type: Value.Type, from json: String) -> Value {
    // swiftlint:disable:next force_try
    try! DashboardAPIClient.makeDecoder().decode(Value.self, from: Data(json.utf8))
  }
}
