import Foundation
import Testing
@testable import AppCore

@Suite("DashboardUIStateFoldEffortTests") struct DashboardUIStateFoldEffortTests {
  @Test func decodesAndValidatesLegacyStateWithExpandedFoldDefaults() throws {
    let json = #"{"range":"week","customStart":"2026-07-01","customEnd":"2026-07-17","selectedModels":["gpt-5"],"selectedAgents":["codex"],"granularity":"daily","chartMetric":"inputTokens"}"#

    let state = try JSONDecoder().decode(DashboardUIState.self, from: Data(json.utf8))

    #expect(state.stackBy == "model")
    #expect(state.sidebarCollapsed == false)
    #expect(state.headerCollapsed == false)
    try state.validate()
  }

  @Test func decodesAndValidatesModelEffortStackMode() throws {
    let json = #"{"range":"week","customStart":"2026-07-01","customEnd":"2026-07-17","selectedModels":[],"selectedAgents":[],"granularity":"daily","chartMetric":"inputTokens","stackBy":"modelEffort"}"#

    let state = try JSONDecoder().decode(DashboardUIState.self, from: Data(json.utf8))

    #expect(state.stackBy == "modelEffort")
    try state.validate()
  }

  @Test func coercesUnknownStackModeToModel() throws {
    let json = #"{"range":"week","customStart":"2026-07-01","customEnd":"2026-07-17","selectedModels":[],"selectedAgents":[],"granularity":"daily","chartMetric":"inputTokens","stackBy":"bogus"}"#

    let state = try JSONDecoder().decode(DashboardUIState.self, from: Data(json.utf8))

    #expect(state.stackBy == "model")
  }

  @Test func roundTripsModelEffortAndFoldStateThroughStore() async throws {
    let file = try temporaryDirectory().appendingPathComponent("cache/dashboard-state.sqlite3")
    let store = DashboardStateStore(fileURL: file)
    let state = DashboardUIState(
      range: "week",
      customStart: "2026-07-01",
      customEnd: "2026-07-17",
      selectedModels: ["gpt-5"],
      selectedAgents: ["codex"],
      granularity: "daily",
      chartMetric: "inputTokens",
      stackBy: "modelEffort",
      sidebarCollapsed: true,
      headerCollapsed: true
    )

    try await store.save(state)

    #expect(try await store.load() == state)
  }

  @Test func encodesFalseFoldFlags() throws {
    let data = try JSONEncoder().encode(makeDefaultState())
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["sidebarCollapsed"] as? Bool == false)
    #expect(object["headerCollapsed"] as? Bool == false)
  }
}

private func makeDefaultState() -> DashboardUIState {
  DashboardUIState(
    range: "week",
    customStart: "2026-07-01",
    customEnd: "2026-07-17",
    selectedModels: [],
    selectedAgents: [],
    granularity: "daily",
    chartMetric: "inputTokens"
  )
}
