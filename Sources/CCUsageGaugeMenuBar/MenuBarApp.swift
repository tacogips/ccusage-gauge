import AppCore
import AppKit
import Foundation

private func formatPercentage(_ value: Decimal) -> String {
  let formatter = NumberFormatter()
  formatter.numberStyle = .decimal
  formatter.maximumFractionDigits = 1
  return "\(formatter.string(from: value as NSDecimalNumber) ?? String(describing: value))%"
}

private func formatUSDCurrency(_ value: Decimal, minimumFractionDigits: Int = 0) -> String {
  let formatter = NumberFormatter()
  formatter.numberStyle = .currency
  formatter.currencyCode = "USD"
  formatter.minimumFractionDigits = minimumFractionDigits
  formatter.maximumFractionDigits = 2
  return formatter.string(from: value as NSDecimalNumber) ?? "$\(value)"
}

private func formatUsagePeriod(from start: Date, through end: Date) -> String {
  let formatter = DateIntervalFormatter()
  formatter.dateStyle = .short
  formatter.timeStyle = .short
  return formatter.string(from: start, to: end)
}

private func formatUsagePeriod(for cycle: ResetCycle, now: Date) -> String {
  guard let interval = try? ResetWindowCalculator().aggregationInterval(for: cycle, now: now) else {
    return "unavailable"
  }
  return formatUsagePeriod(from: interval.start, through: interval.end.addingTimeInterval(-1))
}

