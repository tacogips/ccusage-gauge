import { For, Show, createEffect, createMemo, createResource, createSignal, onCleanup, onMount } from "solid-js";
import { type BudgetResponse, type CostRow, type CostSeriesResponse, type DashboardUIState, type DashboardUIStateResponse, type LoadStatusResponse, type Machine, type MachinesResponse, type MachineStatusResponse, type MetricRow, type MetricsResponse, getJSON, mutationJSON, requestJSON } from "./api";
import { initialMachineLimit, matchesMachineSelection, toggledMachineSelection, visibleMachineItems } from "./machineScope";

type QuickRange = "recent12h" | "today" | "yesterday" | "week" | "month";
type Range = QuickRange | "custom";
type MetricKey = "costUSD" | "totalTokens" | "inputTokens" | "outputTokens" | "cacheReadTokens" | "cacheCreationTokens";
type Granularity = "15min" | "hourly" | "6hour" | "daily";

const quickRanges: Array<[QuickRange, string]> = [
  ["recent12h", "Last 12 hours"], ["today", "Today"], ["yesterday", "Yesterday"], ["week", "This week"], ["month", "This month"]
];
const currency = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const integer = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const percentage = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });
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
const modelColors = ["#238855", "#3f75b5", "#b86f32", "#7b5eb5", "#b84f6f", "#468a86", "#8a7a35", "#596d7a"];
function bucketMilliseconds(granularity: Granularity) {
  switch (granularity) {
  case "15min": return 15 * 60 * 1_000;
  case "hourly": return 60 * 60 * 1_000;
  case "6hour": return 6 * 60 * 60 * 1_000;
  case "daily": return 24 * 60 * 60 * 1_000;
  }
}

function alignedBucketStart(timestamp: string, granularity: Granularity) {
  const date = new Date(timestamp);
  if (granularity === "15min") date.setMinutes(Math.floor(date.getMinutes() / 15) * 15, 0, 0);
  else if (granularity === "hourly") date.setMinutes(0, 0, 0);
  else if (granularity === "6hour") date.setHours(Math.floor(date.getHours() / 6) * 6, 0, 0, 0);
  else date.setHours(0, 0, 0, 0);
  return date;
}

function nextBucket(date: Date, granularity: Granularity) {
  const next = new Date(date);
  if (granularity === "daily") next.setDate(next.getDate() + 1);
  else next.setTime(next.getTime() + bucketMilliseconds(granularity));
  return next;
}

function chartDateLabel(timestamp: string, granularity: Granularity) {
  const date = new Date(timestamp);
  return {
    date: date.toLocaleDateString([], { month: "short", day: "numeric" }),
    time: granularity === "daily" ? undefined : date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
  };
}

function niceChartMaximum(value: number) {
  if (value <= 0) return 1;
  const magnitude = 10 ** Math.floor(Math.log10(value));
  const normalized = value / magnitude;
  const rounded = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
  return rounded * magnitude;
}

function axisCurrency(value: number, step: number) {
  const fractionDigits = step >= 1 ? 2 : Math.min(6, Math.max(2, Math.ceil(-Math.log10(step)) + 1));
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: fractionDigits,
  }).format(value);
}

