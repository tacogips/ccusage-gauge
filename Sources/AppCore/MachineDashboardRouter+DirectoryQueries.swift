import Foundation

extension MachineDashboardRouter {
  func metricsResponse(
    snapshot: CostSnapshot,
    range: String,
    components: URLComponents,
    scope: DashboardScope,
    rangeProgress: DashboardRangeLoadProgress?,
    directorySelections: DashboardDirectorySelections
  ) throws -> HTTPResponse {
    let start = range == "custom" ? queryValue("start", components).flatMap(queryService.parseDay) : nil
    let end = range == "custom" ? queryValue("end", components).flatMap(queryService.parseDay) : nil
    if range == "custom", start == nil || end == nil {
      return error(status: 400, code: "invalid_custom_range", message: "Invalid custom range")
    }
    var response = try queryService.metrics(
      snapshot: snapshot,
      range: range,
      startDate: start,
      endDate: end,
      directorySelections: directorySelections
    )
    response.rangeLoad = rangeProgress
    return jsonWithScope(response, scope: scope)
  }

  func costResponse(
    snapshot: CostSnapshot,
    range: String,
    granularity: String,
    components: URLComponents,
    scope: DashboardScope,
    machineLatestEvents: [MachineLatestEvent],
    rangeProgress: DashboardRangeLoadProgress?,
    directorySelections: DashboardDirectorySelections,
    directoryBreakdown: Bool
  ) throws -> HTTPResponse {
    let start = range == "custom" ? queryValue("start", components).flatMap(queryService.parseDay) : nil
    let end = range == "custom" ? queryValue("end", components).flatMap(queryService.parseDay) : nil
    if range == "custom", start == nil || end == nil {
      return error(status: 400, code: "invalid_custom_range", message: "Invalid custom range")
    }
    var response = try queryService.costSeries(
      snapshot: snapshot,
      granularity: granularity,
      range: range,
      startDate: start,
      endDate: end,
      directorySelections: directorySelections,
      directoryBreakdown: directoryBreakdown
    )
    response.scope = scope
    response.machineLatestEvents = machineLatestEvents
    response.rangeLoad = rangeProgress
    return json(response, dateMilliseconds: true)
  }
}
