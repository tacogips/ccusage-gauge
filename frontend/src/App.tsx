import { For, Show, createEffect, createMemo, createResource, createSignal, onCleanup, onMount } from "solid-js";
import { type BudgetResponse, type ChartColorsResponse, type CostRow, type DashboardUIState, type DashboardUIStateResponse, type LoadStatusResponse, type Machine, type MachineConnectionTestResponse, type MachineDataGap, type MachineLatestEvent, type MachineRefreshResponse, type MachinesResponse, type MachineStatusResponse, type MetricKey, type MetricRow, type MetricsResponse, type SubdirectoriesResponse, getJSON, mutationJSON, renameSubdirectory, requestJSON } from "./api";
import {
  machineSaveErrors,
  machineMetadataCleanupWarning,
  removeMachineCatalog,
  runMachineRefreshLifecycle,
  saveMachineCatalog,
  toggleMachineCatalog,
  type MachineCatalogRefreshFailure,
} from "./machineActions";
import { actionRefetchTargets } from "./machineObservability";
import { availabilityErrorCode, dashboardErrorMessage, getCostSeriesState } from "./costSeriesState";
import { currentViewMetricTotal } from "./currentViewMetrics";
import {
  costSeriesDataPath,
  dashboardDataPath,
  defaultStackBy,
  beginDirectoryRename,
  directoryCatalogRefreshWarning,
  directoryCatalogWithConfirmedFallback,
  directoryRenameIntent,
  submitDirectoryRename,
  type DirectoryRenameEditor,
  type DirectoryRenameInteraction,
  restoredStackBy,
  visibleDirectoryChoices,
} from "./dashboardDirectoryState";
import { initializeDashboardState } from "./dashboardStatePersistence";
import { startDashboardAutoRefresh } from "./dashboardAutoRefresh";
import { shieldResource, shouldBlockDashboard } from "./dashboardLoadingState";
import { changingProxyKind, draftFromMachine, emptyMachineDraft, machineDraftErrors, type MachineDraft, type MachineProxyKind } from "./machineForm";
import { BreakdownBars, LoadingState, MachineHealthPanel } from "./DashboardComponents";
import { MachineAdminPanel } from "./MachineAdminPanel";
import {
  allDirectoryItemsSelected,
  clearUncheckedDirectorySelections,
  directoryItemSelected,
  directoryLabels,
  directorySelectionMachineScope,
  filteredDirectoryItems,
  initialDirectoryLimit,
  initialMachineLimit,
  machineProgressDetail,
  machineQuery,
  requestedMachineIDs,
  toggledDirectoryItems,
  toggledMachineSelection,
  visibleDirectoryItems,
  visibleMachineItems,
  wholeMachineSelected,
} from "./machineScope";
import { allocateModelColors, effortShade, seriesColor } from "./seriesColors";
import { directorySeriesDisplayLabel, modelEffortParts, type StackBy } from "./usageChartSeries";
import { UsageChart } from "./UsageChart";
// @ts-expect-error TS5097: the explicit extension selects this component over the case-only rangeControls.ts helper.
import { RangeControls } from "./RangeControls.tsx";
// @ts-expect-error TS5097: explicit .ts disambiguates the case-only rangeControls.ts and RangeControls.tsx modules.
import { rangeSummaryLabel, type QuickRange, type Range } from "./rangeControls.ts";
import { HeaderFoldBar, PaneFoldBar, ThemeToggle } from "./DashboardLayout";
import { applyColorScheme, oppositeColorScheme, readStoredColorScheme, storeColorScheme, type ColorScheme } from "./colorScheme";
import { restoredFoldState } from "./dashboardLayoutState";

type Granularity = "15min" | "hourly" | "6hour" | "daily";

const currency = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const integer = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const percentage = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });
const timestampLabel = (value?: string) => value == null ? "not recorded" : new Date(value).toLocaleString();
const dateText = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
const localDate = () => dateText(new Date());
const daysAgo = (days: number) => { const date = new Date(); date.setDate(date.getDate() - days); return dateText(date); };
const metricValue = (row: Pick<MetricRow, MetricKey>, metric: MetricKey) => row[metric];
const chartMetrics: Array<[MetricKey, string]> = [
  ["costUSD", "Cost"],
  ["totalTokens", "Total tokens"],
  ["inputTokens", "Input tokens"],
  ["outputTokens", "Output tokens"],
  ["cacheReadTokens", "Cache read tokens"],
  ["cacheCreationTokens", "Cache creation tokens"],
];