function Bars(props: {
  rows: CostRow[];
  granularity: Granularity;
  label: string;
  metric: MetricKey;
  seriesDomain: string[];
  timelineStart?: string;
  timelineEndExclusive?: string;
  onLazyLoadingChange: (isLoading: boolean) => void;
  stackBy: "model" | "machine";
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
  const colorForModel = (model: string) => modelColors[Math.max(props.seriesDomain.indexOf(model), 0) % modelColors.length];
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
      <Show when={points().length > 0} fallback={<div class="chart"><p class="empty">No usage matches this period and model filter.</p></div>}>
        <div class="chart-legend" aria-hidden="true">
          <For each={models()}>{(model) => <span title={model}><i style={{ background: colorForModel(model) }} />{model}</span>}</For>
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
                return <rect class="cost-bar" fill={colorForModel(segment.model)} x={x()} y={y()} width={barWidth()} height={height()} rx="2"
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

function LoadingState(props: { status?: LoadStatusResponse }) {
  const completed = () => props.status?.completed ?? 0;
  const total = () => Math.max(props.status?.total ?? 3, 1);
  return (
    <section class="loading-state" role="status" aria-live="polite">
      <div class="loading-spinner" aria-hidden="true" />
      <div>
        <strong>{props.status?.message ?? "Loading this week"}…</strong>
        <p>Reading ccusage metrics and preparing the dashboard. {completed()}/{total()}</p>
        <progress class="load-progress" value={completed()} max={total()} aria-label="Usage loading progress" />
      </div>
    </section>
  );
}

function BreakdownBars(props: {
  rows: MetricRow[];
  metric: MetricKey;
  keyOf: (row: MetricRow) => string;
  colorFor: (key: string) => string;
  label: string;
}) {
  const totals = createMemo(() => {
    const map = new Map<string, number>();
    for (const row of props.rows) map.set(props.keyOf(row), (map.get(props.keyOf(row)) ?? 0) + metricValue(row, props.metric));
    return [...map].map(([key, value]) => ({ key, value })).sort((left, right) => right.value - left.value);
  });
  const maximum = createMemo(() => Math.max(...totals().map((entry) => entry.value), 0) || 1);
  const grandTotal = createMemo(() => totals().reduce((sum, entry) => sum + entry.value, 0));
  const format = (value: number) => props.metric === "costUSD" ? currency.format(value) : integer.format(value);
  const share = (value: number) => grandTotal() > 0 ? percentage.format((value / grandTotal()) * 100) : "0";
  return (
    <Show when={totals().length > 0} fallback={<p class="empty compact">No usage matches this period and filter.</p>}>
      <div class="breakdown-bars" role="img" aria-label={`${props.metric} total ${props.label} for the selected period`}>
        <For each={totals()}>{(entry) => (
          <div class="breakdown-bar-row">
            <span class="breakdown-name">
              <i class="breakdown-swatch" style={{ background: props.colorFor(entry.key) }} aria-hidden="true" />
              <span class="breakdown-label" title={entry.key}>{entry.key}</span>
            </span>
            <div class="breakdown-track">
              <div class="breakdown-fill" style={{ width: `${(entry.value / maximum()) * 100}%`, background: props.colorFor(entry.key) }} title={`${entry.key}: ${format(entry.value)} · ${share(entry.value)}%`} />
            </div>
            <span class="breakdown-value">{format(entry.value)}<small> · {share(entry.value)}%</small></span>
          </div>
        )}</For>
      </div>
    </Show>
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
  const [machineID, setMachineID] = createSignal("");
  const [machineName, setMachineName] = createSignal("");
  const [machineHost, setMachineHost] = createSignal("127.0.0.1");
  const [machinePort, setMachinePort] = createSignal("22");
  const [machineUser, setMachineUser] = createSignal("");
  const [machineIdentity, setMachineIdentity] = createSignal("");
  const [machineError, setMachineError] = createSignal<string>();
  const machineSuffix = "machine=all";
  const withMachine = (path: string) => `${path}${path.includes("?") ? "&" : "?"}${machineSuffix}`;
  const [machines, { refetch: refreshMachines }] = createResource(() => getJSON<MachinesResponse>("/api/machines"));
  const [machineStatuses, { refetch: refreshMachineStatuses }] = createResource(() => getJSON<MachineStatusResponse>("/api/machine-status?machine=all"));

  const periodPath = createMemo(() => range() === "custom"
    ? `/api/metrics?range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}&${machineSuffix}`
    : `/api/metrics?range=${range()}&${machineSuffix}`);
  const [period, { refetch: refreshPeriod }] = createResource(periodPath, (path) => getJSON<MetricsResponse>(path));
  const costPath = createMemo(() => range() === "custom"
    ? `/api/cost-series?granularity=${granularity()}&range=custom&start=${appliedCustomRange().start}&end=${appliedCustomRange().end}&${machineSuffix}`
    : `/api/cost-series?granularity=${granularity()}&range=${range()}&${machineSuffix}`);
  const [costSeries, { refetch: refreshCostSeries }] = createResource(costPath, (path) => getJSON<CostSeriesResponse>(path));
  const [budget, { refetch: refreshBudget }] = createResource(() => getJSON<BudgetResponse>("/api/budget?machine=all"));
  const [loadStatus, { refetch: refreshLoadStatus }] = createResource(() => getJSON<LoadStatusResponse>("/api/load-status?machine=all"));

  const selectableMachines = createMemo(() => (machines()?.machines ?? []).filter((machine) => machine.enabled));
  const visibleMachines = createMemo(() => visibleMachineItems(selectableMachines(), areAllMachinesVisible()));
  const machineScopeLabel = createMemo(() => selectedMachines().length === 0
    ? "All available machines"
    : selectedMachines().map((id) => selectableMachines().find((machine) => machine.id === id)?.displayName ?? id).join(", "));
  const machineFilteredRows = createMemo(() => (period()?.rows ?? [])
    .filter((row) => matchesMachineSelection(selectedMachines(), row.machine)));
  const machineFilteredCostRows = createMemo(() => (costSeries()?.rows ?? [])
    .filter((row) => matchesMachineSelection(selectedMachines(), row.machine)));
  const models = createMemo(() => [...new Set(machineFilteredRows().map((row) => row.model))].sort());
  const agents = createMemo(() => [...new Set(machineFilteredRows().map((row) => row.agent))].sort());
  const chartModels = createMemo(() => new Set(machineFilteredCostRows().map((row) => row.model)));
  // Color follows the entity, not its rank: a machine/model keeps one hue across
  // the stacked chart and its breakdown, from a stable sorted domain.
  const machineDomain = createMemo(() => [...new Set(machineFilteredRows().map((row) => row.machine))].sort());
  const chartSeriesDomain = createMemo(() => stackBy() === "machine" ? machineDomain() : models());
  const colorFor = (domain: string[], key: string) => modelColors[Math.max(domain.indexOf(key), 0) % modelColors.length];
  const colorForMachine = (machine: string) => colorFor(machineDomain(), machine);
  const colorForModel = (model: string) => colorFor(models(), model);
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
  const errorMessage = createMemo(() => period.error?.message ?? costSeries.error?.message ?? budget.error?.message);
  const isInitialLoading = createMemo(() => period() == null || costSeries() == null || budget() == null);
  const isBlockingLoading = createMemo(() => isInitialLoading() || isRangeLoading());
  const isBackgroundLoading = createMemo(() => !isBlockingLoading() &&
    (loadStatus()?.isLoading || isRefreshing() || period.loading || costSeries.loading || budget.loading));
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
  const toggleSelectedMachine = (machine: string) => updateMachineSelection((current) => toggledMachineSelection(current, machine));
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
  const createMachine = async () => {
    setMachineError(undefined);
    try {
      await mutationJSON<Machine>("/api/machines", {
        method: "POST",
        body: JSON.stringify({
          id: machineID(), displayName: machineName(), kind: "ssh", enabled: true,
          ssh: {
            host: machineHost(), port: Number(machinePort()), user: machineUser(),
            ...(machineIdentity() ? { identityFile: machineIdentity() } : {}),
            extraOptions: [], remoteCcusagePath: "ccusage",
          },
        }),
      });
      setMachineID(""); setMachineName(""); setMachineUser(""); setMachineIdentity("");
      setMachineFormOpen(false);
      await Promise.all([refreshMachines(), refreshMachineStatuses()]);
    } catch (error) {
      setMachineError(error instanceof Error ? error.message : "Machine registration failed.");
    }
  };
  const toggleMachine = async (machine: Machine) => {
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
    const timer = window.setInterval(refreshLoadStatus, 250);
    onCleanup(() => {
      window.clearInterval(timer);
      if (machineRenderStartFrame != null) window.cancelAnimationFrame(machineRenderStartFrame);
      if (machineRenderApplyFrame != null) window.cancelAnimationFrame(machineRenderApplyFrame);
      if (machineRenderEndFrame != null) window.cancelAnimationFrame(machineRenderEndFrame);
    });
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
          <button classList={{ "model-choice": true, active: selectedMachines().length === 0 }} onClick={() => updateMachineSelection(() => [])}><span>All machines</span></button>
          <div class="model-list">
            <For each={visibleMachines()} fallback={<p class="muted">{machines.loading ? "Loading machines…" : "No enabled machines."}</p>}>{(machine) => (
              <label classList={{ "model-choice": true, active: selectedMachines().includes(machine.id) }} title={`${machine.displayName} (${machine.id})`}>
                <input type="checkbox" checked={selectedMachines().includes(machine.id)} onChange={() => toggleSelectedMachine(machine.id)} />
                <span>{machine.displayName}</span>
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
              <summary aria-label="Open dashboard configuration" title="Dashboard configuration">Config</summary>
              <div class="config-menu-panel">
                <strong>Dashboard configuration</strong>
                <p>Remove persisted usage aggregates and reload recent data.</p>
                <button disabled={isClearingCache()} onClick={clearCache}>{isClearingCache() ? "Clearing…" : "Clear cache"}</button>
                <Show when={cacheStatus()}>{(message) => <small role="status">{message()}</small>}</Show>
                <hr />
                <strong>Machines</strong>
                <div class="machine-admin-list">
                  <For each={(machines()?.machines ?? []).filter((machine) => machine.kind === "ssh")} fallback={<small>No SSH machines registered.</small>}>{(machine) => {
                    const status = () => machineStatuses()?.machines.find((item) => item.id === machine.id);
                    return <div class="machine-admin-row">
                      <div><b>{machine.displayName}</b><small>{machine.id} · {status()?.collectionState ?? "unknown"}</small></div>
                      <button class="secondary" onClick={() => toggleMachine(machine)}>{machine.enabled ? "Disable" : "Enable"}</button>
                      <button class="danger" onClick={() => removeMachine(machine)}>Remove</button>
                    </div>;
                  }}</For>
                </div>
                <button class="secondary" onClick={() => setMachineFormOpen(!machineFormOpen())}>{machineFormOpen() ? "Cancel" : "Add SSH machine"}</button>
                <Show when={machineFormOpen()}><div class="machine-form">
                  <input aria-label="Machine id" placeholder="machine-id" value={machineID()} onInput={(event) => setMachineID(event.currentTarget.value)} />
                  <input aria-label="Display name" placeholder="Display name" value={machineName()} onInput={(event) => setMachineName(event.currentTarget.value)} />
                  <input aria-label="SSH host" placeholder="Host" value={machineHost()} onInput={(event) => setMachineHost(event.currentTarget.value)} />
                  <input aria-label="SSH port" type="number" min="1" max="65535" value={machinePort()} onInput={(event) => setMachinePort(event.currentTarget.value)} />
                  <input aria-label="SSH user" placeholder="User" value={machineUser()} onInput={(event) => setMachineUser(event.currentTarget.value)} />
                  <input aria-label="Identity file" placeholder="/absolute/path/to/key (optional)" value={machineIdentity()} onInput={(event) => setMachineIdentity(event.currentTarget.value)} />
                  <button onClick={createMachine}>Register machine</button>
                  <Show when={machineError()}>{(message) => <small class="machine-warning" role="alert">{message()}</small>}</Show>
                </div></Show>
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
                ? `${loadStatus()!.message} · ${loadStatus()!.completed}/${loadStatus()!.total}`
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
            <section class="stats metric-stats">
            <article><span>Selected cost</span><strong>{currency.format(total("costUSD"))}</strong><small>{rangeLabel()} · {filterLabel()}</small></article>
            <article><span>Total tokens</span><strong>{integer.format(total("totalTokens"))}</strong><small>All token categories</small></article>
            <article><span>Input / output</span><strong>{integer.format(total("inputTokens"))} / {integer.format(total("outputTokens"))}</strong><small>Prompt and generated</small></article>
            <article><span>Cache read / creation</span><strong>{integer.format(total("cacheReadTokens"))} / {integer.format(total("cacheCreationTokens"))}</strong><small>Reported by ccusage</small></article>
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
              seriesDomain={chartSeriesDomain()}
              timelineStart={costSeries()?.timelineStart}
              timelineEndExclusive={costSeries()?.timelineEndExclusive}
              onLazyLoadingChange={setIsGraphLazyLoading}
              stackBy={stackBy()}
            />
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