@main
@MainActor
struct CCUsageGaugeMenuBarApp {
  static func main() {
    let application = NSApplication.shared
    let isE2E = ProcessInfo.processInfo.environment["CCUSAGE_GAUGE_E2E_OPEN_MENU"] == "1"
    application.setActivationPolicy(isE2E ? .regular : .accessory)
    let delegate = MenuBarDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

@MainActor
final class MenuBarDelegate: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let launchAtLoginController: LaunchAtLoginControlling
  private var paths = AppPaths.production()
  private lazy var bootstrapLogger = BootstrapLogger(paths: paths, runtime: .menuBar)
  private var configuration: AppConfiguration?
  private var defaultResetCycle: ResetCycle = .daily
  private var stateStore: StateStore?
  private var snapshotService: SnapshotService?
  private var machineSnapshotStore: MachineSnapshotStore?
  private var machineCollector: MachineCollector?
  private var machineRouter: MachineDashboardRouter?
  private var dashboardServer: DashboardHTTPServer?
  private var pollingTask: Task<Void, Never>?
  private var latestSnapshot: CostSnapshot?
  private var currentState: AppState?
  private var errorMessage: String?
  private var isUsageUnavailable = false
  private var launchAtLoginError: String?
  private var stateMutationGeneration = 0
  private var e2eWindow: NSWindow?
  private var e2eIconView: NSImageView?
  private var e2eStatusLabel: NSTextField?
  private var e2eBudgetLabel: NSTextField?
  private var e2eErrorLabel: NSTextField?
  private var e2eCycleLabel: NSTextField?
  private var e2eDashboardButton: NSButton?
  private var e2eLaunchAtLoginButton: NSButton?
  private var e2eRefreshIntervalButton: NSButton?

  override init() {
    launchAtLoginController = LaunchAtLoginControllerFactory.make()
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    bootstrapLogger.activate()
    configureStatusButton()
    updateStatusTitle("$—")
    rebuildMenu()
    Task { await bootstrap() }
  }

  func applicationWillTerminate(_ notification: Notification) {
    pollingTask?.cancel()
    dashboardServer?.stop()
    if let machineCollector { Task { await machineCollector.stop() } }
  }

  private func bootstrap() async {
    pollingTask?.cancel()
    if let machineCollector { await machineCollector.stop() }
    snapshotService = nil
    machineSnapshotStore = nil
    self.machineCollector = nil
    machineRouter = nil
    do {
      let loaded = try ConfigStore(fileURL: paths.configFile).loadOrCreate()
      let resetCycle = try ResetCycle(term: loaded.defaultResetTerm)
      let store = StateStore(fileURL: paths.stateFile)
      currentState = try await store.load(defaultCycle: resetCycle)
      configuration = loaded
      defaultResetCycle = resetCycle
      stateStore = store

      let executable = try CCUsageExecutableResolver().resolve(
        configuredPath: loaded.ccusagePath,
        additionalSearchDirectories: ["/opt/homebrew/bin", "/usr/local/bin"]
      )
      let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
      let registry = try registryStore.load()
      try LocalCacheMigrator(
        legacyURL: paths.aggregationCacheFile,
        destinationURL: paths.aggregationCacheFile(forMachine: "local")
      ).migrateIfNeeded()
      for descriptor in registry.machines {
        try MachineCacheRecovery.reconcile(
          machineID: descriptor.id,
          cacheURL: paths.aggregationCacheFile(forMachine: descriptor.id)
        )
      }
      let service = SnapshotService(
        stateStore: store,
        client: CCUsageClient(executable: executable),
        defaultRefreshIntervalSeconds: loaded.pollIntervalSeconds,
        aggregationCache: UsageAggregationCache(
          fileURL: paths.aggregationCacheFile(forMachine: "local"),
          retentionDays: loaded.cacheRetentionDays,
          machineID: "local"
        ),
        claudeUsageEventLoader: .production(),
        codexUsageEventLoader: .production()
      )
      snapshotService = service
      let machineStore = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: loaded.pollIntervalSeconds)
      let collector = try MachineCollector(
        registry: registry,
        store: machineStore,
        connectionTester: { descriptor in
          let runner: any CCUsageCommandRunner
          if descriptor.kind == .local {
            runner = LocalCCUsageCommandRunner(executable: executable)
          } else {
            guard let connection = descriptor.ssh else {
              throw MachineValidationError(fieldErrors: ["ssh": "is required"])
            }
            runner = try SSHCCUsageCommandRunner(connection: connection)
          }
          _ = try await runner.run(arguments: ["--version"], timeoutSeconds: 30)
        }
      ) { [paths, loaded, store, service] descriptor in
        if descriptor.kind == .local { return service }
        guard let connection = descriptor.ssh else { throw MachineValidationError(fieldErrors: ["ssh": "is required"]) }
        return SnapshotService(
          stateStore: store,
          client: CCUsageClient(commandRunner: try SSHCCUsageCommandRunner(connection: connection), machine: descriptor.id),
          defaultRefreshIntervalSeconds: loaded.pollIntervalSeconds,
          aggregationCache: UsageAggregationCache(
            fileURL: paths.aggregationCacheFile(forMachine: descriptor.id),
            retentionDays: loaded.cacheRetentionDays,
            machineID: descriptor.id
          )
        )
      }
      let mutationOwner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
      machineSnapshotStore = machineStore
      machineCollector = collector
      machineRouter = MachineDashboardRouter(
        store: machineStore,
        collector: collector,
        mutationOwner: mutationOwner,
        paths: paths,
        dashboardStateStore: DashboardStateStore(fileURL: paths.dashboardStateFile),
        chartColors: loaded.chartColors
      )
      errorMessage = nil
      isUsageUnavailable = false
      if loaded.dashboardAutostart { startDashboard() }
      await loadInitialMenuBarSnapshot(using: service)
      await collector.start()
      let initialCollection = Task { await collector.refresh(machine: "local") }
      _ = await initialCollection.value
      await refresh()
      startPolling(
        interval: currentState?.refreshIntervalSeconds ?? loaded.pollIntervalSeconds,
        refreshImmediately: false
      )
    } catch {
      bootstrapLogger.append(
        phase: "bootstrap",
        code: "bootstrap_failed",
        message: "Menu-bar bootstrap failed: \(error)"
      )
      errorMessage = "ccusage unavailable. Install ccusage or verify the configured executable and connection."
      isUsageUnavailable = true
      updateStatusTitle("$!")
      rebuildMenu()
    }
    openE2EWindowIfNeeded()
  }

