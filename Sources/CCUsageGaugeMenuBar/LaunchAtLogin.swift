import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
  case off
  case on
  case requiresApproval
  case unavailable

  var isRequested: Bool { self == .on || self == .requiresApproval }

  var label: String {
    switch self {
    case .off: "Off"
    case .on: "On"
    case .requiresApproval: "Approval required"
    case .unavailable: "Unavailable"
    }
  }
}

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
  var state: LaunchAtLoginState { get }
  func toggle() throws
}

@MainActor
final class SystemLaunchAtLoginController: LaunchAtLoginControlling {
  private let service: SMAppService

  init(service: SMAppService = .mainApp) { self.service = service }

  var state: LaunchAtLoginState {
    switch service.status {
    case .notRegistered: .off
    case .enabled: .on
    case .requiresApproval: .requiresApproval
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }

  func toggle() throws {
    if state.isRequested {
      try service.unregister()
    } else {
      try service.register()
    }
  }
}

@MainActor
final class E2ELaunchAtLoginController: LaunchAtLoginControlling {
  private(set) var state: LaunchAtLoginState = .off

  func toggle() throws { state = state == .on ? .off : .on }
}

@MainActor
enum LaunchAtLoginControllerFactory {
  static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> LaunchAtLoginControlling {
    environment["CCUSAGE_GAUGE_E2E_OPEN_MENU"] == "1"
      ? E2ELaunchAtLoginController()
      : SystemLaunchAtLoginController()
  }
}
