import Foundation

extension DashboardRouter {
  func directoryNameMutationResponse(
    path: String,
    method: String,
    headers: [String: String],
    body: Data,
    listenerPort: Int
  ) async -> HTTPResponse? {
    guard path == "/api/subdirectories/name" else { return nil }
    if method == "OPTIONS" {
      return directoryNameError(
        status: 403,
        code: "origin_rejected",
        message: "State-changing request rejected"
      )
    }
    guard method == "PUT" else {
      let response = directoryNameError(
        status: 405,
        code: "method_not_allowed",
        message: "Method is not supported for this route"
      )
      return HTTPResponse(
        status: response.status,
        contentType: response.contentType,
        body: response.body,
        headers: ["Allow": "PUT"]
      )
    }
    guard dashboardMutationAllowed(headers: headers, listenerPort: listenerPort) else {
      return directoryNameError(
        status: 403,
        code: "origin_rejected",
        message: "State-changing request rejected"
      )
    }
    guard let directoryNameStore else {
      return directoryNameError(
        status: 503,
        code: "directory_name_unavailable",
        message: "Directory name storage is unavailable"
      )
    }
    return await dashboardDirectoryNameMutationResponse(
      store: directoryNameStore,
      body: body,
      allowedMachineIDs: ["local"]
    )
  }
}