export default function App() {
  let configMenu: HTMLDetailsElement | undefined;
  const initialCustomStart = daysAgo(6);
  const initialCustomEnd = localDate();
  const [range, setRange] = createSignal<Range>("recent12h");
  const [customStart, setCustomStart] = createSignal(initialCustomStart);
  const [customEnd, setCustomEnd] = createSignal(initialCustomEnd);
  const [appliedCustomRange, setAppliedCustomRange] = createSignal({ start: initialCustomStart, end: initialCustomEnd });
  const [isCustomEditorOpen, setIsCustomEditorOpen] = createSignal(false);
  const [selectedModels, setSelectedModels] = createSignal<string[]>([]);
  const [selectedAgents, setSelectedAgents] = createSignal<string[]>([]);
  const [granularity, setGranularity] = createSignal<Granularity>("hourly");
  const [chartMetric, setChartMetric] = createSignal<MetricKey>("costUSD");
  const [stackBy, setStackBy] = createSignal<StackBy>(defaultStackBy);
  const [isGraphLazyLoading, setIsGraphLazyLoading] = createSignal(false);
  const [isRefreshing, setIsRefreshing] = createSignal(false);
  const [isRangeLoading, setIsRangeLoading] = createSignal(false);
  const [rangeLoadStarted, setRangeLoadStarted] = createSignal(false);
  const [isClearingCache, setIsClearingCache] = createSignal(false);
  const [cacheStatus, setCacheStatus] = createSignal<string>();
  const [isDashboardStateLoaded, setIsDashboardStateLoaded] = createSignal(false);
  const [isDashboardStatePersistenceEnabled, setIsDashboardStatePersistenceEnabled] =
    createSignal(false);
  const [selectedMachines, setSelectedMachines] = createSignal<string[]>([]);
  const [pendingMachineSelection, setPendingMachineSelection] = createSignal<string[]>();
  const [selectedDirectories, setSelectedDirectories] = createSignal<Record<string, string[]>>({});
  const [directoryRenameEditor, setDirectoryRenameEditor] = createSignal<DirectoryRenameEditor>();
  const [confirmedSubdirectories, setConfirmedSubdirectories] = createSignal<SubdirectoriesResponse>();
  const [directoryCatalogWarning, setDirectoryCatalogWarning] = createSignal<string>();
  const [areAllMachinesVisible, setAreAllMachinesVisible] = createSignal(false);
  const [expandedDirectoryMachines, setExpandedDirectoryMachines] = createSignal<string[]>([]);
  const [expandedDirectoryLists, setExpandedDirectoryLists] = createSignal<string[]>([]);
  const [directoryFilterQueries, setDirectoryFilterQueries] = createSignal<Record<string, string>>({});
  const [isMachineGraphRendering, setIsMachineGraphRendering] = createSignal(false);
  const [machineFormOpen, setMachineFormOpen] = createSignal(false);
  const [machineDraft, setMachineDraft] = createSignal<MachineDraft>(emptyMachineDraft());
  const [editingMachineID, setEditingMachineID] = createSignal<string>();
  const [machineError, setMachineError] = createSignal<string>();
  const [machineFieldErrors, setMachineFieldErrors] = createSignal<Record<string, string>>({});
  const [machineActions, setMachineActions] = createSignal<Record<string, { message: string; failed: boolean }>>({});
  const [machineActionInFlight, setMachineActionInFlight] = createSignal<Record<string, boolean>>({});
  const [sidebarCollapsed, setSidebarCollapsed] = createSignal(false);
  const [headerCollapsed, setHeaderCollapsed] = createSignal(false);
  const [colorScheme, setColorScheme] = createSignal<ColorScheme>(readStoredColorScheme());
  const toggleColorScheme = () => {
    const next = oppositeColorScheme(colorScheme());
    setColorScheme(next);
    applyColorScheme(document.documentElement, next);
    storeColorScheme(next);
  };
  const [machinesResource, { refetch: refreshMachines }] = createResource(() => getJSON<MachinesResponse>("/api/machines"));
  const machines = shieldResource(machinesResource);
  const metadataCleanupWarning = createMemo(() =>
    machineMetadataCleanupWarning(machines()?.metadataCleanupPendingMachineIds ?? []));
  const [chartColorsResource] = createResource(() => getJSON<ChartColorsResponse>("/api/chart-colors"));
  const chartColors = shieldResource(chartColorsResource);
  const requestedMachineScope = createMemo(() => requestedMachineIDs(machines()?.machines ?? [], selectedMachines()));
  const machineSuffix = createMemo(() => isDashboardStateLoaded() && machines() != null
    ? machineQuery(requestedMachineScope())
    : undefined);
  const withMachine = (path: string) => {
    const suffix = machineSuffix();
    return suffix == null || suffix.length === 0 ? path : `${path}${path.includes("?") ? "&" : "?"}${suffix}`;
  };
  const machineStatusPath = createMemo(() => machineSuffix() == null ? undefined : withMachine("/api/machine-status"));
  const [machineStatusesResource, { refetch: refreshMachineStatuses }] = createResource(
    machineStatusPath,
    (path) => getJSON<MachineStatusResponse>(path)
  );
  const machineStatuses = shieldResource(machineStatusesResource);

  const subdirectoriesPath = createMemo(() => machineSuffix() == null
    ? undefined
    : "/api/subdirectories?machine=all");
  const [subdirectoriesResource, {
    refetch: refreshSubdirectories,
    mutate: mutateSubdirectories,
  }] = createResource(
    subdirectoriesPath,
    (path) => getJSON<SubdirectoriesResponse>(path),
  );
  const subdirectoriesResult = shieldResource(subdirectoriesResource);
  const subdirectories = () => directoryCatalogWithConfirmedFallback(
    subdirectoriesResult(),
    confirmedSubdirectories(),
  );
  createEffect(() => {
    const catalog = subdirectoriesResult();
    if (catalog == null) return;
    setConfirmedSubdirectories(catalog);
    if (!subdirectoriesResult.loading) setDirectoryCatalogWarning(undefined);
  });
  const periodPath = createMemo(() => machineSuffix() == null ? undefined : range() === "custom"
    ? dashboardDataPath(
      `/api/metrics?range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}`,
      requestedMachineScope(),
      selectedDirectories(),
    )
    : dashboardDataPath(`/api/metrics?range=${range()}`, requestedMachineScope(), selectedDirectories()));
  const [periodResource, { refetch: refreshPeriod }] = createResource(periodPath, (path) => getJSON<MetricsResponse>(path));
  const period = shieldResource(periodResource);
  const costPath = createMemo(() => {
    if (machineSuffix() == null) return undefined;
    const path = range() === "custom"
      ? `/api/cost-series?granularity=${granularity()}&range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}`
      : `/api/cost-series?granularity=${granularity()}&range=${range()}`;
    return costSeriesDataPath(path, requestedMachineScope(), selectedDirectories(), stackBy());
  });
  const [costSeriesResource, { refetch: refreshCostSeries }] = createResource(costPath, getCostSeriesState);
  const costSeries = shieldResource(costSeriesResource);
  const budgetPath = createMemo(() => machineSuffix() == null
    ? undefined
    : dashboardDataPath("/api/budget", requestedMachineScope(), selectedDirectories()));
  const [budgetResource, { refetch: refreshBudget }] = createResource(budgetPath, (path) => getJSON<BudgetResponse>(path));
  const budget = shieldResource(budgetResource);
  const loadStatusPath = createMemo(() => {
    if (machineSuffix() == null) return undefined;
    return range() === "custom"
      ? withMachine(`/api/load-status?range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}`)
      : withMachine(`/api/load-status?range=${range()}`);
  });
  const [loadStatusResource, { refetch: refreshLoadStatus }] = createResource(
    loadStatusPath,
    (path) => getJSON<LoadStatusResponse>(path)
  );
  const loadStatus = shieldResource(loadStatusResource);

  const selectableMachines = createMemo(() => (machines()?.machines ?? []).filter((machine) => machine.enabled));
  const visibleMachines = createMemo(() => visibleMachineItems(selectableMachines(), areAllMachinesVisible()));
  const directoriesByMachine = createMemo(() => new Map(
    (subdirectories()?.machines ?? []).map((item) => [item.machine, item.directories]),
  ));
  const directoryLabelsByMachine = createMemo(() =>
    directoryLabels(subdirectories()?.machines ?? []));
  const selectedDirectoryCount = createMemo(() =>
    Object.values(selectedDirectories()).reduce((total, directories) => total + directories.length, 0));
  const allMachinesSelected = createMemo(() =>
    selectableMachines().length > 0
      && requestedMachineScope().length === selectableMachines().length
      && selectedDirectoryCount() === 0);
  const activeFilterDimensionCount = createMemo(() => {
    const modelFiltered = selectedModels().length > 0 && selectedModels().length < models().length;
    const agentFiltered = selectedAgents().length > 0 && selectedAgents().length < agents().length;
    const machineFiltered = requestedMachineScope().length < selectableMachines().length;
    const directoriesFiltered = requestedMachineScope().some((machine) => {
      const selected = selectedDirectories()[machine] ?? [];
      const available = directoriesByMachine().get(machine)?.length ?? 0;
      return selected.length > 0 && selected.length < available;
    });
    return Number(modelFiltered) + Number(agentFiltered) + Number(machineFiltered) + Number(directoriesFiltered);
  });
  const machineFilteredRows = createMemo(() => (period()?.rows ?? [])
    .filter((row) => requestedMachineScope().includes(row.machine)));
  const machineFilteredCostRows = createMemo(() => (costSeries()?.rows ?? [])
    .filter((row) => requestedMachineScope().includes(row.machine)));
  const models = createMemo(() => [...new Set(machineFilteredRows().map((row) => row.model))].sort());
  const agents = createMemo(() => [...new Set(machineFilteredRows().map((row) => row.agent))].sort());
  const chartModels = createMemo(() => new Set(machineFilteredCostRows().map((row) => row.model)));
  const activeChartColors = () => chartColors()?.[colorScheme()];
  const modelColor = createMemo(() => allocateModelColors(models(), activeChartColors()?.models, colorScheme()));
  const colorForMachine = (machine: string) => seriesColor("machine", machine, activeChartColors()?.machines, colorScheme());
  const colorForModel = (model: string) => modelColor()(model);
  const colorForSeries = (identity: string): string => {
    switch (stackBy()) {
      case "model": return modelColor()(identity);
      case "machine": return colorForMachine(identity);
      case "subdirectory": return seriesColor("subdirectory", identity, undefined, colorScheme());
      case "modelEffort": {
        const { model, effort } = modelEffortParts(identity);
        return effortShade(modelColor()(model), effort, colorScheme());
      }
    }
  };
  const subdirectorySeriesLabel = (row: CostRow) => {
    const machine = selectableMachines().find((item) => item.id === row.machine);
    return directorySeriesDisplayLabel(
      row,
      row.directory == null ? undefined : directoryLabelsByMachine().get(row.machine)?.get(row.directory),
      machine?.displayName,
      requestedMachineScope().length > 1,
    );
  };
  const estimatedModels = createMemo(() => new Set(machineFilteredCostRows()
    .filter((row) => row.dataQuality === "sessionEstimated")
    .map((row) => row.model)));
  const unavailableModelReason = (model: string) => {
    if (chartModels().has(model)) return undefined;
    if (granularity() === "daily") return `${model} has no daily usage in the selected period.`;
    return `${model} has no timestamped usage events or session data for the selected period. Choose Daily to view its aggregate usage.`;
  };
  const modelSourceNote = (model: string) => unavailableModelReason(model)
    ?? (estimatedModels().has(model) ? `${model} uses session-level timing for part or all of this period, so sub-daily placement is estimated.` : undefined);
  createEffect(() => {
    if (!isDashboardStateLoaded() || machines() == null) return;
    const enabledIDs = new Set(selectableMachines().map((machine) => machine.id));
    const normalized = selectedMachines().filter((id) => enabledIDs.has(id));
    const replacement = normalized.length > 0 ? normalized : requestedMachineScope();
    if (replacement.length === selectedMachines().length
        && replacement.every((id, index) => id === selectedMachines()[index])) return;
    setSelectedMachines(replacement);
  });
  createEffect(() => {
    const checked = directorySelectionMachineScope(
      requestedMachineScope(),
      pendingMachineSelection(),
    );
    setSelectedDirectories((current) => {
      const next = clearUncheckedDirectorySelections(current, checked);
      return JSON.stringify(next) === JSON.stringify(current) ? current : next;
    });
  });
  createEffect(() => {
    if (!isDashboardStateLoaded() || period()?.range !== range() || costSeries()?.range !== range() || costSeries()?.granularity !== granularity()) return;
    const available = chartModels();
    setSelectedModels((current) => {
      const next = current.filter((model) => available.has(model));
      return next.length === current.length ? current : next;
    });
  });
  createEffect(() => {
    if (!isDashboardStateLoaded() || period()?.range !== range()) return;
    const available = new Set(agents());
    setSelectedAgents((current) => {
      const next = current.filter((agent) => available.has(agent));
      return next.length === current.length ? current : next;
    });
  });
  const filteredRows = createMemo(() => machineFilteredRows().filter((row) =>
    (selectedModels().length === 0 || selectedModels().includes(row.model)) &&
    (selectedAgents().length === 0 || selectedAgents().includes(row.agent))));
  const filteredCostRows = createMemo(() => machineFilteredCostRows().filter((row) =>
    (selectedModels().length === 0 || selectedModels().includes(row.model)) &&
    (selectedAgents().length === 0 || selectedAgents().includes(row.agent))));
  const chartDataQuality = createMemo(() => {
    if (granularity() === "daily") return "Daily aggregate";
    const qualities = new Set(filteredCostRows().map((row) => row.dataQuality));
    if (qualities.has("timestamped") && qualities.has("sessionEstimated")) return "Timestamped + session estimate";
    if (qualities.has("sessionEstimated")) return "Session estimate";
    return "Timestamped events";
  });
  // Cards and graph must describe the same view. Sub-daily series use session
  // timing while daily series use daily aggregates, so totals follow the
  // currently selected cost series instead of the separate metrics response.
  const total = (key: MetricKey) => currentViewMetricTotal(filteredCostRows(), key);
  const chartTotal = createMemo(() => filteredCostRows().reduce((sum, row) => sum + metricValue(row, chartMetric()), 0));
  const chartMetricLabel = createMemo(() => chartMetrics.find(([value]) => value === chartMetric())?.[1] ?? "Cost");
  const stackLabel = createMemo(() => ({
    model: "model",
    machine: "machine",
    subdirectory: "subdirectory",
    modelEffort: "model + effort",
  })[stackBy()]);
  const chartTitle = createMemo(() => `${chartMetricLabel()} over time by ${stackLabel()}`);
  const formattedChartTotal = createMemo(() => chartMetric() === "costUSD" ? currency.format(chartTotal()) : integer.format(chartTotal()));
  const rangeLabel = createMemo(() => rangeSummaryLabel(range(), appliedCustomRange()));
  const filterLabel = createMemo(() => selectedModels().length === 0 ? "All models" : `${selectedModels().length} selected`);
  const periodAvailabilityError = createMemo(() => availabilityErrorCode(period.error) != null);
  const budgetAvailabilityError = createMemo(() => availabilityErrorCode(budget.error) != null);
  const errorMessage = createMemo(() => dashboardErrorMessage(period.error, costSeries.error, budget.error));
  const selectedMachineIDs = createMemo(() => new Set(requestedMachineScope()));
  const visibleStatuses = createMemo(() => (machineStatuses()?.machines ?? [])
    .filter((status) => selectedMachineIDs().has(status.id) && status.collectionState !== "healthy"));
  const statusByMachine = createMemo(() => new Map(
    (machineStatuses()?.machines ?? []).map((status) => [status.id, status])
  ));
  const latestEventMarkers = createMemo<MachineLatestEvent[]>(() => (costSeries()?.machineLatestEvents ?? [])
    .filter((marker) => selectedMachineIDs().has(marker.machine)));
  const visibleDataGaps = createMemo(() => (costSeries()?.scope.lastHourDataGaps ?? [])
    .filter((gap) => selectedMachineIDs().has(gap.machine)));
  const markerStatusLabel = (marker: MachineLatestEvent) => {
    const unavailableSince = costSeries()?.scope.machineAvailability
      .find((availability) => availability.machine === marker.machine)?.unavailableSince;
    if (marker.markerState === "noEvent") return "No event";
    if (marker.markerState === "stale") return `Stale since ${timestampLabel(unavailableSince ?? marker.latestEventAt)}`;
    if (marker.markerState === "unavailable") return `Unavailable since ${timestampLabel(unavailableSince)}`;
    return `Latest ${timestampLabel(marker.latestEventAt)}`;
  };
  const currentScope = createMemo(() => period()?.scope ?? costSeries()?.scope);
  const visibleExcludedMachineIDs = createMemo(() => (currentScope()?.excludedFromCurrentTotalsMachineIds ?? [])
    .filter((id) => selectedMachineIDs().has(id)));
  const isInitialLoading = createMemo(() =>
    (period() == null && !periodAvailabilityError())
    || costSeries() == null
    || (budget() == null && !budgetAvailabilityError()));
  const isBlockingLoading = createMemo(() => shouldBlockDashboard({
    isInitialLoading: isInitialLoading(),
    isRangeLoading: isRangeLoading(),
    isFetching: period.loading || costSeries.loading || budget.loading,
    hasFailedRequest: period.error != null || costSeries.error != null || budget.error != null,
    loadStatus: loadStatus(),
  }));
  const isBackgroundLoading = createMemo(() => !isBlockingLoading() &&
    (loadStatus()?.isLoading || isRefreshing() || period.loading || costSeries.loading || budget.loading));
  const visibleRangeLoad = createMemo(() => period()?.rangeLoad ?? costSeries()?.rangeLoad);
  const toggleModel = (model: string) => setSelectedModels((current) => current.includes(model)
    ? current.filter((item) => item !== model)
    : [...current, model]);
  let machineRenderStartFrame: number | undefined;
  let machineRenderApplyFrame: number | undefined;
  let machineRenderEndFrame: number | undefined;
  const updateMachineSelection = (update: (current: string[]) => string[]) => {
    const current = pendingMachineSelection() ?? selectedMachines();
    const next = update(current);
    if (next.length === current.length && next.every((item, index) => item === current[index])) return;
    setPendingMachineSelection(next);
    if (machineRenderStartFrame != null) window.cancelAnimationFrame(machineRenderStartFrame);
    if (machineRenderApplyFrame != null) window.cancelAnimationFrame(machineRenderApplyFrame);
    if (machineRenderEndFrame != null) window.cancelAnimationFrame(machineRenderEndFrame);
    setIsMachineGraphRendering(true);
    machineRenderStartFrame = window.requestAnimationFrame(() => {
      machineRenderApplyFrame = window.requestAnimationFrame(() => {
        setSelectedMachines(pendingMachineSelection() ?? []);
        setPendingMachineSelection(undefined);
        machineRenderEndFrame = window.requestAnimationFrame(() => setIsMachineGraphRendering(false));
      });
    });
  };
  const toggleSelectedMachine = (machine: string) => updateMachineSelection((current) => {
    const effective = current.length === 0 ? requestedMachineScope() : current;
    const next = toggledMachineSelection(effective, machine);
    return next.length === 0 ? effective : next;
  });
  const selectWholeMachine = (machine: string) => {
    const isWholeMachineSelected = wholeMachineSelected(
      requestedMachineScope(),
      selectedDirectories(),
      machine,
    );
    setSelectedDirectories((current) =>
      Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine)));
    if (!isWholeMachineSelected && selectedMachineIDs().has(machine)) return;
    toggleSelectedMachine(machine);
  };
  const selectAllMachines = () => {
    setSelectedDirectories({});
    updateMachineSelection(() => selectableMachines().map((machine) => machine.id));
  };
  const toggleDirectoryExpansion = (machine: string) => {
    setExpandedDirectoryMachines((current) => current.includes(machine)
      ? current.filter((id) => id !== machine)
      : [...current, machine]);
  };
  const toggleDirectoryListExpansion = (machine: string) => {
    setExpandedDirectoryLists((current) => current.includes(machine)
      ? current.filter((id) => id !== machine)
      : [...current, machine]);
  };
  const updateDirectoryFilterQuery = (machine: string, query: string) => {
    setDirectoryFilterQueries((current) => query.length === 0
      ? Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine))
      : { ...current, [machine]: query });
  };
  const selectAllDirectories = (machine: string) => {
    if (!selectedMachineIDs().has(machine)) {
      updateMachineSelection((current) => [...current, machine]);
    }
    setSelectedDirectories((current) =>
      Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine)));
  };
  const clearAllDirectories = (machine: string) => {
    setSelectedDirectories((current) =>
      Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine)));
    if (selectedMachineIDs().has(machine)) toggleSelectedMachine(machine);
  };
  const toggleDirectory = (
    machine: string,
    directory: string,
    directories: readonly string[],
  ) => {
    const machineIsSelected = selectedMachineIDs().has(machine);
    const wholeMachineIsSelected = wholeMachineSelected(
      requestedMachineScope(),
      selectedDirectories(),
      machine,
    );
    if (!machineIsSelected) {
      updateMachineSelection((current) => [...current, machine]);
    }
    setSelectedDirectories((current) => {
      const next = toggledDirectoryItems(
        directories,
        current[machine] ?? [],
        directory,
        wholeMachineIsSelected,
      );
      if (next.length === 0) {
        if (machineIsSelected) toggleSelectedMachine(machine);
        return Object.fromEntries(
          Object.entries(current).filter(([id]) => id !== machine),
        );
      }
      if (next.length === new Set(directories).size) {
        return Object.fromEntries(
          Object.entries(current).filter(([id]) => id !== machine),
        );
      }
      return { ...current, [machine]: next };
    });
  };
  const explicitDirectoryName = (machine: string, directory: string) =>
    subdirectories()?.machines.find((item) => item.machine === machine)?.names?.[directory];
  const directoryEditorFor = (machine: string, directory: string) => {
    const editor = directoryRenameEditor();
    return editor?.machine === machine && editor.directory === directory ? editor : undefined;
  };
  const startDirectoryRename = (machine: string, directory: string) => {
    setDirectoryRenameEditor(beginDirectoryRename(
      machine,
      directory,
      explicitDirectoryName(machine, directory),
    ));
  };
  const saveDirectoryRename = async (machine: string, directory: string) => {
    const editor = directoryEditorFor(machine, directory);
    if (editor == null || editor.saving) return;
    await submitDirectoryRename(editor, {
      rename: renameSubdirectory,
      setEditor: (next) => setDirectoryRenameEditor((current) =>
        current?.machine === machine && current.directory === directory ? next : current),
      currentCatalog: subdirectories,
      applyConfirmedCatalog: (catalog) => {
        setConfirmedSubdirectories(catalog);
        mutateSubdirectories(() => catalog);
      },
      refreshCatalog: refreshSubdirectories,
      reportCatalogRefreshFailure: (_error, kind) => {
        setDirectoryCatalogWarning(directoryCatalogRefreshWarning(kind));
      },
    });
  };
  const handleDirectoryRenameInteraction = (
    machine: string,
    directory: string,
    interaction: DirectoryRenameInteraction,
  ) => {
    const intent = directoryRenameIntent(interaction);
    if (intent === "save") {
      void saveDirectoryRename(machine, directory);
    } else if (intent === "cancel") {
      setDirectoryRenameEditor(undefined);
    }
  };
  const toggleAgent = (agent: string) => {
    const nextAgents = selectedAgents().includes(agent)
      ? selectedAgents().filter((item) => item !== agent)
      : [...selectedAgents(), agent];
    setSelectedAgents(nextAgents);
    if (nextAgents.length === 0) {
      setSelectedModels([]);
      return;
    }
    const selectable = chartModels();
    setSelectedModels([...new Set(machineFilteredRows()
      .filter((row) => nextAgents.includes(row.agent) && selectable.has(row.model))
      .map((row) => row.model))].sort());
  };
  let refreshPromise: Promise<unknown> | undefined;
  const refresh = () => {
    if (refreshPromise) return refreshPromise;
    setIsRefreshing(true);
    refreshPromise = mutationJSON<{ status: string }>(withMachine("/api/refresh"))
      .then(() => Promise.all([
        refreshPeriod(),
        refreshCostSeries(),
        refreshBudget(),
        refreshMachineStatuses(),
        refreshSubdirectories(),
      ]))
      .finally(() => {
        refreshPromise = undefined;
        setIsRefreshing(false);
    });
    return refreshPromise;
  };
  const clearCache = async () => {
    if (isClearingCache() || !window.confirm("Clear cached usage aggregates? The dashboard will reload recent data.")) return;
    setIsClearingCache(true);
    setCacheStatus(undefined);
    try {
      await mutationJSON<{ status: string }>(withMachine("/api/cache"), { method: "DELETE" });
      if (configMenu) configMenu.open = false;
      const wasShowingThisWeek = range() === "week";
      setIsCustomEditorOpen(false);
      beginRangeLoad();
      let reload: Promise<unknown>;
      if (wasShowingThisWeek) {
        reload = Promise.all([refreshPeriod(), refreshCostSeries(), refreshBudget()]);
      } else {
        setRange("week");
        reload = Promise.resolve(refreshBudget());
      }
      void reload.catch((error) => setCacheStatus(error instanceof Error ? error.message : "Background reload failed."));
      setCacheStatus("Cache cleared. Reloading this week in the background.");
    } catch (error) {
      setCacheStatus(error instanceof Error ? error.message : "Cache clear failed.");
    } finally {
      setIsClearingCache(false);
    }
  };
  const currentMachineDraft = machineDraft;
  const applyMachineDraft = setMachineDraft;
  const closeMachineForm = () => {
    applyMachineDraft(emptyMachineDraft());
    setEditingMachineID(undefined);
    setMachineError(undefined);
    setMachineFieldErrors({});
    setMachineFormOpen(false);
  };
  const beginCreateMachine = () => {
    applyMachineDraft(emptyMachineDraft());
    setEditingMachineID(undefined);
    setMachineError(undefined);
    setMachineFieldErrors({});
    setMachineFormOpen(true);
  };
  const beginEditMachine = (machine: Machine) => {
    applyMachineDraft(draftFromMachine(machine));
    setEditingMachineID(machine.id);
    setMachineActions((current) => Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine.id)));
    setMachineError(undefined);
    setMachineFieldErrors({});
    setMachineFormOpen(true);
  };
  const changeMachineProxyKind = (proxyKind: MachineProxyKind) => {
    applyMachineDraft(changingProxyKind(currentMachineDraft(), proxyKind));
  };
  const reportMachineCatalogRefreshFailures = (
    failures: MachineCatalogRefreshFailure[],
  ) => {
    const catalogs = failures.map((failure) => failure.catalog).join(", ");
    setMachineError(
      `Machine change saved, but ${catalogs} could not be refreshed after retry. Reload the dashboard to reconcile.`,
    );
  };
  const saveMachine = async () => {
    setMachineError(undefined);
    setMachineFieldErrors({});
    const draft = currentMachineDraft();
    const validation = machineDraftErrors(draft);
    if (Object.keys(validation).length > 0) {
      const [field, message] = Object.entries(validation)[0];
      setMachineFieldErrors(validation);
      setMachineError(`${field}: ${message}`);
      return;
    }
    try {
      const editingID = editingMachineID();
      await saveMachineCatalog({
        draft,
        editingID,
        request: mutationJSON,
        saved: closeMachineForm,
        refreshMachines,
        refreshMachineStatuses,
        refreshSubdirectories,
        reportCatalogRefreshFailures: reportMachineCatalogRefreshFailures,
      });
    } catch (error) {
      const detail = machineSaveErrors(error);
      setMachineFieldErrors(detail.fieldErrors);
      setMachineError(detail.message);
    }
  };
  const toggleMachine = async (machine: Machine) => {
    setMachineActions((current) => Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine.id)));
    setMachineError(undefined);
    await toggleMachineCatalog({
      machine,
      request: mutationJSON,
      refreshMachines,
      refreshMachineStatuses,
      refreshSubdirectories,
      reportCatalogRefreshFailures: reportMachineCatalogRefreshFailures,
    });
  };
  const removeMachine = async (machine: Machine) => {
    if (!window.confirm(`Remove ${machine.displayName}? Its host cache will be retained.`)) return;
    setMachineError(undefined);
    await removeMachineCatalog({
      machine,
      request: mutationJSON,
      removed: (machineID) => {
        setSelectedMachines((current) => current.filter((id) => id !== machineID));
      },
      refreshMachines,
      refreshMachineStatuses,
      refreshSubdirectories,
      reportCatalogRefreshFailures: reportMachineCatalogRefreshFailures,
    });
  };
  const testMachineConnection = async (machine: Machine) => {
    if (machineActionInFlight()[machine.id]) return;
    setMachineActionInFlight((current) => ({ ...current, [machine.id]: true }));
    setMachineActions((current) => Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine.id)));
    try {
      const result = await mutationJSON<MachineConnectionTestResponse>(
        `/api/machines/${machine.id}/test-connection`,
        { method: "POST", body: "{}" },
      );
      const message = result.status === "reachable"
        ? "Connection is reachable."
        : `${result.diagnostic?.message ?? "Connection failed."} ${result.diagnostic?.remediation ?? ""}`.trim();
      setMachineActions((current) => ({ ...current, [machine.id]: { message, failed: result.status === "failed" } }));
      if (actionRefetchTargets("test-connection", result.status === "failed").includes("status")) {
        await refreshMachineStatuses();
      }
    } catch (error) {
      setMachineActions((current) => ({
        ...current,
        [machine.id]: { message: error instanceof Error ? error.message : "Connection test failed.", failed: true },
      }));
    } finally {
      setMachineActionInFlight((current) => ({ ...current, [machine.id]: false }));
    }
  };
  const refreshMachine = async (machine: Machine) => {
    if (machineActionInFlight()[machine.id]) return;
    setMachineActionInFlight((current) => ({ ...current, [machine.id]: true }));
    setMachineActions((current) => Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine.id)));
    await runMachineRefreshLifecycle({
      request: () => mutationJSON<MachineRefreshResponse>(
        `/api/machines/${machine.id}/refresh`,
        { method: "POST", body: "{}" },
      ),
      refetch: () => Promise.all([
        refreshMachineStatuses(),
        refreshPeriod(),
        refreshCostSeries(),
        refreshBudget(),
        refreshSubdirectories(),
      ]),
      setDiagnostic: (diagnostic) => {
        setMachineActions((current) => ({ ...current, [machine.id]: diagnostic }));
      },
      settled: () => {
        setMachineActionInFlight((current) => ({ ...current, [machine.id]: false }));
      },
    });
  };
  const beginRangeLoad = () => {
    setRangeLoadStarted(false);
    setIsRangeLoading(true);
  };
  const selectRange = (next: Range) => {
    if (next === range()) return;
    setIsCustomEditorOpen(false);
    beginRangeLoad();
    setRange(next);
  };
  const updateCustomStart = (value: string) => {
    if (value === customStart()) return;
    setCustomStart(value);
  };
  const updateCustomEnd = (value: string) => {
    if (value === customEnd()) return;
    setCustomEnd(value);
  };
  const applyCustomRange = () => {
    const start = customStart();
    const end = customEnd();
    if (!start || !end || start > end) return;
    const applied = appliedCustomRange();
    if (range() === "custom" && applied.start === start && applied.end === end) return;
    beginRangeLoad();
    setAppliedCustomRange({ start, end });
    setRange("custom");
  };
  const selectGranularity = (next: Granularity) => {
    if (next === granularity()) return;
    beginRangeLoad();
    setGranularity(next);
    if (next === "daily" && range() === "recent12h") selectRange("today");
  };
  createEffect(() => {
    if (!isRangeLoading()) return;
    if (period.loading || costSeries.loading) {
      setRangeLoadStarted(true);
    } else if (rangeLoadStarted()) {
      setIsRangeLoading(false);
      setRangeLoadStarted(false);
    }
  });
  let lastVisibleRangeProgress = "";
  createEffect(() => {
    const status = loadStatus();
    if (!status || !status.machines.some((machine) => machine.requestedCoverageStart != null)) return;
    const key = `${loadStatusPath()}:${status.completed}/${status.total}:${status.isLoading}`;
    if (key === lastVisibleRangeProgress) return;
    lastVisibleRangeProgress = key;
    void Promise.all([refreshPeriod(), refreshCostSeries(), refreshSubdirectories()]);
  });
  let lastTerminalRecovery = "";
  createEffect(() => {
    const status = loadStatus();
    if (!status || !["ready", "failed"].includes(status.phase)
        || period.loading || costSeries.loading || budget.loading) return;
    if (period() != null && costSeries() != null && budget() != null) return;
    const key = `${loadStatusPath()}:${status.phase}:${status.completed}/${status.total}`;
    if (key === lastTerminalRecovery) return;
    lastTerminalRecovery = key;
    void Promise.all([
      refreshPeriod(),
      refreshCostSeries(),
      refreshBudget(),
      refreshMachineStatuses(),
      refreshSubdirectories(),
    ]);
  });
  onMount(() => {
    void initializeDashboardState({
      load: () => getJSON<DashboardUIStateResponse>("/api/dashboard-state"),
      apply: (state) => {
        setRange(state.range);
        setCustomStart(state.customStart);
        setCustomEnd(state.customEnd);
        setAppliedCustomRange({ start: state.customStart, end: state.customEnd });
        setSelectedModels(state.selectedModels);
        setSelectedAgents(state.selectedAgents);
        setSelectedMachines(state.selectedMachines);
        setGranularity(state.granularity);
        setChartMetric(state.chartMetric);
        setStackBy(restoredStackBy(state.stackBy));
        const folds = restoredFoldState(state);
        setSidebarCollapsed(folds.sidebarCollapsed);
        setHeaderCollapsed(folds.headerCollapsed);
      },
      setLoaded: setIsDashboardStateLoaded,
      setPersistenceEnabled: setIsDashboardStatePersistenceEnabled,
    });
    onCleanup(() => {
      if (machineRenderStartFrame != null) window.cancelAnimationFrame(machineRenderStartFrame);
      if (machineRenderApplyFrame != null) window.cancelAnimationFrame(machineRenderApplyFrame);
      if (machineRenderEndFrame != null) window.cancelAnimationFrame(machineRenderEndFrame);
    });
  });
  // Poll /api/load-status fast (250 ms) only while work is in flight; back off to 2 s when idle so a
  // steady dashboard issues ~1 request every 2 s. beginRangeLoad/refresh/clearCache flip the signals
  // below, so fast polling resumes immediately when loading starts.
  const isPollingFast = createMemo(() => Boolean(loadStatus()?.isLoading) || isRefreshing() || isRangeLoading());
  createEffect(() => {
    const timer = window.setInterval(refreshLoadStatus, isPollingFast() ? 250 : 2_000);
    onCleanup(() => window.clearInterval(timer));
  });
  let dashboardStateSave = Promise.resolve<unknown>(undefined);
  createEffect(() => {
    if (!isDashboardStateLoaded() || !isDashboardStatePersistenceEnabled()) return;
    const state: DashboardUIState = {
      range: range(),
      customStart: appliedCustomRange().start,
      customEnd: appliedCustomRange().end,
      selectedModels: selectedModels(),
      selectedAgents: selectedAgents(),
      selectedMachines: selectedMachines(),
      granularity: granularity(),
      chartMetric: chartMetric(),
      stackBy: stackBy(),
      sidebarCollapsed: sidebarCollapsed(),
      headerCollapsed: headerCollapsed(),
    };
    dashboardStateSave = dashboardStateSave
      .catch(() => undefined)
      .then(() => requestJSON<{ status: string }>("/api/dashboard-state", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(state),
        keepalive: true,
      }));
  });
  createEffect(() => {
    const intervalSeconds = budget()?.refreshIntervalSeconds ?? 20;
    const stopAutoRefresh = startDashboardAutoRefresh({
      intervalSeconds,
      isLoading: () => Boolean(loadStatus()?.isLoading),
      refresh,
    });
    onCleanup(stopAutoRefresh);
  });

  return (
    <div class="app-shell" classList={{ "sidebar-collapsed": sidebarCollapsed() }}>
      <aside class="model-sidebar" aria-label="Usage filters">
        <PaneFoldBar
          collapsed={sidebarCollapsed()}
          onToggle={() => setSidebarCollapsed((collapsed) => !collapsed)}
          summary={activeFilterDimensionCount() === 0 ? "Filters" : `Filters · ${activeFilterDimensionCount()} active`}
        />
        <div id="usage-filters-content" class="model-sidebar-content">
        <div><p class="eyebrow">FILTER USAGE</p><h2>Models</h2></div>
        <button classList={{ "model-choice": true, active: selectedModels().length === 0 }} onClick={() => setSelectedModels([])}><span>All models</span></button>
        <div class="model-list">
          <For each={models()} fallback={<p class="muted">{period.loading ? "Loading models…" : "No models have data in this period."}</p>}>{(model) => (
            <label
              classList={{ "model-choice": true, active: selectedModels().includes(model), unavailable: unavailableModelReason(model) != null, estimated: estimatedModels().has(model) }}
              title={modelSourceNote(model) ?? model}
              data-tooltip={modelSourceNote(model)}
            >
              <input type="checkbox" disabled={unavailableModelReason(model) != null} checked={selectedModels().includes(model)} onChange={() => toggleModel(model)} />
              <span>{model}</span>
            </label>
          )}</For>
        </div>
        <div class="machine-filter">
          <div><p class="eyebrow">MACHINE SCOPE</p><h2>Machines</h2></div>
          <button
            classList={{ "model-choice": true, active: allMachinesSelected() }}
            onClick={selectAllMachines}
          ><span>All machines</span></button>
          <div class="model-list">
            <For each={visibleMachines()} fallback={<p class="muted">{machines.loading ? "Loading machines…" : "No enabled machines."}</p>}>{(machine) => (
              <div class="machine-directory-group">
                <div class="machine-choice-row">
                  <label
                    classList={{
                      "model-choice": true,
                      active: wholeMachineSelected(requestedMachineScope(), selectedDirectories(), machine.id),
                      partial: (selectedDirectories()[machine.id]?.length ?? 0) > 0,
                    }}
                    title={`Include all directories from ${machine.displayName} (${machine.id})`}
                  >
                    <input
                      type="checkbox"
                      aria-label={`Include all directories from ${machine.displayName}`}
                      checked={wholeMachineSelected(requestedMachineScope(), selectedDirectories(), machine.id)}
                      onChange={() => selectWholeMachine(machine.id)}
                    />
                    <span class="machine-choice-copy">
                      <span>{machine.displayName}</span>
                      <small>{(selectedDirectories()[machine.id]?.length ?? 0) > 0
                        ? `${selectedDirectories()[machine.id].length} selected directories`
                        : wholeMachineSelected(requestedMachineScope(), selectedDirectories(), machine.id)
                          ? "All directories"
                          : "Not included"}</small>
                    </span>
                    <Show when={statusByMachine().get(machine.id)?.collectionState === "error"
                      || statusByMachine().get(machine.id)?.collectionState === "stale"}>
                      <svg class="machine-warning-icon" viewBox="0 0 24 24" role="img" aria-label={`${machine.displayName} collection warning`}>
                        <path d="M12 3 2.7 20h18.6L12 3Z" />
                        <path d="M12 9v5M12 17.5v.5" />
                      </svg>
                    </Show>
                  </label>
                  <Show when={(directoriesByMachine().get(machine.id)?.length ?? 0) > 0}>
                    <button
                      type="button"
                      classList={{
                        "directory-disclosure": true,
                        expanded: expandedDirectoryMachines().includes(machine.id),
                      }}
                      aria-label={`${expandedDirectoryMachines().includes(machine.id) ? "Collapse" : "Expand"} directories for ${machine.displayName}`}
                      aria-expanded={expandedDirectoryMachines().includes(machine.id)}
                      aria-controls={`directories-${machine.id}`}
                      onClick={() => toggleDirectoryExpansion(machine.id)}
                    >
                      <svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 4 6 6-6 6" /></svg>
                    </button>
                  </Show>
                </div>
                <Show when={visibleDirectoryChoices(
                  expandedDirectoryMachines().includes(machine.id),
                  directoriesByMachine().get(machine.id) ?? [],
                )}>{(directories) =>
                  <div class="directory-filter-list" id={`directories-${machine.id}`}>
                    <input
                      type="search"
                      class="directory-filter-input"
                      aria-label={`Filter directories for ${machine.displayName}`}
                      placeholder="Filter directories…"
                      value={directoryFilterQueries()[machine.id] ?? ""}
                      onInput={(event) => updateDirectoryFilterQuery(
                        machine.id,
                        event.currentTarget.value,
                      )}
                    />
                    <div class="directory-bulk-actions" aria-label={`Directory selection actions for ${machine.displayName}`}>
                      <button
                        type="button"
                        disabled={!selectedMachineIDs().has(machine.id)
                          || requestedMachineScope().length <= 1}
                        onClick={() => clearAllDirectories(machine.id)}
                      >Clear all</button>
                      <button
                        type="button"
                        disabled={wholeMachineSelected(
                          requestedMachineScope(),
                          selectedDirectories(),
                          machine.id,
                        ) || allDirectoryItemsSelected(
                          directories(),
                          selectedDirectories()[machine.id] ?? [],
                        )}
                        onClick={() => selectAllDirectories(machine.id)}
                      >Select all</button>
                    </div>
                    <For each={visibleDirectoryItems(
                      filteredDirectoryItems(
                        directories(),
                        directoryFilterQueries()[machine.id] ?? "",
                        directoryLabelsByMachine().get(machine.id),
                      ),
                      selectedDirectories()[machine.id] ?? [],
                      expandedDirectoryLists().includes(machine.id)
                        || (directoryFilterQueries()[machine.id]?.trim().length ?? 0) > 0,
                      directoryLabelsByMachine().get(machine.id),
                    )} fallback={<small class="directory-filter-empty">No matching directories.</small>}>{(directory) => {
                      const label = () =>
                        directoryLabelsByMachine().get(machine.id)?.get(directory) ?? "Directory";
                      return (
                        <div classList={{
                          "directory-choice": true,
                          active: directoryItemSelected(
                            selectedDirectories()[machine.id] ?? [],
                            directory,
                            wholeMachineSelected(
                              requestedMachineScope(),
                              selectedDirectories(),
                              machine.id,
                            ),
                          ),
                        }}>
                          <input
                            type="checkbox"
                            aria-label={`Filter by ${label()}`}
                            checked={directoryItemSelected(
                              selectedDirectories()[machine.id] ?? [],
                              directory,
                              wholeMachineSelected(
                                requestedMachineScope(),
                                selectedDirectories(),
                                machine.id,
                              ),
                            )}
                            onChange={() => toggleDirectory(
                              machine.id,
                              directory,
                              directories(),
                            )}
                          />
                          <Show
                            when={directoryEditorFor(machine.id, directory)}
                            fallback={
                              <>
                                <span class="directory-label">{label()}</span>
                                <button
                                  type="button"
                                  class="directory-rename-button"
                                  aria-label={`Rename ${label()}`}
                                  onClick={() => startDirectoryRename(machine.id, directory)}
                                >Rename</button>
                              </>
                            }
                          >{(editor) => (
                            <div class="directory-rename-editor">
                              <input
                                class="directory-rename-input"
                                aria-label={`Display name for ${label()}`}
                                value={editor().value}
                                disabled={editor().saving}
                                autofocus
                                onInput={(event) => setDirectoryRenameEditor({
                                  ...editor(),
                                  value: event.currentTarget.value,
                                  error: undefined,
                                })}
                                onBlur={() => handleDirectoryRenameInteraction(
                                  machine.id,
                                  directory,
                                  { type: "blur" },
                                )}
                                onKeyDown={(event) => {
                                  const intent = directoryRenameIntent({
                                    type: "keydown",
                                    key: event.key,
                                  });
                                  if (intent != null) {
                                    event.preventDefault();
                                    handleDirectoryRenameInteraction(
                                      machine.id,
                                      directory,
                                      { type: "keydown", key: event.key },
                                    );
                                  }
                                }}
                              />
                              <button
                                type="button"
                                disabled={editor().saving}
                                onMouseDown={(event) => {
                                  event.preventDefault();
                                  handleDirectoryRenameInteraction(
                                    machine.id,
                                    directory,
                                    { type: "cancel" },
                                  );
                                }}
                              >Cancel</button>
                              <Show when={editor().error}>{(message) =>
                                <small class="directory-rename-error">{message()}</small>
                              }</Show>
                            </div>
                          )}</Show>
                        </div>
                      );
                    }}</For>
                    <Show when={(directoryFilterQueries()[machine.id]?.trim().length ?? 0) === 0
                      && directories().length > initialDirectoryLimit}>
                      <button
                        type="button"
                        class="directory-more"
                        aria-expanded={expandedDirectoryLists().includes(machine.id)}
                        aria-label={expandedDirectoryLists().includes(machine.id)
                          ? `Show fewer directories for ${machine.displayName}`
                          : `Show ${directories().length - initialDirectoryLimit} more directories for ${machine.displayName}`}
                        title={expandedDirectoryLists().includes(machine.id) ? "Show less" : "Show more"}
                        onClick={() => toggleDirectoryListExpansion(machine.id)}
                      >
                        <svg
                          classList={{ expanded: expandedDirectoryLists().includes(machine.id) }}
                          viewBox="0 0 20 20"
                          aria-hidden="true"
                        ><path d="m5 7 5 5 5-5" /></svg>
                      </button>
                    </Show>
                  </div>
                }</Show>
              </div>
            )}</For>
          </div>
          <Show when={selectableMachines().length > initialMachineLimit}>
            <button class="machine-more" onClick={() => setAreAllMachinesVisible(!areAllMachinesVisible())} aria-expanded={areAllMachinesVisible()}>
              {areAllMachinesVisible() ? "Show less" : `More (${selectableMachines().length - initialMachineLimit})`}
            </button>
          </Show>
          <Show when={directoryCatalogWarning()}>{(message) =>
            <small class="machine-warning" role="alert">{message()}</small>
          }</Show>
          <Show when={metadataCleanupWarning()}>{(message) =>
            <small class="machine-warning">{message()}</small>
          }</Show>
          <Show when={(period()?.scope.staleMachineIds.length ?? 0) > 0}><small class="machine-warning">Stale: {period()!.scope.staleMachineIds.join(", ")}</small></Show>
          <Show when={(period()?.scope.unavailableMachineIds.length ?? 0) > 0}><small class="machine-warning">Unavailable: {period()!.scope.unavailableMachineIds.join(", ")}</small></Show>
        </div>
        <div class="agent-filter"><p class="eyebrow">AGENTS</p><div class="agent-buttons toggle-group">
          <For each={agents()}>{(agent) => <button aria-pressed={selectedAgents().includes(agent) ? "true" : "false"} classList={{ active: selectedAgents().includes(agent) }} onClick={() => toggleAgent(agent)}>{agent}</button>}</For>
        </div></div>
        </div>
      </aside>

      <main class="content" aria-busy={isBlockingLoading() || isBackgroundLoading()}>
        <header classList={{ "header-collapsed": headerCollapsed() }}>
          <HeaderFoldBar
            title={<div class="dashboard-title"><h1>ccusage-gauge</h1></div>}
            rangeLabel={rangeLabel()}
            collapsed={headerCollapsed()}
            onToggle={() => setHeaderCollapsed((collapsed) => !collapsed)}
          />
          <div id="dashboard-header-content" class="header-content">
            <details class="config-menu" ref={configMenu}>
              <summary aria-label="Open dashboard configuration" title="Dashboard configuration">
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M12 15.25a3.25 3.25 0 1 0 0-6.5 3.25 3.25 0 0 0 0 6.5Z" />
                  <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-1.86 1.86-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1 1.55V20h-2.63v-.09a1.7 1.7 0 0 0-1.1-1.55 1.7 1.7 0 0 0-1.88.34l-.06.06-1.86-1.86.06-.06A1.7 1.7 0 0 0 7.87 15a1.7 1.7 0 0 0-1.55-1H6.2v-2.63h.09a1.7 1.7 0 0 0 1.55-1.1 1.7 1.7 0 0 0-.34-1.88l-.06-.06 1.86-1.86.06.06a1.7 1.7 0 0 0 1.88.34 1.7 1.7 0 0 0 1-1.55V5.2h2.63v.09a1.7 1.7 0 0 0 1.1 1.55 1.7 1.7 0 0 0 1.88-.34l.06-.06 1.86 1.86-.06.06a1.7 1.7 0 0 0-.34 1.88 1.7 1.7 0 0 0 1.55 1H20v2.63h-.09A1.7 1.7 0 0 0 19.4 15Z" />
                </svg>
              </summary>
              <div class="config-menu-panel">
                <strong>Dashboard configuration</strong>
                <p>Remove persisted usage aggregates and reload recent data.</p>
                <button disabled={isClearingCache()} onClick={clearCache}>{isClearingCache() ? "Clearing…" : "Clear cache"}</button>
                <Show when={cacheStatus()}>{(message) => <small role="status">{message()}</small>}</Show>
                <hr />
                <MachineAdminPanel
                  machines={machines()?.machines ?? []}
                  statuses={machineStatuses()?.machines ?? []}
                  actions={machineActions()}
                  inFlight={machineActionInFlight()}
                  formOpen={machineFormOpen()}
                  editingID={editingMachineID()}
                  draft={currentMachineDraft()}
                  error={machineError()}
                  fieldErrors={machineFieldErrors()}
                  onTest={testMachineConnection}
                  onRefresh={refreshMachine}
                  onEdit={beginEditMachine}
                  onToggle={toggleMachine}
                  onRemove={removeMachine}
                  onToggleForm={() => machineFormOpen() ? closeMachineForm() : beginCreateMachine()}
                  onDraft={applyMachineDraft}
                  onProxyKind={changeMachineProxyKind}
                  onSave={saveMachine}
                />
              </div>
            </details>

          <div class="period-control" aria-label="Aggregation period">
            <RangeControls
              range={range}
              select={selectRange}
              isCustomEditorOpen={isCustomEditorOpen}
              setIsCustomEditorOpen={setIsCustomEditorOpen}
              customStart={customStart}
              customEnd={customEnd}
              updateCustomStart={updateCustomStart}
              updateCustomEnd={updateCustomEnd}
              applyCustomRange={applyCustomRange}
            />
            <span classList={{ "background-refresh-status": true, visible: isBackgroundLoading() }} role="status" aria-live="polite">
              <span class="refresh-spinner" aria-hidden="true" />
              {loadStatus()?.isLoading
                ? `${loadStatus()!.message} · ${loadStatus()!.completed}/${loadStatus()!.total} · ${machineProgressDetail(loadStatus())}`
                : "Updating…"}
            </span>

          </div>
          </div>
        </header>

        <Show when={!errorMessage()} fallback={<section class="error"><span>{errorMessage()}</span><button onClick={refresh}>Retry</button></section>}>
          <Show when={!isBlockingLoading()} fallback={<LoadingState status={loadStatus()} />}>
            <Show when={visibleRangeLoad()?.isPartial}>
              <section class="partial-range-status" role="status" aria-live="polite">
                <strong>Partial usage data</strong>
                <span>
                  Loaded {visibleRangeLoad()?.completed ?? 0}/{Math.max(visibleRangeLoad()?.total ?? 1, 1)}
                  {" "}range chunks. Charts and totals update as background loading completes.
                </span>
                <progress
                  value={visibleRangeLoad()?.completed ?? 0}
                  max={Math.max(visibleRangeLoad()?.total ?? 1, 1)}
                  aria-label="Selected range loading progress"
                />
              </section>
            </Show>
            <Show when={visibleStatuses().length > 0 || visibleExcludedMachineIDs().length > 0}>
              <MachineHealthPanel
                statuses={visibleStatuses()}
                excludedMachineIDs={visibleExcludedMachineIDs()}
              />
            </Show>
            <section class="stats metric-stats">
            <article><span>Cost for current view</span><strong>{currency.format(total("costUSD"))}</strong><small>{rangeLabel()} · {filterLabel()}</small></article>
            <article><span>Total tokens</span><strong>{integer.format(total("totalTokens"))}</strong><small>All token categories</small></article>
            <article><span>Input / output</span><strong>{integer.format(total("inputTokens"))} / {integer.format(total("outputTokens"))}</strong><small>Prompt and generated</small></article>
            <article><span>Cache read / creation</span><strong>{integer.format(total("cacheReadTokens"))} / {integer.format(total("cacheCreationTokens"))}</strong><small>Reported by ccusage</small></article>
            <div class="stats-actions">
              <button
                classList={{ "refresh-icon": true, refreshing: isRefreshing() }}
                onClick={refresh}
                aria-label="Refresh usage data"
                aria-busy={isRefreshing()}
                title="Refresh usage data"
              >
                <svg viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M20 11a8 8 0 0 0-14.9-4M4 4v6h6M4 13a8 8 0 0 0 14.9 4M20 20v-6h-6" />
                </svg>
              </button>
              <ThemeToggle scheme={colorScheme()} onToggle={toggleColorScheme} />

            </div>
            </section>

            <section class="panel usage-panel">
            <div class="panel-title"><div><p class="eyebrow">AGGREGATED USAGE</p><div class="chart-heading"><h2>{chartTitle()}</h2>
              <span class="data-quality-badge">{chartDataQuality()}</span>
              <Show when={isGraphLazyLoading() || isMachineGraphRendering()}><span class="graph-loading-status" role="status" aria-label={isMachineGraphRendering() ? "Rendering selected machine data" : "Rendering earlier graph data"}><span class="graph-loading-spinner" aria-hidden="true" /></span></Show>
            </div></div>
              <div class="granularity-control toggle-group" aria-label="Graph aggregation">
                <div><button aria-pressed={granularity() === "15min" ? "true" : "false"} classList={{ active: granularity() === "15min" }} onClick={() => selectGranularity("15min")}>15 min</button><button aria-pressed={granularity() === "hourly" ? "true" : "false"} classList={{ active: granularity() === "hourly" }} onClick={() => selectGranularity("hourly")}>Hourly</button><button aria-pressed={granularity() === "6hour" ? "true" : "false"} classList={{ active: granularity() === "6hour" }} onClick={() => selectGranularity("6hour")}>6 hour</button><button aria-pressed={granularity() === "daily" ? "true" : "false"} classList={{ active: granularity() === "daily" }} onClick={() => selectGranularity("daily")}>Daily</button></div>
                <label class="metric-selector">Metric
                  <select value={chartMetric()} onChange={(event) => setChartMetric(event.currentTarget.value as MetricKey)}>
                    <For each={chartMetrics}>{([value, label]) => <option value={value}>{label}</option>}</For>
                  </select>
                </label>
                <div class="stack-toggle toggle-group" role="group" aria-label="Stack by">
                  <span>Stack by</span>
                  <button aria-pressed={stackBy() === "model" ? "true" : "false"} classList={{ active: stackBy() === "model" }} onClick={() => setStackBy("model")}>Model</button>
                  <button aria-pressed={stackBy() === "machine" ? "true" : "false"} classList={{ active: stackBy() === "machine" }} onClick={() => setStackBy("machine")}>Machine</button>
                  <button aria-pressed={stackBy() === "subdirectory" ? "true" : "false"} classList={{ active: stackBy() === "subdirectory" }} onClick={() => setStackBy("subdirectory")}>Subdirectory</button>
                  <button aria-pressed={stackBy() === "modelEffort" ? "true" : "false"} classList={{ active: stackBy() === "modelEffort" }} onClick={() => setStackBy("modelEffort")}>Model + effort</button>
                </div>
                <strong>{formattedChartTotal()}</strong>
              </div>
            </div>
            <UsageChart
              rows={filteredCostRows()}
              granularity={granularity()}
              label={rangeLabel()}
              metric={chartMetric()}
              timelineStart={costSeries()?.timelineStart}
              timelineEndExclusive={costSeries()?.timelineEndExclusive}
              onLazyLoadingChange={setIsGraphLazyLoading}
              stackBy={stackBy()}
              colorForSeries={colorForSeries}
              stackLabel={stackLabel()}
              metricLabel={chartMetricLabel()}
              subdirectoryLabel={subdirectorySeriesLabel}
              markers={latestEventMarkers()}
              gaps={visibleDataGaps()}
              evaluatedAt={costSeries()?.scope.evaluatedAt}
            />
            <Show when={latestEventMarkers().length > 0 || visibleDataGaps().length > 0}>
              <div class="machine-event-markers" aria-label="Per-machine latest-event markers and last-hour gaps">
                <For each={latestEventMarkers()}>{(marker) => (
                  <span classList={{ "machine-event-marker": true, [marker.markerState]: true }}>
                    <b>{marker.machine}</b>: {markerStatusLabel(marker)}
                    {marker.inLastHour || marker.latestEventAt == null ? "" : " · outside last hour"}
                  </span>
                )}</For>
                <For each={visibleDataGaps()}>{(gap) => (
                  <span class="machine-gap-marker"><b>{gap.machine}</b>: data gap {timestampLabel(gap.startAt)} – {timestampLabel(gap.endAt)}</span>
                )}</For>
              </div>
            </Show>
            </section>

            <section class="panel breakdown-panel">
            <div class="panel-title"><div><p class="eyebrow">PERIOD BREAKDOWN</p><div class="chart-heading"><h2>{chartMetricLabel()} by host and model</h2>
              <span class="data-quality-badge">{rangeLabel()}</span>
            </div></div></div>
            <div class="breakdown-grid">
              <div class="breakdown-col">
                <h3 class="breakdown-title">By host</h3>
                <BreakdownBars rows={filteredCostRows()} metric={chartMetric()} keyOf={(row) => row.machine} colorFor={colorForMachine} label="per host" />
              </div>
              <div class="breakdown-col">
                <h3 class="breakdown-title">By model</h3>
                <BreakdownBars rows={filteredCostRows()} metric={chartMetric()} keyOf={(row) => row.model} colorFor={colorForModel} label="per model" />
              </div>
            </div>
            </section>

            <section class="panel block-panel">
            <div class="panel-title"><div><p class="eyebrow">CCUSAGE BREAKDOWNS</p><h2>Daily agent and model detail</h2></div></div>
            <div class="metric-table" role="table">
              <div classList={{ "metric-row": true, "metric-head": true, "with-machine": selectedMachines().length !== 1 }} role="row"><span>Date</span><Show when={selectedMachines().length !== 1}><span>Machine</span></Show><span>Agent</span><span>Model</span><span>Cost</span><span>Total tokens</span></div>
              <For each={filteredRows().slice().reverse()} fallback={<p class="empty compact">No matching metric rows.</p>}>{(row) => (
                <div classList={{ "metric-row": true, "with-machine": selectedMachines().length !== 1 }} role="row"><time>{row.date}</time><Show when={selectedMachines().length !== 1}><span class="machine-tag">{row.machine}</span></Show><span class="agent-tag">{row.agent}</span><strong title={row.model}>{row.model}</strong><span>{currency.format(row.costUSD)}</span><span>{integer.format(row.totalTokens)}</span></div>
              )}</For>
            </div>
            </section>

            <section class="budget-note">
              Menu budget: {currency.format(budget()?.spentUSD ?? 0)} in selected period · {budget()?.usagePercentage == null ? "No budget set" : `${percentage.format(budget()!.usagePercentage!)}% used`} · {budget()?.remainingUSD == null ? "No remaining amount" : `${currency.format(budget()!.remainingUSD!)} remaining`}
            </section>
          </Show>
        </Show>
      </main>
    </div>
  );
}
