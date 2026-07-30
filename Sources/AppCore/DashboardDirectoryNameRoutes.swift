import Foundation

public struct DashboardDirectoryNameRequest: Decodable, Equatable, Sendable {
  public let machine: String
  public let directory: String
  public let name: String?

  private enum CodingKeys: String, CodingKey {
    case machine, directory, name
  }

  public init(machine: String, directory: String, name: String?) {
    self.machine = machine
    self.directory = directory
    self.name = name
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    machine = try container.decode(String.self, forKey: .machine)
    directory = try container.decode(String.self, forKey: .directory)
    guard container.contains(.name) else {
      throw DecodingError.keyNotFound(
        CodingKeys.name,
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "name is required"
        )
      )
    }
    name = try container.decodeIfPresent(String.self, forKey: .name)
  }
}

public struct DashboardDirectoryNameResponse: Codable, Equatable, Sendable {
  public let status: String
  public let machine: String
  public let directory: String
  public let name: String?

  public init(machine: String, directory: String, name: String?) {
    status = "ok"
    self.machine = machine
    self.directory = directory
    self.name = name
  }

  private enum CodingKeys: String, CodingKey {
    case status, machine, directory, name
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(machine, forKey: .machine)
    try container.encode(directory, forKey: .directory)
    if let name {
      try container.encode(name, forKey: .name)
    } else {
      try container.encodeNil(forKey: .name)
    }
  }
}

func dashboardDirectoryNameMutationResponse(
  store: DashboardDirectoryNameStore,
  body: Data,
  allowedMachineIDs: Set<String>
) async -> HTTPResponse {
  let request: DashboardDirectoryNameRequest
  do {
    request = try JSONDecoder().decode(DashboardDirectoryNameRequest.self, from: body)
  } catch {
    return directoryNameError(
      status: 400,
      code: "invalid_directory_name",
      message: "Directory name request is invalid"
    )
  }
  guard MachineValidation.isCanonicalMachineID(request.machine),
        !request.directory.isEmpty else {
    return directoryNameError(
      status: 400,
      code: "invalid_directory_name",
      message: "Directory name request is invalid"
    )
  }
  guard allowedMachineIDs.contains(request.machine) else {
    return directoryNameError(
      status: 404,
      code: "machine_not_found",
      message: "Machine not found"
    )
  }
  do {
    let name = try await store.setName(
      machine: request.machine,
      directory: request.directory,
      name: request.name
    )
    return directoryNameJSON(
      DashboardDirectoryNameResponse(
        machine: request.machine,
        directory: request.directory,
        name: name
      )
    )
  } catch DashboardDirectoryNameError.invalidInput {
    return directoryNameError(
      status: 400,
      code: "invalid_directory_name",
      message: "Directory name request is invalid"
    )
  } catch DashboardDirectoryNameError.machineDeletionPending {
    return directoryNameError(
      status: 404,
      code: "machine_not_found",
      message: "Machine not found"
    )
  } catch {
    return directoryNameError(
      status: 503,
      code: "directory_name_unavailable",
      message: "Directory name storage is unavailable"
    )
  }
}

private func directoryNameJSON<T: Encodable>(_ value: T) -> HTTPResponse {
  guard let data = try? JSONEncoder().encode(value) else {
    return directoryNameError(
      status: 500,
      code: "encoding_failed",
      message: "Response encoding failed"
    )
  }
  return HTTPResponse(status: 200, contentType: "application/json", body: data)
}

func directoryNameError(
  status: Int,
  code: String,
  message: String
) -> HTTPResponse {
  let body = (try? JSONSerialization.data(
    withJSONObject: ["error": ["code": code, "message": message]],
    options: [.sortedKeys]
  )) ?? Data()
  return HTTPResponse(status: status, contentType: "application/json", body: body)
}
