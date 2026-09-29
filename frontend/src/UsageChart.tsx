import { For, Show, createEffect, createMemo, createSignal, onCleanup, onMount } from "solid-js";
import type { CostRow, MachineDataGap, MachineLatestEvent, MetricKey } from "./api";
import { alignedBucketStart, axisCurrency, bucketMilliseconds, chartDateLabel, clippedInterval, nextBucket, niceChartMaximum } from "./usageChartGeometry";
import { chartSeriesIdentity, chartSeriesLabel, compareSeriesIdentities, type StackBy } from "./usageChartSeries";

type Granularity = "15min" | "hourly" | "6hour" | "daily";
const currency = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const integer = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const metricValue = (row: Pick<CostRow, MetricKey>, metric: MetricKey) => row[metric];
const chartHeight = 360;
const chartMargin = { top: 16, right: 78, bottom: 54, left: 78 };
const yTickCount = 4;
const lazyRenderWindowMilliseconds = 12 * 60 * 60 * 1_000;
const chartSlotWidths: Record<Granularity, number> = { "15min": 32, hourly: 96, "6hour": 112, daily: 72 };
export function UsageChart(props: {
  rows: CostRow[];
  granularity: Granularity;
  label: string;
  metric: MetricKey;
  timelineStart?: string;
  timelineEndExclusive?: string;
  onLazyLoadingChange: (isLoading: boolean) => void;
  stackBy: StackBy;
  colorForSeries: (identity: string) => string;
  stackLabel: string;
  metricLabel: string;
  markers: MachineLatestEvent[];
  gaps: MachineDataGap[];
  evaluatedAt?: string;
  subdirectoryLabel: (row: CostRow) => string;
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
  const colorForSeries = props.colorForSeries;
  const seriesName = (row: CostRow) => chartSeriesIdentity(row, props.stackBy);
  const seriesLabels = createMemo(() => new Map(props.rows.map((row) => [
    seriesName(row),
    chartSeriesLabel(row, props.stackBy, props.subdirectoryLabel),
  ])));
  const displaySeries = (series: string) => seriesLabels().get(series) ?? series;
  const models = createMemo(() => [...new Set(props.rows.map(seriesName))].sort((a, b) => compareSeriesIdentities(props.stackBy, a, b)));
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
        segments: [...modelValues].sort(([left], [right]) => compareSeriesIdentities(props.stackBy, left, right)).map(([model, value]) => ({ model, value })),
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
  const metricLabel = () => props.metricLabel;
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
    <div class="chart-wrap" role="img" aria-label={`${props.label} ${props.metric} by ${props.granularity} and ${props.stackLabel}`}>
      <Show when={hasChartContent()} fallback={<div class="chart"><p class="empty">No usage matches this period and model filter.</p></div>}>
        <div class="chart-legend" aria-hidden="true">
          <For each={models()}>{(model) => <span title={displaySeries(model)}><i style={{ background: colorForSeries(model) }} />{displaySeries(model)}</span>}</For>
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
                return <rect class="cost-bar" fill={colorForSeries(segment.model)} x={x()} y={y()} width={barWidth()} height={height()} rx="0"
                  onMouseEnter={() => setHoveredSegment({ bucketIndex: index(), model: segment.model })} onMouseLeave={() => setHoveredSegment(null)}>
                  <title>{`${new Date(point.timestamp).toLocaleString()} · ${displaySeries(segment.model)}: ${formatValue(segment.value)}`}</title>
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
              <rect width="300" height="54" rx="0" />
              <text class="chart-tooltip-label" x="12" y="20">{point.label}</text>
              <text class="chart-tooltip-value" x="12" y="41">{displaySeries(point.model)} · {metricLabel()}: {formatValue(point.value)}</text>
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

