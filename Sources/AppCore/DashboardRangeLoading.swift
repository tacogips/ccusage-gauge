import Foundation

func requestedCoverage(
  path: String,
  components: URLComponents,
  queryService: DashboardQueryService
) -> (start: Date, end: Date)? {
  func queryValue(_ name: String) -> String? {
    components.queryItems?.first(where: { $0.name == name })?.value
  }
  if path == "/api/day", let day = queryValue("date").flatMap(queryService.parseDay) {
    return (day, day)
  }
  guard ["/api/period", "/api/metrics", "/api/cost-series"].contains(path) else { return nil }
  let range = queryValue("range") ?? "today"
  let now = Date()
  let today = queryService.calendar.startOfDay(for: now)
  if range == "custom",
     let start = queryValue("start").flatMap(queryService.parseDay),
     let end = queryValue("end").flatMap(queryService.parseDay) {
    return (start, min(end, today))
  }
  switch range {
  case "recent12h":
    return (queryService.calendar.startOfDay(for: now.addingTimeInterval(-43_200)), today)
  case "today":
    return (today, today)
  case "yesterday":
    guard let yesterday = queryService.calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
    return (yesterday, yesterday)
  case "week":
    guard let start = queryService.calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return nil }
    return (start, today)
  case "month":
    guard let start = queryService.calendar.dateInterval(of: .month, for: now)?.start else { return nil }
    return (start, today)
  default:
    return nil
  }
}

func dashboardRangeProgress(
  states: [MachineRangeLoadState],
  coverage: (start: Date, end: Date)?
) -> DashboardRangeLoadProgress? {
  guard let coverage else { return nil }
  let total = states.reduce(0) { $0 + max($1.progress.total, 1) }
  let completed = states.reduce(0) { $0 + min($1.progress.completed, max($1.progress.total, 1)) }
  let loading = states.contains(where: \.isLoading)
  let failed = states.filter(\.failed).map(\.machineID).sorted()
  return DashboardRangeLoadProgress(
    requestedStart: coverage.start,
    requestedEnd: coverage.end,
    completed: completed,
    total: max(total, states.isEmpty ? 0 : 1),
    isLoading: loading,
    isPartial: loading || !failed.isEmpty,
    failedMachineIds: failed
  )
}

func rangeLoadMessage(_ state: MachineRangeLoadState) -> String {
  if state.failed { return "Usage range loading failed" }
  if state.isLoading { return "Loading selected usage range" }
  return "Selected usage range is ready"
}

func dashboardMutationAllowed(headers: [String: String], listenerPort: Int) -> Bool {
  let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
  guard normalized["x-ccusage-gauge-mutation"] == "1" else { return false }
  let acceptedHosts = ["127.0.0.1:\(listenerPort)", "localhost:\(listenerPort)"]
  guard let host = normalized["host"], acceptedHosts.contains(host.lowercased()) else { return false }
  let fetchSite = normalized["sec-fetch-site"]?.lowercased()
  if fetchSite == "cross-site" || fetchSite == "same-site" || fetchSite == "none" { return false }
  if let origin = normalized["origin"] {
    guard origin != "null",
          acceptedHosts.map({ "http://\($0)" }).contains(origin.lowercased()),
          fetchSite == nil || fetchSite == "same-origin" else { return false }
  } else if fetchSite != nil, fetchSite != "same-origin" {
    return false
  }
  return true
}

func dashboardDataDisposition(
  path: String,
  components: URLComponents,
  now: Date,
  queryService: DashboardQueryService
) -> DashboardDataDisposition {
  if path == "/api/recent" || path == "/api/budget" { return .current }
  let today = queryService.calendar.startOfDay(for: now)
  let queryValue: (String) -> String? = { name in
    components.queryItems?.first(where: { $0.name == name })?.value
  }
  if path == "/api/day" {
    guard let day = queryValue("date").flatMap(queryService.parseDay) else { return .current }
    return day >= today ? .current : .historical
  }
  let range = queryValue("range") ?? "today"
  if range == "yesterday" { return .historical }
  if range == "custom" {
    guard let end = queryValue("end").flatMap(queryService.parseDay) else { return .current }
    return end >= today ? .current : .historical
  }
  return .current
}
