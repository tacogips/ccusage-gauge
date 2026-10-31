import Foundation
import Testing
@testable import AppCore

@Suite("PieChartSelectionTests") struct PieChartSelectionTests {
  @Test func normalizesAndToggles() {
    #expect(PieChartSelection.normalized(rawValues: ["codexWeekly", "bogus", "claude5h", "claude5h"]) == [.claude5h, .codexWeekly])
    #expect(PieChartSelection.normalized(rawValues: []) == [.budget])
    #expect(PieChartSelection.toggled(.budget, in: [.budget]) == [.budget])
    #expect(PieChartSelection.toggled(.codex5h, in: [.budget]) == [.budget, .codex5h])
    #expect(PieChartSelection.toggled(.budget, in: [.budget, .codex5h]) == [.codex5h])
  }

  @Test func legacyAndNormalizedAppState() throws {
    let legacy = try JSONDecoder().decode(AppState.self, from: Data(#"{"budgetUSD":50,"resetCycle":{"type":"weekly"}}"#.utf8))
    #expect(legacy.budgetUSD == 50)
    #expect(legacy.resetCycle == .weekly)
    #expect(legacy.menuBarPieCharts == [.budget])
    let json = #"{"resetCycle":{"type":"weekly"},"menuBarPieCharts":["codexWeekly","bogus","claude5h","claude5h"]}"#
    let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
    #expect(state.menuBarPieCharts == [.claude5h, .codexWeekly])
    let empty = try JSONDecoder().decode(AppState.self, from: Data(#"{"resetCycle":{"type":"weekly"},"menuBarPieCharts":[]}"#.utf8))
    #expect(empty.menuBarPieCharts == [.budget])
  }

  @Test func appStateStoreRoundTrip() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let store = StateStore(fileURL: file)
    let state = AppState(budgetUSD: 50, resetCycle: .weekly, menuBarPieCharts: [.budget, .codex5h])
    try await store.save(state)
    #expect(try await store.load() == state)
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["menuBarPieCharts"] as? [String] == ["budget", "codex5h"])
  }

  @Test func legacyAndNormalizedDashboardState() throws {
    let prefix = #"{"range":"week","customStart":"2026-07-01","customEnd":"2026-07-17","selectedModels":[],"selectedAgents":[],"granularity":"daily","chartMetric":"inputTokens""#
    let legacy = try JSONDecoder().decode(DashboardUIState.self, from: Data((prefix + "}").utf8))
    #expect(legacy.pieCharts == [.budget])
    try legacy.validate()
    let state = try JSONDecoder().decode(DashboardUIState.self, from: Data((prefix + #", "pieCharts":["claudeWeekly","budget","bogus","budget"]}"#).utf8))
    #expect(state.pieCharts == [.budget, .claudeWeekly])
    try state.validate()
  }

  @Test func dashboardStoreRoundTripAndBounds() async throws {
    let file = try temporaryDirectory().appendingPathComponent("dashboard.sqlite3")
    let store = DashboardStateStore(fileURL: file)
    let state = dashboardState(pieCharts: [.budget, .claudeWeekly])
    try await store.save(state)
    #expect(try await store.load() == state)
    #expect(throws: DashboardStateError.self) { try dashboardState(pieCharts: []).validate() }
    #expect(throws: DashboardStateError.self) { try dashboardState(pieCharts: Array(repeating: .budget, count: 6)).validate() }
  }
}

private func dashboardState(pieCharts: [PieChartID]) -> DashboardUIState {
  DashboardUIState(
    range: "week", customStart: "2026-07-01", customEnd: "2026-07-17",
    selectedModels: [], selectedAgents: [], granularity: "daily", chartMetric: "inputTokens", pieCharts: pieCharts
  )
}