  private func loadInitialMenuBarSnapshot(using service: SnapshotService) async {
    let refreshGeneration = stateMutationGeneration
    do {
      let snapshot = try await service.menuBarSnapshot(defaultCycle: defaultResetCycle)
      guard refreshGeneration == stateMutationGeneration else { return }
      latestSnapshot = snapshot
      errorMessage = nil
      isUsageUnavailable = false
      updateStatusTitle(Self.statusTitle(snapshot))
    } catch {
      guard refreshGeneration == stateMutationGeneration else { return }
      errorMessage = MachineDiagnosticClassifier.classify(error).message
      isUsageUnavailable = true
      updateStatusTitle(latestSnapshot.map { Self.statusTitle($0) + " !" } ?? "$!")
    }
    rebuildMenu()
  }

  private func startPolling(interval: Int, refreshImmediately: Bool = true) {
    pollingTask?.cancel()
    pollingTask = Task { [weak self] in
      if !refreshImmediately {
        do { try await Task.sleep(for: .seconds(interval)) } catch { return }
      }
      while !Task.isCancelled {
        await self?.refresh()
        do { try await Task.sleep(for: .seconds(interval)) } catch { break }
      }
    }
  }

  private func refresh() async {
    let refreshGeneration = stateMutationGeneration
    guard let machineSnapshotStore else {
      rebuildMenu()
      return
    }
    do {
      guard let snapshot = try await machineSnapshotStore.selection(machine: "local").snapshot else { return }
      let state = try await stateStore?.load(defaultCycle: defaultResetCycle)
      guard refreshGeneration == stateMutationGeneration else { return }
      latestSnapshot = snapshot
      currentState = state
      errorMessage = nil
      isUsageUnavailable = false
      updateStatusTitle(latestSnapshot.map(Self.statusTitle) ?? "$—")
    } catch {
      guard refreshGeneration == stateMutationGeneration else { return }
      errorMessage = MachineDiagnosticClassifier.classify(error).message
      isUsageUnavailable = true
      updateStatusTitle(latestSnapshot.map { Self.statusTitle($0) + " !" } ?? "$!")
    }
    rebuildMenu()
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    if let snapshot = latestSnapshot {
      let budgetItem = NSMenuItem()
      budgetItem.view = BudgetMenuView(snapshot: snapshot)
      menu.addItem(budgetItem)
    } else if let budget = currentState?.budgetUSD {
      let item = NSMenuItem(title: "Budget: \(formatUSDCurrency(budget)) (usage unavailable)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    } else {
      menu.addItem(withTitle: "Budget: unavailable", action: nil, keyEquivalent: "")
    }
    if let errorMessage {
      menu.addItem(errorDetailsItem(message: errorMessage))
    }
    menu.addItem(.separator())
    let budgetItem = menu.addItem(withTitle: "Set budget…", action: #selector(setBudget), keyEquivalent: "b")
    budgetItem.target = self
    budgetItem.isEnabled = stateStore != nil
    let cycleItem = resetCycleItem()
    cycleItem.isEnabled = stateStore != nil
    menu.addItem(cycleItem)
    menu.addItem(refreshIntervalItem())
    menu.addItem(settingsItem())
    menu.addItem(.separator())
    menu.addItem(withTitle: "Open dashboard", action: #selector(openDashboard), keyEquivalent: "d").target = self
    let toggleTitle = dashboardServer?.isRunning == true ? "Stop dashboard" : "Start dashboard"
    menu.addItem(withTitle: toggleTitle, action: #selector(toggleDashboard), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Refresh", action: #selector(refreshAction), keyEquivalent: "f").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    statusItem.menu = menu
    refreshE2EWindow()
  }

  private func errorDetailsItem(message: String) -> NSMenuItem {
    let title = isUsageUnavailable ? "Warning: ccusage unavailable" : "Error Details"
    let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    root.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
    let submenu = NSMenu()
    let detail = NSMenuItem(title: message, action: nil, keyEquivalent: "")
    detail.isEnabled = false
    detail.toolTip = message
    submenu.addItem(detail)
    let configPath = NSMenuItem(title: "Config: \(paths.configFile.path)", action: nil, keyEquivalent: "")
    configPath.isEnabled = false
    submenu.addItem(configPath)
    submenu.addItem(.separator())
    let retry = submenu.addItem(withTitle: "Retry validation", action: #selector(retryValidation), keyEquivalent: "")
    retry.target = self
    root.submenu = submenu
    return root
  }

  private func settingsItem() -> NSMenuItem {
    let root = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    let launch = submenu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    launch.target = self
    launch.state = launchAtLoginController.state.isRequested ? .on : .off
    if launchAtLoginController.state == .requiresApproval {
      let approval = NSMenuItem(title: "Approval required in System Settings", action: nil, keyEquivalent: "")
      approval.isEnabled = false
      submenu.addItem(approval)
    } else if launchAtLoginController.state == .unavailable {
      launch.isEnabled = false
    }
    if let launchAtLoginError {
      let error = NSMenuItem(title: launchAtLoginError, action: nil, keyEquivalent: "")
      error.isEnabled = false
      submenu.addItem(error)
    }
    root.submenu = submenu
    return root
  }

  private func resetCycleItem() -> NSMenuItem {
    let root = NSMenuItem(title: "Aggregation period", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    [("Hourly", 0), ("Daily", 1), ("Weekly", 2), ("Monthly", 3), ("Custom hours…", 4)].forEach { title, tag in
      let item = NSMenuItem(title: title, action: #selector(changeCycle(_:)), keyEquivalent: "")
      item.target = self
      item.tag = tag
      submenu.addItem(item)
    }
    root.submenu = submenu
    return root
  }

  private func refreshIntervalItem() -> NSMenuItem {
    let root = NSMenuItem(title: "Refresh interval", action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    let current = NSMenuItem(title: "Every \(effectiveRefreshIntervalSeconds) seconds", action: nil, keyEquivalent: "")
    current.isEnabled = false
    submenu.addItem(current)
    let setItem = NSMenuItem(title: "Set seconds…", action: #selector(setRefreshInterval), keyEquivalent: "")
    setItem.target = self
    setItem.isEnabled = stateStore != nil
    submenu.addItem(setItem)
    if currentState?.refreshIntervalSeconds != nil, let configured = configuration?.pollIntervalSeconds {
      let resetItem = NSMenuItem(title: "Use config default (\(configured) seconds)", action: #selector(resetRefreshInterval), keyEquivalent: "")
      resetItem.target = self
      submenu.addItem(resetItem)
    }
    root.submenu = submenu
    return root
  }

  private var effectiveRefreshIntervalSeconds: Int {
    currentState?.refreshIntervalSeconds ?? configuration?.pollIntervalSeconds ?? AppConfiguration.defaultPollIntervalSeconds
  }

  @objc private func setBudget() {
    guard let text = prompt(title: "Set budget", message: "Monthly budget in USD", defaultValue: latestSnapshot?.budget.budgetUSD.map(String.init(describing:)) ?? "") else { return }
    guard let value = Decimal(string: text), value >= 0 else { showError("Budget must be a nonnegative number."); return }
    Task { await mutateState { $0.budgetUSD = value } }
  }

  @objc private func setRefreshInterval() {
    guard let text = prompt(
      title: "Set refresh interval",
      message: "Refresh every N seconds",
      defaultValue: String(effectiveRefreshIntervalSeconds)
    ) else {
      return
    }
    guard let seconds = Int(text), seconds > 0 else {
      showError("Refresh interval must be a positive whole number of seconds.")
      return
    }
    Task {
      if await mutateState({ $0.refreshIntervalSeconds = seconds }) {
        startPolling(interval: seconds)
      }
    }
  }

  @objc private func resetRefreshInterval() {
    Task {
      if await mutateState({ $0.refreshIntervalSeconds = nil }) {
        startPolling(interval: configuration?.pollIntervalSeconds ?? AppConfiguration.defaultPollIntervalSeconds)
      }
    }
  }

  @objc private func changeCycle(_ sender: NSMenuItem) {
    var cycle: ResetCycle
    switch sender.tag {
    case 0: cycle = .hourly
    case 1: cycle = .daily
    case 2: cycle = .weekly
    case 3: cycle = .monthly
    default:
      guard let text = prompt(title: "Custom aggregation period", message: "Rolling hours", defaultValue: "24"), let hours = Int(text), hours > 0 else { return }
      cycle = .customHours(hours)
    }
    Task { await mutateState { state in state = try ResetWindowCalculator().changing(state, to: cycle, at: Date()) } }
  }

  @discardableResult
  private func mutateState(_ mutation: (inout AppState) throws -> Void) async -> Bool {
    guard let stateStore else {
      showError("State storage is unavailable. Check the configuration and relaunch ccusage-gauge.")
      return false
    }
    do {
      var state = try await stateStore.load(defaultCycle: defaultResetCycle)
      try mutation(&state)
      try await stateStore.save(state)
      stateMutationGeneration += 1
      currentState = state
      if let projectedSnapshot = latestSnapshot?.applying(state: state) {
        latestSnapshot = projectedSnapshot
        updateStatusTitle(Self.statusTitle(projectedSnapshot))
      }
      rebuildMenu()
      if snapshotService != nil { Task { await refresh() } }
      return true
    } catch {
      showError(String(describing: error))
      return false
    }
  }

  @objc private func refreshAction() { Task { await refresh() } }

  @objc private func retryValidation() { Task { await bootstrap() } }

  @objc private func toggleLaunchAtLogin() {
    do {
      try launchAtLoginController.toggle()
      launchAtLoginError = nil
    } catch {
      launchAtLoginError = "Launch at Login failed: \(error.localizedDescription)"
    }
    rebuildMenu()
  }

  @objc private func toggleDashboard() {
    if dashboardServer?.isRunning == true { dashboardServer?.stop(); dashboardServer = nil } else { startDashboard() }
    rebuildMenu()
  }

  private func startDashboard() {
    guard dashboardServer?.isRunning != true, let machineRouter, let configuration else { return }
    let router = DashboardRouter(machineRouter: machineRouter, assetResolver: StaticAssetResolver())
    let server = DashboardHTTPServer(router: router)
    do {
      try server.start(port: UInt16(configuration.dashboardPort))
      dashboardServer = server
    } catch { errorMessage = "Dashboard could not start: \(error)" }
  }

  @objc private func openDashboard() {
    startDashboard()
    guard let port = configuration?.dashboardPort,
          let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func quit() { NSApplication.shared.terminate(nil) }

  private func prompt(title: String, message: String, defaultValue: String) -> String? {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(string: defaultValue)
    field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
  }

  private func showError(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "ccusage-gauge"
    alert.informativeText = message
    alert.runModal()
  }

  private static func statusTitle(_ snapshot: CostSnapshot) -> String {
    let cost = formatUSDCurrency(snapshot.costSinceResetUSD)
    guard let usagePercentage = snapshot.budget.usagePercentage else { return cost }
    return "\(cost) · \(formatPercentage(usagePercentage))"
  }

  private func configureStatusButton() {
    guard let button = statusItem.button else { return }
    button.imagePosition = .imageLeading
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = "ccusage-gauge — cost in selected period"
    button.setAccessibilityLabel("ccusage-gauge cost in selected period")
    updateStatusIcon()
  }

  private func updateStatusTitle(_ title: String) {
    statusItem.button?.title = title
    statusItem.button?.setAccessibilityValue(title)
    updateStatusIcon()
  }

  private func updateStatusIcon() {
    statusItem.button?.image = MenuBarPieIcon.image(
      fraction: latestSnapshot?.budget.visualFraction,
      hasBudget: currentState?.budgetUSD != nil,
      warning: isUsageUnavailable
    )
    let label = isUsageUnavailable ? "Warning: ccusage unavailable" : "ccusage-gauge cost in selected period"
    statusItem.button?.setAccessibilityLabel(label)
    statusItem.button?.toolTip = isUsageUnavailable ? errorMessage : "ccusage-gauge — cost in selected period"
    e2eIconView?.image = statusItem.button?.image
  }

  private func openE2EWindowIfNeeded() {
    guard e2eWindow == nil,
          ProcessInfo.processInfo.environment["CCUSAGE_GAUGE_E2E_OPEN_MENU"] == "1" else { return }
    let window = makeE2EWindow()
    e2eWindow = window
    refreshE2EWindow()
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  private func makeE2EWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 680),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "ccusage-gauge E2E"
    window.center()

    let icon = NSImageView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.setAccessibilityLabel("Budget usage pie chart")
    e2eIconView = icon
    let status = NSTextField(labelWithString: "$—")
    status.font = .systemFont(ofSize: 20, weight: .semibold)
    status.setAccessibilityLabel("Cost in selected period")
    e2eStatusLabel = status
    let header = NSStackView(views: [icon, status])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 10

    let budget = NSTextField(wrappingLabelWithString: "Budget unavailable")
    budget.setAccessibilityLabel("Budget summary")
    e2eBudgetLabel = budget
    let error = NSTextField(wrappingLabelWithString: "")
    error.textColor = .systemRed
    error.setAccessibilityLabel("Usage error")
    e2eErrorLabel = error

    let setBudgetButton = e2eButton(title: "Set budget…", action: #selector(setBudget))
    let cycleLabel = NSTextField(labelWithString: "Aggregation period: daily")
    cycleLabel.setAccessibilityLabel("Current aggregation period")
    e2eCycleLabel = cycleLabel
    let hourlyButton = e2eCycleButton(title: "Aggregation period: Hourly", tag: 0)
    let dailyButton = e2eCycleButton(title: "Aggregation period: Daily", tag: 1)
    let weeklyButton = e2eCycleButton(title: "Aggregation period: Weekly", tag: 2)
    let monthlyButton = e2eCycleButton(title: "Aggregation period: Monthly", tag: 3)
    let customButton = e2eCycleButton(title: "Aggregation period: Custom hours…", tag: 4)
    let launchAtLoginButton = e2eButton(title: "Launch at Login: Off", action: #selector(toggleLaunchAtLogin))
    launchAtLoginButton.setAccessibilityLabel("Launch at Login")
    e2eLaunchAtLoginButton = launchAtLoginButton
    let refreshIntervalButton = e2eButton(
      title: "Refresh interval: \(AppConfiguration.defaultPollIntervalSeconds) seconds",
      action: #selector(setRefreshInterval)
    )
    refreshIntervalButton.setAccessibilityLabel("Refresh interval")
    e2eRefreshIntervalButton = refreshIntervalButton
    let openDashboardButton = e2eButton(title: "Open dashboard", action: #selector(openDashboard))
    let dashboardButton = e2eButton(title: "Start dashboard", action: #selector(toggleDashboard))
    e2eDashboardButton = dashboardButton
    let refreshButton = e2eButton(title: "Refresh", action: #selector(refreshAction))
    let quitButton = e2eButton(title: "Quit", action: #selector(quit))

    let stack = NSStackView(views: [
      header, budget, error, setBudgetButton, cycleLabel,
      hourlyButton, dailyButton, weeklyButton, monthlyButton, customButton,
      launchAtLoginButton, refreshIntervalButton, openDashboardButton, dashboardButton, refreshButton, quitButton
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    guard let contentView = window.contentView else { return window }
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24)
    ])
    [
      setBudgetButton, hourlyButton, dailyButton, weeklyButton, monthlyButton,
      customButton, launchAtLoginButton, refreshIntervalButton, openDashboardButton, dashboardButton, refreshButton, quitButton
    ].forEach {
      $0.widthAnchor.constraint(equalToConstant: 220).isActive = true
    }
    return window
  }

  private func e2eButton(title: String, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    return button
  }

  private func e2eCycleButton(title: String, tag: Int) -> NSButton {
    let button = e2eButton(title: title, action: #selector(changeCycleFromE2E(_:)))
    button.tag = tag
    return button
  }

  private func refreshE2EWindow() {
    guard e2eWindow != nil else { return }
    e2eIconView?.image = statusItem.button?.image
    e2eIconView?.setAccessibilityLabel(isUsageUnavailable ? "Warning: ccusage unavailable" : "Budget usage pie chart")
    e2eStatusLabel?.stringValue = statusItem.button?.title ?? "$—"
    if let snapshot = latestSnapshot {
      let budget = snapshot.budget.budgetUSD.map { formatUSDCurrency($0) } ?? "not set"
      let usage = snapshot.budget.usagePercentage.map(formatPercentage) ?? "unavailable"
      let period = formatUsagePeriod(for: snapshot.resetCycle, now: snapshot.generatedAt)
      e2eBudgetLabel?.stringValue = "Spent \(formatUSDCurrency(snapshot.budget.spentUSD, minimumFractionDigits: 2)) · Budget \(budget) · Usage \(usage) · \(snapshot.resetCycle.label) · Period \(period)"
    } else if let budget = currentState?.budgetUSD {
      e2eBudgetLabel?.stringValue = "Spent unavailable · Budget \(formatUSDCurrency(budget)) · \(currentState?.resetCycle.label ?? defaultResetCycle.label)"
    } else {
      e2eBudgetLabel?.stringValue = "Budget not set · \(currentState?.resetCycle.label ?? defaultResetCycle.label)"
    }
    e2eErrorLabel?.stringValue = errorMessage ?? ""
    e2eCycleLabel?.stringValue = "Aggregation period: \((currentState?.resetCycle ?? defaultResetCycle).label)"
    e2eDashboardButton?.title = dashboardServer?.isRunning == true ? "Stop dashboard" : "Start dashboard"
    e2eLaunchAtLoginButton?.title = "Launch at Login: \(launchAtLoginController.state.label)"
    e2eRefreshIntervalButton?.title = "Refresh interval: \(effectiveRefreshIntervalSeconds) seconds"
  }

  @objc private func changeCycleFromE2E(_ sender: NSButton) {
    let item = NSMenuItem()
    item.tag = sender.tag
    changeCycle(item)
  }
}

@MainActor
final class BudgetMenuView: NSView {
  private let snapshot: CostSnapshot

  init(snapshot: CostSnapshot) {
    self.snapshot = snapshot
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 86))
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let circle = NSRect(x: 14, y: 21, width: 44, height: 44)
    NSColor.systemGray.withAlphaComponent(0.25).setFill()
    NSBezierPath(ovalIn: circle).fill()
    if let fraction = snapshot.budget.visualFraction {
      let path = NSBezierPath()
      let center = NSPoint(x: circle.midX, y: circle.midY)
      path.move(to: center)
      path.appendArc(withCenter: center, radius: 22, startAngle: 90, endAngle: 90 - CGFloat(truncating: fraction as NSDecimalNumber) * 360, clockwise: true)
      path.close()
      NSColor.systemGreen.setFill()
      path.fill()
    }
    let budget = snapshot.budget.budgetUSD.map { formatUSDCurrency($0) } ?? "not set"
    let usage = snapshot.budget.usagePercentage.map(formatPercentage) ?? "unavailable"
    let period = formatUsagePeriod(for: snapshot.resetCycle, now: snapshot.generatedAt)
    let text = "Spent \(formatUSDCurrency(snapshot.budget.spentUSD, minimumFractionDigits: 2)) (\(usage))\nBudget \(budget)\nPeriod \(period)"
    text.draw(
      at: NSPoint(x: 72, y: 16),
      withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
    )
  }
}
