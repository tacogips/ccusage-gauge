import Foundation

public struct MachineSubdirectories: Codable, Equatable, Sendable {
  public let machine: String
  public let directories: [String]
  public let names: [String: String]?

  public init(
    machine: String,
    directories: [String],
    names: [String: String]? = nil
  ) {
    self.machine = machine
    self.directories = directories
    self.names = names?.isEmpty == true ? nil : names
  }
}

public struct SubdirectoriesResponse: Codable, Equatable, Sendable {
  public let machines: [MachineSubdirectories]

  public init(machines: [MachineSubdirectories]) {
    self.machines = machines
  }
}

struct DashboardDirectoryRequest: Sendable {
  let selections: DashboardDirectorySelections
  let breakdown: Bool
}

enum DashboardDirectoryRequestError: Error, Equatable {
  case invalid
  case machineNotFound
}

func dashboardDirectoryRequest(
  _ components: URLComponents,
  descriptors: [MachineDescriptor],
  requestedMachines: String,
  acceptsBreakdown: Bool
) throws -> DashboardDirectoryRequest {
  let knownIDs = Set(descriptors.map(\.id))
  let activeIDs = requestedMachines == "all"
    ? Set(descriptors.filter(\.enabled).map(\.id))
    : Set(requestedMachines.split(separator: ",").map(String.init))
  var selections: DashboardDirectorySelections = [:]
  for item in (components.queryItems ?? []).filter({ $0.name == "directory" }) {
    guard let value = item.value,
          let separator = value.firstIndex(of: ":"),
          separator != value.startIndex else {
      throw DashboardDirectoryRequestError.invalid
    }
    let machine = String(value[..<separator])
    let directory = String(value[value.index(after: separator)...])
    guard MachineValidation.isCanonicalMachineID(machine), !directory.isEmpty else {
      throw DashboardDirectoryRequestError.invalid
    }
    guard knownIDs.contains(machine) else {
      throw DashboardDirectoryRequestError.machineNotFound
    }
    if activeIDs.contains(machine) {
      selections[machine, default: []].insert(directory)
    }
  }

  let breakdownItems = (components.queryItems ?? []).filter { $0.name == "directoryBreakdown" }
  guard acceptsBreakdown || breakdownItems.isEmpty,
        breakdownItems.count <= 1 else {
    throw DashboardDirectoryRequestError.invalid
  }
  let breakdown: Bool
  switch breakdownItems.first?.value {
  case nil, "false": breakdown = false
  case "true": breakdown = true
  default: throw DashboardDirectoryRequestError.invalid
  }
  return DashboardDirectoryRequest(selections: selections, breakdown: breakdown)
}

func subdirectoriesResponse(
  snapshot: CostSnapshot,
  machineIDs: [String],
  namesByMachine: [String: [String: String]] = [:]
) -> SubdirectoriesResponse {
  let directoriesByMachine = Dictionary(grouping: snapshot.dashboardSessions, by: \.machine)
    .mapValues { rows in
      Array(Set(rows.compactMap(\.directory))).sorted()
    }
  return SubdirectoriesResponse(
    machines: machineIDs.sorted().map { machine in
      let directories = directoriesByMachine[machine] ?? []
      let discovered = Set(directories)
      let names = namesByMachine[machine]?.filter { discovered.contains($0.key) }
      return MachineSubdirectories(
        machine: machine,
        directories: directories,
        names: names
      )
    }
  )
}
