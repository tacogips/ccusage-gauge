import Foundation
import Testing
@testable import AppCore

@Suite("RatioTextTests") struct RatioTextTests {
  @Test func selection() {
    #expect(RatioTextSelection.normalized(rawValues: ["codexWeekly", "bogus", "claudeWeekly", "claudeWeekly"]) == [.claudeWeekly, .codexWeekly])
    #expect(RatioTextSelection.normalized(rawValues: []) == [])
    #expect(RatioTextSelection.toggled(.budget, in: [.budget]) == [])
    #expect(RatioTextSelection.toggled(.codexWeekly, in: []) == [.codexWeekly])
    #expect(RatioTextSelection.toggled(.budget, in: [.codexWeekly]) == [.budget, .codexWeekly])
  }

  @Test func appStateDecoding() throws {
    func decode(_ suffix: String) throws -> AppState {
      try JSONDecoder().decode(AppState.self, from: Data((#"{"resetCycle":{"type":"weekly"}"# + suffix + "}").utf8))
    }
    #expect(try decode("").menuBarRatioLabels == [.budget])
    #expect(try decode(#", "menuBarRatioLabels":[]"#).menuBarRatioLabels == [])
    #expect(try decode(#", "menuBarRatioLabels":["bogus"]"#).menuBarRatioLabels == [])
    #expect(try decode(#", "menuBarRatioLabels":["codexWeekly","claudeWeekly","codexWeekly"]"#).menuBarRatioLabels == [.claudeWeekly, .codexWeekly])
  }

  @Test func appStateRoundTrip() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let store = StateStore(fileURL: file)
    try await store.save(AppState(menuBarRatioLabels: []))
    #expect(try await store.load().menuBarRatioLabels == [])
    let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(object["menuBarRatioLabels"] as? [String] == [])
  }

  @Test func dashboardDecodingAndBounds() throws {
    let prefix = #"{"range":"week","customStart":"2026-07-01","customEnd":"2026-07-17","selectedModels":[],"selectedAgents":[],"granularity":"daily","chartMetric":"inputTokens""#
    let legacy = try JSONDecoder().decode(DashboardUIState.self, from: Data((prefix + "}").utf8))
    #expect(legacy.hiddenPieRatios == [])
    try legacy.validate()
    let state = try JSONDecoder().decode(DashboardUIState.self, from: Data((prefix + #", "hiddenPieRatios":["codexWeekly","x","budget","budget"]}"#).utf8))
    #expect(state.hiddenPieRatios == [.budget, .codexWeekly])
    try state.validate()
    #expect(throws: DashboardStateError.self) { try dashboard(hidden: Array(repeating: .budget, count: 6)).validate() }
  }

  @Test func dashboardRoundTrip() async throws {
    let store = DashboardStateStore(fileURL: try temporaryDirectory().appendingPathComponent("dashboard.sqlite3"))
    let state = dashboard(hidden: [.claudeWeekly])
    try await store.save(state)
    #expect(try await store.load() == state)
  }

  @Test func titlesAndLabels() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func window(_ value: Double) throws -> RateLimitWindow {
      try RateLimitWindow(windowSeconds: 18000, usedPercent: value, resetsAt: nil)
    }
    func provider(_ id: RateLimitProvider, _ status: RateLimitStatus, _ five: RateLimitWindow?, _ weekly: RateLimitWindow?) -> ProviderRateLimits {
      ProviderRateLimits(provider: id, status: status, errorCode: nil, message: nil, planType: nil,
                         fetchedAt: now, stale: false, fiveHour: five, weekly: weekly, otherWindows: [])
    }
    let response = RateLimitsResponse(generatedAt: now, providers: [
      provider(.claude, .ok, try window(58.6), try window(59)),
      provider(.codex, .ok, try window(12), try window(83))
    ])
    for text in ["$12.34 · 45%", "$12.34", "$—", "$!", "$12.34 · 45% !"] {
      #expect(RateLimitDisplayFormatting.statusTitle(selection: [.budget], budgetText: text, response: nil) == text)
    }
    #expect(RateLimitDisplayFormatting.statusTitle(selection: [], budgetText: "$1", response: response) == "")
    #expect(RateLimitDisplayFormatting.statusTitle(selection: [.codexWeekly, .claudeWeekly], budgetText: "$1", response: response) == "Claude W 59% · Codex W 83%")
    #expect(RateLimitDisplayFormatting.statusTitle(selection: [.claude5h], budgetText: "$1", response: nil) == "Claude 5h --")
    let unauthorized = RateLimitsResponse(generatedAt: now, providers: [provider(.claude, .unauthorized, nil, nil)])
    #expect(RateLimitDisplayFormatting.statusTitle(selection: [.claude5h], budgetText: "$1", response: unauthorized) == "Claude 5h --")
    #expect(RateLimitDisplayFormatting.statusTitle(selection: [.budget, .codex5h], budgetText: "$12.34 · 45%", response: response) == "$12.34 · 45% · Codex 5h 12%")
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .budget, in: response) == "")
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .claude5h, in: response) == "Claude 5h 59%")
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .claudeWeekly, in: response) == "Claude W 59%")
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .codex5h, in: response) == "Codex 5h 12%")
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .codexWeekly, in: response) == "Codex W 83%")
    let clamped = RateLimitsResponse(generatedAt: now, providers: [provider(.codex, .ok, nil, try window(120))])
    #expect(RateLimitDisplayFormatting.ratioLabel(for: .codexWeekly, in: clamped) == "Codex W 100%")
  }

  private func dashboard(hidden: [PieChartID]) -> DashboardUIState {
    DashboardUIState(range: "week", customStart: "2026-07-01", customEnd: "2026-07-17",
                     selectedModels: [], selectedAgents: [], granularity: "daily", chartMetric: "inputTokens",
                     hiddenPieRatios: hidden)
  }
}
