public enum PieChartID: String, Codable, CaseIterable, Sendable {
  case budget, claude5h, claudeWeekly, claudeCredit, codex5h, codexWeekly, codexCredit

  /// Charts offered as menu-bar icons and ratio text; credit balances are shown in the tooltip instead.
  public static let menuBarCases: [PieChartID] = allCases.filter { !$0.isCredit }

  public var provider: RateLimitProvider? {
    switch self {
    case .budget: nil
    case .claude5h, .claudeWeekly, .claudeCredit: .claude
    case .codex5h, .codexWeekly, .codexCredit: .codex
    }
  }

  public var isCredit: Bool { self == .claudeCredit || self == .codexCredit }
}

public enum PieChartSelection {
  public static let defaultSelection: [PieChartID] = [.budget]

  public static func normalized(rawValues: [String]) -> [PieChartID] {
    normalized(rawValues.compactMap(PieChartID.init(rawValue:)))
  }

  public static func normalized(_ ids: [PieChartID]) -> [PieChartID] {
    let selected = Set(ids)
    let result = PieChartID.allCases.filter { selected.contains($0) }
    return result.isEmpty ? defaultSelection : result
  }

  public static func toggled(_ id: PieChartID, in selection: [PieChartID]) -> [PieChartID] {
    var selected = normalized(selection)
    if selected.contains(id) {
      if selected.count > 1 { selected.removeAll { $0 == id } }
    } else {
      selected.append(id)
    }
    return normalized(selected)
  }
}

public enum RatioTextSelection {
  public static let defaultSelection: [PieChartID] = [.budget]

  public static func normalized(rawValues: [String]) -> [PieChartID] {
    normalized(rawValues.compactMap(PieChartID.init(rawValue:)))
  }

  public static func normalized(_ ids: [PieChartID]) -> [PieChartID] {
    let selected = Set(ids)
    return PieChartID.allCases.filter { selected.contains($0) }
  }

  public static func toggled(_ id: PieChartID, in selection: [PieChartID]) -> [PieChartID] {
    var selected = normalized(selection)
    if selected.contains(id) {
      selected.removeAll { $0 == id }
    } else {
      selected.append(id)
    }
    return normalized(selected)
  }
}
