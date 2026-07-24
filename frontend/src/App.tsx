import { For, Show, createEffect, createMemo, createResource, createSignal, onCleanup, onMount } from "solid-js";
import { type BudgetResponse, type ChartColorsResponse, type CostRow, type DashboardUIState, type DashboardUIStateResponse, type LoadStatusResponse, type Machine, type MachineConnectionTestResponse, type MachineDataGap, type MachineLatestEvent, type MachineRefreshResponse, type MachinesResponse, type MachineStatusResponse, type MetricRow, type MetricsResponse, getJSON, mutationJSON, requestJSON } from "./api";
import { runMachineRefreshLifecycle } from "./machineActions";
import { actionRefetchTargets } from "./machineObservability";
import { availabilityErrorCode, dashboardErrorMessage, getCostSeriesState } from "./costSeriesState";
import { changingProxyKind, draftFromMachine, emptyMachineDraft, machineDraftErrors, machineRequestBody, type MachineDraft, type MachineProxyKind } from "./machineForm";
import { BreakdownBars, LoadingState, MachineHealthPanel, type MetricKey } from "./DashboardComponents";
import { MachineAdminPanel } from "./MachineAdminPanel";
import {
  initialMachineLimit,
  machineProgressDetail,
  machineQuery,
  requestedMachineIDs,
  toggledMachineSelection,
  visibleMachineItems,
} from "./machineScope";
import { type ColorScheme, seriesColor } from "./seriesColors";
import { alignedBucketStart, axisCurrency, bucketMilliseconds, chartDateLabel, clippedInterval, nextBucket, niceChartMaximum } from "./usageChartGeometry";

type QuickRange = "recent12h" | "today" | "yesterday" | "week" | "month";
type Range = QuickRange | "custom";
type Granularity = "15min" | "hourly" | "6hour" | "daily";

const quickRanges: Array<[QuickRange, string]> = [
  ["recent12h", "Last 12 hours"], ["today", "Today"], ["yesterday", "Yesterday"], ["week", "This week"], ["month", "This month"]
];
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

