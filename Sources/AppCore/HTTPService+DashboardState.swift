import Foundation

extension DashboardRouter {
  func dashboardStateResponse(
    path: String,
    method: String,
    body: Data
  ) async -> HTTPResponse? {
    guard path == "/api/dashboard-state" else { return nil }
    guard let dashboardStateStore else {
      return errorResponse(
        status: 503,
        code: "state_unavailable",
        message: "Dashboard state storage is unavailable"
      )
    }
    do {
      if method == "PUT" {
        let state = try JSONDecoder().decode(DashboardUIState.self, from: body)
        try await dashboardStateStore.save(state)
        return json(["status": "ok"])
      }
      return json(DashboardUIStateResponse(state: try await dashboardStateStore.load()))
    } catch DashboardStateError.invalidState {
      return errorResponse(
        status: 400,
        code: "invalid_dashboard_state",
        message: "Dashboard state is invalid"
      )
    } catch is DecodingError {
      return errorResponse(
        status: 400,
        code: "invalid_dashboard_state",
        message: "Dashboard state is invalid"
      )
    } catch {
      return errorResponse(
        status: 503,
        code: "state_unavailable",
        message: "Dashboard state storage is unavailable"
      )
    }
  }
}