const chartHeight = 360;
const chartMargin = { top: 16, right: 78, bottom: 54, left: 78 };
const yTickCount = 4;
const lazyRenderWindowMilliseconds = 12 * 60 * 60 * 1_000;
const chartSlotWidths: Record<Granularity, number> = { "15min": 32, hourly: 96, "6hour": 112, daily: 72 };
function Bars(props: {
  rows: CostRow[];
  granularity: Granularity;
  label: string;
  metric: MetricKey;
  timelineStart?: string;
  timelineEndExclusive?: string;
  onLazyLoadingChange: (isLoading: boolean) => void;
  stackBy: "model" | "machine";
  colorScheme: ColorScheme;
  colorOverrides?: Readonly<Record<string, string>>;
  markers: MachineLatestEvent[];
  gaps: MachineDataGap[];
  evaluatedAt?: string;
}) {
  const [hoveredSegment, setHoveredSegment] = createSignal<{ bucketIndex: number; model: string } | null>(null);
  const [loadedAfter, setLoadedAfter] = createSignal(Number.NEGATIVE_INFINITY);
  const [isLoadingEarlier, setIsLoadingEarlier] = createSignal(false);
  let chartElement: HTMLDivElement | undefined;
  let lazyLoadFrame: number | undefined;
  let renderFrame: number | undefined;
  let completionFrame: number | undefined;
  const cancelScheduledLazyLoad = () => {
    if (lazyLoadFrame != null) window.cancelAnimationFrame(lazyLoadFrame);
    if (renderFrame != null) window.cancelAnimationFrame(renderFrame);
    if (completionFrame != null) window.cancelAnimationFrame(completionFrame);
    lazyLoadFrame = undefined;
    renderFrame = undefined;
    completionFrame = undefined;
  };
  const seriesName = (row: CostRow) => props.stackBy === "machine" ? row.machine : row.model;
  const models = createMemo(() => [...new Set(props.rows.map(seriesName))].sort());
  const colorForSeries = (series: string) => seriesColor(props.colorScheme, props.stackBy, series, props.colorOverrides);
  const occupiedPoints = createMemo(() => {
    const grouped = new Map<string, Map<string, number>>();
    for (const row of props.rows) {
      const bucket = new Date(row.timestamp);
      if (props.granularity === "15min") bucket.setMinutes(Math.floor(bucket.getMinutes() / 15) * 15, 0, 0);
      else if (props.granularity === "hourly") bucket.setMinutes(0, 0, 0);
      else if (props.granularity === "6hour") bucket.setHours(Math.floor(bucket.getHours() / 6) * 6, 0, 0, 0);
      else bucket.setHours(0, 0, 0, 0);
      const key = bucket.toISOString();
      const modelValues = grouped.get(key) ?? new Map<string, number>();
      const series = seriesName(row);
      modelValues.set(series, (modelValues.get(series) ?? 0) + metricValue(row, props.metric));
      grouped.set(key, modelValues);
    }
    return [...grouped]
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([timestamp, modelValues]) => ({
        timestamp,
        segments: [...modelValues].sort(([left], [right]) => left.localeCompare(right)).map(([model, value]) => ({ model, value })),
        total: [...modelValues.values()].reduce((sum, value) => sum + value, 0),
      }));
  });
  const points = createMemo(() => {
    const occupied = occupiedPoints();
    if (props.timelineStart == null || props.timelineEndExclusive == null) return occupied;
    const start = alignedBucketStart(props.timelineStart, props.granularity);
    const endExclusive = new Date(props.timelineEndExclusive);
    if (Number.isNaN(start.getTime()) || Number.isNaN(endExclusive.getTime()) || start >= endExclusive) return occupied;
    const occupiedByTimestamp = new Map(occupied.map((point) => [point.timestamp, point]));
    const continuous = [];
    for (let bucket = start; bucket < endExclusive; bucket = nextBucket(bucket, props.granularity)) {
      const key = bucket.toISOString();
      continuous.push(occupiedByTimestamp.get(key) ?? { timestamp: key, segments: [], total: 0 });
    }
    return continuous;
  });
  const firstTimestamp = createMemo(() => points()[0] == null ? 0 : new Date(points()[0].timestamp).getTime());
  const lastTimestamp = createMemo(() => points().at(-1) == null ? 0 : new Date(points().at(-1)!.timestamp).getTime());
  const bucketCount = createMemo(() => points().length);
  const pointIndexByTimestamp = createMemo(() => new Map(points().map((point, index) => [point.timestamp, index])));
  const visiblePoints = createMemo(() => points().filter((point) => new Date(point.timestamp).getTime() >= loadedAfter()));
  const axisMaximum = createMemo(() => niceChartMaximum(Math.max(...visiblePoints().map((point) => point.total), 0)));
  const yTicks = createMemo(() => Array.from({ length: yTickCount + 1 }, (_, index) => (axisMaximum() / yTickCount) * index));
  const chartWidth = createMemo(() => Math.max(1_100, chartMargin.left + chartMargin.right + bucketCount() * chartSlotWidths[props.granularity]));
  const plotHeight = chartHeight - chartMargin.top - chartMargin.bottom;
  const plotWidth = () => chartWidth() - chartMargin.left - chartMargin.right;
  const barSlotWidth = () => plotWidth() / Math.max(bucketCount(), 1);
  const barWidth = () => Math.min(28, barSlotWidth() * 0.65);
  const overlayDomainEnd = createMemo(() => {
    const explicit = props.timelineEndExclusive == null ? Number.NaN : new Date(props.timelineEndExclusive).getTime();
    if (Number.isFinite(explicit)) return explicit;
    const evaluated = props.evaluatedAt == null ? Number.NaN : new Date(props.evaluatedAt).getTime();
    if (Number.isFinite(evaluated)) return evaluated;
    const candidates = [
      lastTimestamp() > 0 ? lastTimestamp() + bucketMilliseconds(props.granularity) : Number.NaN,
      ...props.markers.map((marker) => marker.latestEventAt == null ? Number.NaN : new Date(marker.latestEventAt).getTime()),
      ...props.gaps.map((gap) => new Date(gap.endAt).getTime()),
    ].filter(Number.isFinite);
    return candidates.length > 0 ? Math.max(...candidates) : Date.now();
  });
  const overlayDomainStart = createMemo(() => {
    const explicit = props.timelineStart == null ? Number.NaN : new Date(props.timelineStart).getTime();
    if (Number.isFinite(explicit)) return explicit;
    if (firstTimestamp() > 0) return firstTimestamp();
    return overlayDomainEnd() - 60 * 60 * 1_000;
  });
  const overlayX = (timestamp: string) => {
    const start = overlayDomainStart();
    const duration = Math.max(overlayDomainEnd() - start, 1);
    const offset = Math.max(0, Math.min(1, (new Date(timestamp).getTime() - start) / duration));
    return chartMargin.left + offset * plotWidth();
  };
  const visibleGaps = createMemo(() => props.granularity === "daily" ? [] : props.gaps.flatMap((gap) => {
    const clipped = clippedInterval(gap.startAt, gap.endAt, overlayDomainStart(), overlayDomainEnd());
    return clipped == null ? [] : [{ ...gap, clippedStart: clipped.startAt, clippedEnd: clipped.endAt }];
  }));
  const visibleMarkers = createMemo(() => props.granularity === "daily" ? [] : props.markers.filter((marker) => {
    if (marker.latestEventAt == null) return false;
    const time = new Date(marker.latestEventAt).getTime();
    return time >= overlayDomainStart() && time <= overlayDomainEnd();
  }));
  const hasChartContent = createMemo(() => points().length > 0 || visibleGaps().length > 0 || visibleMarkers().length > 0);
  const bucketIndex = (timestamp: string) => pointIndexByTimestamp().get(timestamp)
    ?? Math.round((new Date(timestamp).getTime() - firstTimestamp()) / bucketMilliseconds(props.granularity));
  const loadEarlier = () => {
    if (props.granularity === "daily" || loadedAfter() <= firstTimestamp() || isLoadingEarlier()) return;
    const boundaryIndex = Math.max(0, (loadedAfter() - firstTimestamp()) / bucketMilliseconds(props.granularity));
    const boundaryX = chartMargin.left + boundaryIndex * barSlotWidth();
    if ((chartElement?.scrollLeft ?? 0) > boundaryX + 160) return;
    setIsLoadingEarlier(true);
    props.onLazyLoadingChange(true);
    lazyLoadFrame = window.requestAnimationFrame(() => {
      renderFrame = window.requestAnimationFrame(() => {
        setLoadedAfter((current) => Math.max(firstTimestamp(), current - lazyRenderWindowMilliseconds));
        completionFrame = window.requestAnimationFrame(() => {
          setIsLoadingEarlier(false);
          props.onLazyLoadingChange(false);
          lazyLoadFrame = undefined;
          renderFrame = undefined;
          completionFrame = undefined;
        });
      });
    });
  };
  const scrollToLatest = () => {
    if (chartElement) chartElement.scrollLeft = chartElement.scrollWidth - chartElement.clientWidth;
  };
  const formatValue = (value: number) => props.metric === "costUSD" ? currency.format(value) : integer.format(value);
  const yAxisTitle = () => props.metric === "costUSD" ? "Spent amount (USD)" : "Tokens";
  const yTickLabel = (tick: number) => props.metric === "costUSD"
    ? axisCurrency(tick, axisMaximum() / yTickCount)
    : integer.format(tick);
  const metricLabel = () => chartMetrics.find(([key]) => key === props.metric)?.[1] ?? "Value";
  const hoveredPoint = createMemo(() => {
    const hovered = hoveredSegment();
    if (hovered == null) return null;
    const point = visiblePoints()[hovered.bucketIndex];
    if (!point) return null;
    const segmentIndex = point.segments.findIndex(({ model }) => model === hovered.model);
    const segment = point.segments[segmentIndex];
    if (!segment) return null;
    const stackedValue = point.segments.slice(0, segmentIndex + 1).reduce((sum, item) => sum + item.value, 0);
    const centerX = chartMargin.left + barSlotWidth() * bucketIndex(point.timestamp) + barSlotWidth() / 2;
    const height = (stackedValue / axisMaximum()) * plotHeight;
    return {
      label: new Date(point.timestamp).toLocaleString(),
      model: segment.model,
      value: segment.value,
      x: Math.max(chartMargin.left, Math.min(centerX - 150, chartWidth() - chartMargin.right - 300)),
      y: Math.max(8, chartMargin.top + plotHeight - height - 62),
    };
  });
  createEffect(() => {
    const latest = lastTimestamp();
    const earliest = firstTimestamp();
    const granularity = props.granularity;
    cancelScheduledLazyLoad();
    setIsLoadingEarlier(false);
    props.onLazyLoadingChange(false);
    setLoadedAfter(granularity === "daily" ? earliest : Math.max(earliest, latest - lazyRenderWindowMilliseconds));
    queueMicrotask(scrollToLatest);
  });
  onMount(() => queueMicrotask(scrollToLatest));
  onCleanup(() => {
    cancelScheduledLazyLoad();
    props.onLazyLoadingChange(false);
  });
  return (
    <div class="chart-wrap" role="img" aria-label={`${props.label} ${props.metric} by ${props.granularity} and model`}>
      <Show when={hasChartContent()} fallback={<div class="chart"><p class="empty">No usage matches this period and model filter.</p></div>}>
        <div class="chart-legend" aria-hidden="true">
          <For each={models()}>{(model) => <span title={model}><i style={{ background: colorForSeries(model) }} />{model}</span>}</For>
        </div>
        <Show when={props.granularity !== "daily"}>
          <p class="chart-scroll-hint">Newest data is shown first. Scroll left to render earlier 12-hour windows.</p>
        </Show>
        <div class="chart-frame">
          <div class="chart" ref={chartElement} onScroll={loadEarlier}>
            <svg class="cost-chart" width={chartWidth()} height={chartHeight} viewBox={`0 0 ${chartWidth()} ${chartHeight}`} aria-hidden="true">
            <For each={yTicks()}>{(tick) => {
              const y = () => chartMargin.top + plotHeight - (tick / axisMaximum()) * plotHeight;
              return <line class="chart-grid-line" x1={chartMargin.left} x2={chartWidth() - chartMargin.right} y1={y()} y2={y()} />;
            }}</For>
          <For each={visiblePoints()}>{(point, index) => {
            const x = () => chartMargin.left + barSlotWidth() * bucketIndex(point.timestamp) + (barSlotWidth() - barWidth()) / 2;
            const label = () => chartDateLabel(point.timestamp, props.granularity);
            const showsLabel = () => props.granularity !== "15min" || bucketIndex(point.timestamp) % 4 === 0;
            return <>
              <For each={point.segments}>{(segment, segmentIndex) => {
                const precedingValue = () => point.segments.slice(0, segmentIndex()).reduce((sum, item) => sum + item.value, 0);
                const height = () => (segment.value / axisMaximum()) * plotHeight;
                const y = () => chartMargin.top + plotHeight - ((precedingValue() + segment.value) / axisMaximum()) * plotHeight;
                return <rect class="cost-bar" fill={colorForSeries(segment.model)} x={x()} y={y()} width={barWidth()} height={height()} rx="2"
                  onMouseEnter={() => setHoveredSegment({ bucketIndex: index(), model: segment.model })} onMouseLeave={() => setHoveredSegment(null)}>
                  <title>{`${new Date(point.timestamp).toLocaleString()} · ${segment.model}: ${formatValue(segment.value)}`}</title>
                </rect>;
              }}</For>
              <Show when={showsLabel()}>
                <text class="x-axis-label" x={x() + barWidth() / 2} y={chartMargin.top + plotHeight + 16} text-anchor="middle">
                  <tspan x={x() + barWidth() / 2}>{label().date}</tspan>
                  <Show when={label().time}>{(time) => <tspan x={x() + barWidth() / 2} dy="12">{time()}</tspan>}</Show>
                </text>
              </Show>
            </>;
          }}</For>
          <g class="chart-observability-overlay" pointer-events="none">
            <For each={visibleGaps()}>{(gap) => (
              <rect
                class="chart-gap-overlay"
                x={overlayX(gap.clippedStart)}
                y={chartMargin.top}
                width={Math.max(1, overlayX(gap.clippedEnd) - overlayX(gap.clippedStart))}
                height={plotHeight}
              />
            )}</For>
            <For each={visibleMarkers()}>{(marker) => (
              <g class={`chart-latest-marker ${marker.markerState}`}>
                <line
                  x1={overlayX(marker.latestEventAt!)}
                  x2={overlayX(marker.latestEventAt!)}
                  y1={chartMargin.top}
                  y2={chartMargin.top + plotHeight}
                />
                <circle cx={overlayX(marker.latestEventAt!)} cy={chartMargin.top + 8} r="5" />
              </g>
            )}</For>
          </g>
          <Show when={hoveredPoint()} keyed>{(point) => (
            <g class="chart-tooltip" transform={`translate(${point.x} ${point.y})`} pointer-events="none">
              <rect width="300" height="54" rx="7" />
              <text class="chart-tooltip-label" x="12" y="20">{point.label}</text>
              <text class="chart-tooltip-value" x="12" y="41">{point.model} · {metricLabel()}: {formatValue(point.value)}</text>
            </g>
          )}</Show>
            </svg>
          </div>
          <svg class="chart-y-axis chart-y-axis-left" width={chartMargin.left} height={chartHeight} viewBox={`0 0 ${chartMargin.left} ${chartHeight}`} aria-hidden="true">
            <rect class="axis-backdrop" width={chartMargin.left} height={chartHeight} />
            <text class="axis-title" x="16" y={chartMargin.top + plotHeight / 2} text-anchor="middle" transform={`rotate(-90 16 ${chartMargin.top + plotHeight / 2})`}>{yAxisTitle()}</text>
            <For each={yTicks()}>{(tick) => {
              const y = () => chartMargin.top + plotHeight - (tick / axisMaximum()) * plotHeight;
              return <text class="y-axis-label" x={chartMargin.left - 10} y={y()} text-anchor="end" dominant-baseline="middle">{yTickLabel(tick)}</text>;
            }}</For>
          </svg>
          <svg class="chart-y-axis chart-y-axis-right" width={chartMargin.right} height={chartHeight} viewBox={`0 0 ${chartMargin.right} ${chartHeight}`} aria-hidden="true">
            <rect class="axis-backdrop" width={chartMargin.right} height={chartHeight} />
            <text class="axis-title" x={chartMargin.right - 16} y={chartMargin.top + plotHeight / 2} text-anchor="middle" transform={`rotate(90 ${chartMargin.right - 16} ${chartMargin.top + plotHeight / 2})`}>{yAxisTitle()}</text>
            <For each={yTicks()}>{(tick) => {
              const y = () => chartMargin.top + plotHeight - (tick / axisMaximum()) * plotHeight;
              return <text class="y-axis-label" x="10" y={y()} text-anchor="start" dominant-baseline="middle">{yTickLabel(tick)}</text>;
            }}</For>
          </svg>
        </div>
      </Show>
    </div>
  );
}

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
  const [stackBy, setStackBy] = createSignal<"model" | "machine">("model");
  const [isGraphLazyLoading, setIsGraphLazyLoading] = createSignal(false);
  const [isRefreshing, setIsRefreshing] = createSignal(false);
  const [isRangeLoading, setIsRangeLoading] = createSignal(false);
  const [rangeLoadStarted, setRangeLoadStarted] = createSignal(false);
  const [isClearingCache, setIsClearingCache] = createSignal(false);
  const [cacheStatus, setCacheStatus] = createSignal<string>();
  const [isDashboardStateLoaded, setIsDashboardStateLoaded] = createSignal(false);
  const [selectedMachines, setSelectedMachines] = createSignal<string[]>([]);
  const [areAllMachinesVisible, setAreAllMachinesVisible] = createSignal(false);
  const [isMachineGraphRendering, setIsMachineGraphRendering] = createSignal(false);
  const [machineFormOpen, setMachineFormOpen] = createSignal(false);
  const [machineDraft, setMachineDraft] = createSignal<MachineDraft>(emptyMachineDraft());
  const [editingMachineID, setEditingMachineID] = createSignal<string>();
  const [machineError, setMachineError] = createSignal<string>();
  const [machineActions, setMachineActions] = createSignal<Record<string, { message: string; failed: boolean }>>({});
  const [machineActionInFlight, setMachineActionInFlight] = createSignal<Record<string, boolean>>({});
  const storedColorScheme = window.localStorage.getItem("ccusage-gauge-color-scheme");
  const initialColorScheme: ColorScheme = storedColorScheme === "light" || storedColorScheme === "dark"
    ? storedColorScheme
    : window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  const [colorScheme, setColorScheme] = createSignal<ColorScheme>(initialColorScheme);
  const [machines, { refetch: refreshMachines }] = createResource(() => getJSON<MachinesResponse>("/api/machines"));
  const [chartColors] = createResource(() => getJSON<ChartColorsResponse>("/api/chart-colors"));
  const requestedMachineScope = createMemo(() => requestedMachineIDs(machines()?.machines ?? [], selectedMachines()));
  const machineSuffix = createMemo(() => isDashboardStateLoaded() && machines() != null
    ? machineQuery(requestedMachineScope())
    : undefined);
  const withMachine = (path: string) => {
    const suffix = machineSuffix();
    return suffix == null || suffix.length === 0 ? path : `${path}${path.includes("?") ? "&" : "?"}${suffix}`;
  };
  const machineStatusPath = createMemo(() => machineSuffix() == null ? undefined : withMachine("/api/machine-status"));
  const [machineStatuses, { refetch: refreshMachineStatuses }] = createResource(
    machineStatusPath,
    (path) => getJSON<MachineStatusResponse>(path)
  );

  const periodPath = createMemo(() => machineSuffix() == null ? undefined : range() === "custom"
    ? withMachine(`/api/metrics?range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}`)
    : withMachine(`/api/metrics?range=${range()}`));
  const [period, { refetch: refreshPeriod }] = createResource(periodPath, (path) => getJSON<MetricsResponse>(path));
  const costPath = createMemo(() => machineSuffix() == null ? undefined : range() === "custom"
    ? withMachine(`/api/cost-series?granularity=${granularity()}&range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}`)
    : withMachine(`/api/cost-series?granularity=${granularity()}&range=${range()}`));
  const [costSeries, { refetch: refreshCostSeries }] = createResource(costPath, getCostSeriesState);
  const budgetPath = createMemo(() => machineSuffix() == null ? undefined : withMachine("/api/budget"));
  const [budget, { refetch: refreshBudget }] = createResource(budgetPath, (path) => getJSON<BudgetResponse>(path));
  const loadStatusPath = createMemo(() => {
    if (machineSuffix() == null) return undefined;
    return range() === "custom"
      ? withMachine(`/api/load-status?range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}`)
      : withMachine(`/api/load-status?range=${range()}`);
  });
  const [loadStatus, { refetch: refreshLoadStatus }] = createResource(
    loadStatusPath,
    (path) => getJSON<LoadStatusResponse>(path)
  );

  const selectableMachines = createMemo(() => (machines()?.machines ?? []).filter((machine) => machine.enabled));
  const visibleMachines = createMemo(() => visibleMachineItems(selectableMachines(), areAllMachinesVisible()));
  const allMachinesSelected = createMemo(() =>
    selectableMachines().length > 0 && requestedMachineScope().length === selectableMachines().length);
  const machineScopeLabel = createMemo(() => allMachinesSelected()
    ? "All available machines"
    : requestedMachineScope().map((id) => selectableMachines().find((machine) => machine.id === id)?.displayName ?? id).join(", "));
  const machineFilteredRows = createMemo(() => (period()?.rows ?? [])
    .filter((row) => requestedMachineScope().includes(row.machine)));
  const machineFilteredCostRows = createMemo(() => (costSeries()?.rows ?? [])
    .filter((row) => requestedMachineScope().includes(row.machine)));
  const models = createMemo(() => [...new Set(machineFilteredRows().map((row) => row.model))].sort());
  const agents = createMemo(() => [...new Set(machineFilteredRows().map((row) => row.agent))].sort());
  const chartModels = createMemo(() => new Set(machineFilteredCostRows().map((row) => row.model)));
  // Color is derived only from entity type and identity, so changing the metric,
  // range, filters, or the other visible series cannot reassign it.
  const activeChartColors = () => chartColors()?.[colorScheme()];
  const colorForMachine = (machine: string) => seriesColor(colorScheme(), "machine", machine, activeChartColors()?.machines);
  const colorForModel = (model: string) => seriesColor(colorScheme(), "model", model, activeChartColors()?.models);
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
    const scheme = colorScheme();
    document.documentElement.dataset.colorScheme = scheme;
    window.localStorage.setItem("ccusage-gauge-color-scheme", scheme);
  });
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
  const total = (key: MetricKey) => filteredRows().reduce((sum, row) => sum + metricValue(row, key), 0);
  const chartTotal = createMemo(() => filteredCostRows().reduce((sum, row) => sum + metricValue(row, chartMetric()), 0));
  const chartMetricLabel = createMemo(() => chartMetrics.find(([value]) => value === chartMetric())?.[1] ?? "Cost");
  const chartTitle = createMemo(() => `${chartMetricLabel()} over time by ${stackBy()}`);
  const formattedChartTotal = createMemo(() => chartMetric() === "costUSD" ? currency.format(chartTotal()) : integer.format(chartTotal()));
  const rangeLabel = createMemo(() => range() === "custom"
    ? `${appliedCustomRange().start} – ${appliedCustomRange().end}`
    : quickRanges.find(([value]) => value === range())?.[1] ?? "Selected period");
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
  const isBlockingLoading = createMemo(() => isInitialLoading() || isRangeLoading());
  const isBackgroundLoading = createMemo(() => !isBlockingLoading() &&
    (loadStatus()?.isLoading || isRefreshing() || period.loading || costSeries.loading || budget.loading));
  const visibleRangeLoad = createMemo(() => period()?.rangeLoad ?? costSeries()?.rangeLoad);
  const toggleModel = (model: string) => setSelectedModels((current) => current.includes(model)
    ? current.filter((item) => item !== model)
    : [...current, model]);
  let machineRenderStartFrame: number | undefined;
  let machineRenderApplyFrame: number | undefined;
  let machineRenderEndFrame: number | undefined;
  let pendingMachineSelection: string[] | undefined;
  const updateMachineSelection = (update: (current: string[]) => string[]) => {
    const current = pendingMachineSelection ?? selectedMachines();
    const next = update(current);
    if (next.length === current.length && next.every((item, index) => item === current[index])) return;
    pendingMachineSelection = next;
    if (machineRenderStartFrame != null) window.cancelAnimationFrame(machineRenderStartFrame);
    if (machineRenderApplyFrame != null) window.cancelAnimationFrame(machineRenderApplyFrame);
    if (machineRenderEndFrame != null) window.cancelAnimationFrame(machineRenderEndFrame);
    setIsMachineGraphRendering(true);
    machineRenderStartFrame = window.requestAnimationFrame(() => {
      machineRenderApplyFrame = window.requestAnimationFrame(() => {
        setSelectedMachines(pendingMachineSelection ?? []);
        pendingMachineSelection = undefined;
        machineRenderEndFrame = window.requestAnimationFrame(() => setIsMachineGraphRendering(false));
      });
    });
  };
  const toggleSelectedMachine = (machine: string) => updateMachineSelection((current) => {
    const effective = current.length === 0 ? requestedMachineScope() : current;
    const next = toggledMachineSelection(effective, machine);
    return next.length === 0 ? effective : next;
  });
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
      .then(() => Promise.all([refreshPeriod(), refreshCostSeries(), refreshBudget(), refreshMachineStatuses()]))
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
    setMachineFormOpen(false);
  };
  const beginCreateMachine = () => {
    applyMachineDraft(emptyMachineDraft());
    setEditingMachineID(undefined);
    setMachineError(undefined);
    setMachineFormOpen(true);
  };
  const beginEditMachine = (machine: Machine) => {
    applyMachineDraft(draftFromMachine(machine));
    setEditingMachineID(machine.id);
    setMachineActions((current) => Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine.id)));
    setMachineError(undefined);
    setMachineFormOpen(true);
  };
  const changeMachineProxyKind = (proxyKind: MachineProxyKind) => {
    applyMachineDraft(changingProxyKind(currentMachineDraft(), proxyKind));
  };
  const saveMachine = async () => {
    setMachineError(undefined);
    const draft = currentMachineDraft();
    const validation = machineDraftErrors(draft);
    if (Object.keys(validation).length > 0) {
      const [field, message] = Object.entries(validation)[0];
      setMachineError(`${field}: ${message}`);
      return;
    }
    try {
      const editingID = editingMachineID();
      await mutationJSON<Machine>(editingID == null ? "/api/machines" : `/api/machines/${editingID}`, {
        method: editingID == null ? "POST" : "PUT",
        body: JSON.stringify(machineRequestBody(draft, editingID == null)),
      });
      closeMachineForm();
      await Promise.all([refreshMachines(), refreshMachineStatuses()]);
    } catch (error) {
      setMachineError(error instanceof Error ? error.message : "Machine save failed.");
    }
  };
  const toggleMachine = async (machine: Machine) => {
    setMachineActions((current) => Object.fromEntries(Object.entries(current).filter(([id]) => id !== machine.id)));
    await mutationJSON<Machine>(`/api/machines/${machine.id}`, {
      method: "PATCH", body: JSON.stringify({ enabled: !machine.enabled }),
    });
    await Promise.all([refreshMachines(), refreshMachineStatuses()]);
  };
  const removeMachine = async (machine: Machine) => {
    if (!window.confirm(`Remove ${machine.displayName}? Its host cache will be retained.`)) return;
    await mutationJSON<void>(`/api/machines/${machine.id}`, { method: "DELETE" });
    setSelectedMachines((current) => current.filter((id) => id !== machine.id));
    await Promise.all([refreshMachines(), refreshMachineStatuses()]);
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
      refetch: () => Promise.all([refreshMachineStatuses(), refreshPeriod(), refreshCostSeries(), refreshBudget()]),
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
    void Promise.all([refreshPeriod(), refreshCostSeries()]);
  });
  onMount(() => {
    void getJSON<DashboardUIStateResponse>("/api/dashboard-state")
      .then(({ state }) => {
        if (!state) return;
        setRange(state.range);
        setCustomStart(state.customStart);
        setCustomEnd(state.customEnd);
        setAppliedCustomRange({ start: state.customStart, end: state.customEnd });
        setSelectedModels(state.selectedModels);
        setSelectedAgents(state.selectedAgents);
        setSelectedMachines(state.selectedMachines);
        setGranularity(state.granularity);
        setChartMetric(state.chartMetric);
        setStackBy(state.stackBy);
      })
      .catch(() => undefined)
      .finally(() => setIsDashboardStateLoaded(true));
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
    if (!isDashboardStateLoaded()) return;
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
    const timer = window.setInterval(() => {
      if (loadStatus()?.isLoading) return;
      void refresh();
    }, Math.max(intervalSeconds, 1) * 1_000);
    onCleanup(() => window.clearInterval(timer));
  });

  return (
    <div class="app-shell">
      <aside class="model-sidebar" aria-label="Usage filters">
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
            onClick={() => updateMachineSelection(() => selectableMachines().map((machine) => machine.id))}
          ><span>All machines</span></button>
          <div class="model-list">
            <For each={visibleMachines()} fallback={<p class="muted">{machines.loading ? "Loading machines…" : "No enabled machines."}</p>}>{(machine) => (
              <label classList={{ "model-choice": true, active: selectedMachineIDs().has(machine.id) }} title={`${machine.displayName} (${machine.id})`}>
                <input type="checkbox" checked={selectedMachineIDs().has(machine.id)} onChange={() => toggleSelectedMachine(machine.id)} />
                <span>{machine.displayName}</span>
                <Show when={statusByMachine().get(machine.id)?.collectionState === "error"
                  || statusByMachine().get(machine.id)?.collectionState === "stale"}>
                  <svg class="machine-warning-icon" viewBox="0 0 24 24" role="img" aria-label={`${machine.displayName} collection warning`}>
                    <path d="M12 3 2.7 20h18.6L12 3Z" />
                    <path d="M12 9v5M12 17.5v.5" />
                  </svg>
                </Show>
              </label>
            )}</For>
          </div>
          <Show when={selectableMachines().length > initialMachineLimit}>
            <button class="machine-more" onClick={() => setAreAllMachinesVisible(!areAllMachinesVisible())} aria-expanded={areAllMachinesVisible()}>
              {areAllMachinesVisible() ? "Show less" : `More (${selectableMachines().length - initialMachineLimit})`}
            </button>
          </Show>
          <small>Selected: {machineScopeLabel()}</small>
          <Show when={(period()?.scope.staleMachineIds.length ?? 0) > 0}><small class="machine-warning">Stale: {period()!.scope.staleMachineIds.join(", ")}</small></Show>
          <Show when={(period()?.scope.unavailableMachineIds.length ?? 0) > 0}><small class="machine-warning">Unavailable: {period()!.scope.unavailableMachineIds.join(", ")}</small></Show>
        </div>
        <div class="agent-filter"><p class="eyebrow">AGENTS</p><div class="agent-buttons">
          <For each={agents()}>{(agent) => <button classList={{ active: selectedAgents().includes(agent) }} onClick={() => toggleAgent(agent)}>{agent}</button>}</For>
        </div></div>
      </aside>

      <main class="content" aria-busy={isBlockingLoading() || isBackgroundLoading()}>
        <header>
          <div class="dashboard-title"><h1>ccusage-gauge</h1>
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
          </div>
          <div class="period-control" aria-label="Aggregation period">
            <div class="range-buttons">
              <For each={quickRanges}>{([value, label]) => <button classList={{ active: range() === value }} onClick={() => selectRange(value)}>{label}</button>}</For>
              <button classList={{ active: range() === "custom" || isCustomEditorOpen() }} onClick={() => setIsCustomEditorOpen(true)}>Custom</button>
            </div>
            <span classList={{ "background-refresh-status": true, visible: isBackgroundLoading() }} role="status" aria-live="polite">
              <span class="refresh-spinner" aria-hidden="true" />
              {loadStatus()?.isLoading
                ? `${loadStatus()!.message} · ${loadStatus()!.completed}/${loadStatus()!.total} · ${machineProgressDetail(loadStatus())}`
                : "Updating…"}
            </span>
            <Show when={isCustomEditorOpen()}><div class="custom-calendar" role="group" aria-label="Custom date range">
              <label>From<input aria-label="Custom range start" type="date" value={customStart()} max={customEnd()} onInput={(event) => updateCustomStart(event.currentTarget.value)} /></label>
              <span>to</span>
              <label>To<input aria-label="Custom range end" type="date" value={customEnd()} min={customStart()} onInput={(event) => updateCustomEnd(event.currentTarget.value)} /></label>
              <button
                class="apply-custom-range"
                disabled={!customStart() || !customEnd() || customStart() > customEnd()}
                onClick={applyCustomRange}
              >Apply</button>
            </div></Show>
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
              <button
                class="refresh-icon theme-icon"
                onClick={() => setColorScheme((current) => current === "light" ? "dark" : "light")}
                aria-label={`Switch to ${colorScheme() === "light" ? "dark" : "light"} mode`}
                title={`Switch to ${colorScheme() === "light" ? "dark" : "light"} mode`}
              >
                <Show
                  when={colorScheme() === "light"}
                  fallback={<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a7.5 7.5 0 1 0 9 9 9 9 0 0 1-9-9Z" /></svg>}
                >
                  <svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.65 17.65l1.42 1.42M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.65 6.35l1.42-1.42" /></svg>
                </Show>
              </button>
            </div>
            </section>

            <section class="panel usage-panel">
            <div class="panel-title"><div><p class="eyebrow">AGGREGATED USAGE</p><div class="chart-heading"><h2>{chartTitle()}</h2>
              <span class="data-quality-badge">{chartDataQuality()}</span>
              <Show when={isGraphLazyLoading() || isMachineGraphRendering()}><span class="graph-loading-status" role="status" aria-label={isMachineGraphRendering() ? "Rendering selected machine data" : "Rendering earlier graph data"}><span class="graph-loading-spinner" aria-hidden="true" /></span></Show>
            </div></div>
              <div class="granularity-control" aria-label="Graph aggregation">
                <div><button classList={{ active: granularity() === "15min" }} onClick={() => selectGranularity("15min")}>15 min</button><button classList={{ active: granularity() === "hourly" }} onClick={() => selectGranularity("hourly")}>Hourly</button><button classList={{ active: granularity() === "6hour" }} onClick={() => selectGranularity("6hour")}>6 hour</button><button classList={{ active: granularity() === "daily" }} onClick={() => selectGranularity("daily")}>Daily</button></div>
                <label class="metric-selector">Metric
                  <select value={chartMetric()} onChange={(event) => setChartMetric(event.currentTarget.value as MetricKey)}>
                    <For each={chartMetrics}>{([value, label]) => <option value={value}>{label}</option>}</For>
                  </select>
                </label>
                <div class="stack-toggle" role="group" aria-label="Stack by">
                  <span>Stack by</span>
                  <button classList={{ active: stackBy() === "model" }} onClick={() => setStackBy("model")}>Model</button>
                  <button classList={{ active: stackBy() === "machine" }} onClick={() => setStackBy("machine")}>Machine</button>
                </div>
                <strong>{formattedChartTotal()}</strong>
              </div>
            </div>
            <Bars
              rows={filteredCostRows()}
              granularity={granularity()}
              label={rangeLabel()}
              metric={chartMetric()}
              timelineStart={costSeries()?.timelineStart}
              timelineEndExclusive={costSeries()?.timelineEndExclusive}
              onLazyLoadingChange={setIsGraphLazyLoading}
              stackBy={stackBy()}
              colorScheme={colorScheme()}
              colorOverrides={stackBy() === "machine" ? activeChartColors()?.machines : activeChartColors()?.models}
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
                <BreakdownBars rows={filteredRows()} metric={chartMetric()} keyOf={(row) => row.machine} colorFor={colorForMachine} label="per host" />
              </div>
              <div class="breakdown-col">
                <h3 class="breakdown-title">By model</h3>
                <BreakdownBars rows={filteredRows()} metric={chartMetric()} keyOf={(row) => row.model} colorFor={colorForModel} label="per model" />
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
