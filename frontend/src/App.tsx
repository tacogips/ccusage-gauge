import { For, Show, createEffect, createMemo, createResource, createSignal } from "solid-js";
import { type BudgetResponse, type CostRow, type CostSeriesResponse, type MetricRow, type MetricsResponse, getJSON } from "./api";

type QuickRange = "today" | "yesterday" | "week" | "month";
type Range = QuickRange | "custom";
type MetricKey = "costUSD" | "totalTokens" | "inputTokens" | "outputTokens" | "cacheReadTokens" | "cacheCreationTokens";
type Granularity = "hourly" | "daily";

const quickRanges: Array<[QuickRange, string]> = [
  ["today", "Today"], ["yesterday", "Yesterday"], ["week", "This week"], ["month", "This month"]
];
const currency = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const integer = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const percentage = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });
const dateText = (date: Date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
const localDate = () => dateText(new Date());
const daysAgo = (days: number) => { const date = new Date(); date.setDate(date.getDate() - days); return dateText(date); };
const metricValue = (row: MetricRow, metric: MetricKey) => row[metric];

const chartHeight = 280;
const chartMargin = { top: 16, right: 16, bottom: 54, left: 78 };
const yTickCount = 4;

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

function Bars(props: { rows: CostRow[]; granularity: Granularity; label: string }) {
  const points = createMemo(() => {
    const grouped = new Map<string, number>();
    for (const row of props.rows) {
      const bucket = new Date(row.timestamp);
      if (props.granularity === "hourly") bucket.setMinutes(0, 0, 0);
      else bucket.setHours(0, 0, 0, 0);
      const key = bucket.toISOString();
      grouped.set(key, (grouped.get(key) ?? 0) + row.costUSD);
    }
    return [...grouped].sort(([left], [right]) => left.localeCompare(right));
  });
  const axisMaximum = createMemo(() => niceChartMaximum(Math.max(...points().map(([, value]) => value), 0)));
  const yTicks = createMemo(() => Array.from({ length: yTickCount + 1 }, (_, index) => (axisMaximum() / yTickCount) * index));
  const chartWidth = createMemo(() => Math.max(640, chartMargin.left + chartMargin.right + points().length * 40));
  const plotHeight = chartHeight - chartMargin.top - chartMargin.bottom;
  const plotWidth = () => chartWidth() - chartMargin.left - chartMargin.right;
  const barSlotWidth = () => plotWidth() / Math.max(points().length, 1);
  const barWidth = () => Math.min(28, barSlotWidth() * 0.65);
  return (
    <div class="chart" role="img" aria-label={`${props.label} cost by ${props.granularity}`}>
      <Show when={points().length > 0} fallback={<p class="empty">No usage matches this period and model filter.</p>}>
        <svg class="cost-chart" width={chartWidth()} height={chartHeight} viewBox={`0 0 ${chartWidth()} ${chartHeight}`} aria-hidden="true">
          <defs>
            <linearGradient id="cost-bar-gradient" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#78dfa0" />
              <stop offset="1" stop-color="#238855" />
            </linearGradient>
          </defs>
          <text class="axis-title" x="16" y={chartMargin.top + plotHeight / 2} text-anchor="middle" transform={`rotate(-90 16 ${chartMargin.top + plotHeight / 2})`}>Spent amount (USD)</text>
          <For each={yTicks()}>{(tick) => {
            const y = () => chartMargin.top + plotHeight - (tick / axisMaximum()) * plotHeight;
            return <>
              <line class="chart-grid-line" x1={chartMargin.left} x2={chartWidth() - chartMargin.right} y1={y()} y2={y()} />
              <text class="y-axis-label" x={chartMargin.left - 10} y={y()} text-anchor="end" dominant-baseline="middle">{axisCurrency(tick, axisMaximum() / yTickCount)}</text>
            </>;
          }}</For>
          <For each={points()}>{([timestamp, value], index) => {
            const x = () => chartMargin.left + barSlotWidth() * index() + (barSlotWidth() - barWidth()) / 2;
            const height = () => (value / axisMaximum()) * plotHeight;
            const label = () => props.granularity === "hourly"
              ? new Date(timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
              : new Date(timestamp).toLocaleDateString([], { month: "short", day: "numeric" });
            return <>
              <rect class="cost-bar" x={x()} y={chartMargin.top + plotHeight - height()} width={barWidth()} height={height()} rx="4">
                <title>{`${new Date(timestamp).toLocaleString()}: ${currency.format(value)}`}</title>
              </rect>
              <text class="x-axis-label" x={x() + barWidth() / 2} y={chartMargin.top + plotHeight + 17} text-anchor="end" transform={`rotate(-35 ${x() + barWidth() / 2} ${chartMargin.top + plotHeight + 17})`}>{label()}</text>
            </>;
          }}</For>
        </svg>
      </Show>
    </div>
  );
}

function LoadingState() {
  return (
    <section class="loading-state" role="status" aria-live="polite">
      <div class="loading-spinner" aria-hidden="true" />
      <div>
        <strong>Loading usage data…</strong>
        <p>Reading ccusage metrics and preparing the dashboard.</p>
      </div>
    </section>
  );
}

export default function App() {
  const [range, setRange] = createSignal<Range>("today");
  const [customStart, setCustomStart] = createSignal(daysAgo(6));
  const [customEnd, setCustomEnd] = createSignal(localDate());
  const [selectedModels, setSelectedModels] = createSignal<string[]>([]);
  const [selectedAgents, setSelectedAgents] = createSignal<string[]>([]);
  const [granularity, setGranularity] = createSignal<Granularity>("hourly");

  const periodPath = createMemo(() => range() === "custom"
    ? `/api/metrics?range=custom&start=${customStart()}&end=${customEnd()}`
    : `/api/metrics?range=${range()}`);
  const [catalog, { refetch: refreshCatalog }] = createResource(() => getJSON<MetricsResponse>("/api/metrics?range=all"));
  const [period, { refetch: refreshPeriod }] = createResource(periodPath, (path) => getJSON<MetricsResponse>(path));
  const costPath = createMemo(() => range() === "custom"
    ? `/api/cost-series?granularity=${granularity()}&range=custom&start=${customStart()}&end=${customEnd()}`
    : `/api/cost-series?granularity=${granularity()}&range=${range()}`);
  const [costSeries, { refetch: refreshCostSeries }] = createResource(costPath, (path) => getJSON<CostSeriesResponse>(path));
  const [budget, { refetch: refreshBudget }] = createResource(() => getJSON<BudgetResponse>("/api/budget"));

  const models = createMemo(() => [...new Set((period()?.rows ?? []).map((row) => row.model))].sort());
  const agents = createMemo(() => [...new Set((catalog()?.rows ?? []).map((row) => row.agent))].sort());
  createEffect(() => {
    const available = new Set(models());
    setSelectedModels((current) => {
      const next = current.filter((model) => available.has(model));
      return next.length === current.length ? current : next;
    });
  });
  const filteredRows = createMemo(() => (period()?.rows ?? []).filter((row) =>
    (selectedModels().length === 0 || selectedModels().includes(row.model)) &&
    (selectedAgents().length === 0 || selectedAgents().includes(row.agent))));
  const filteredCostRows = createMemo(() => (costSeries()?.rows ?? []).filter((row) =>
    (selectedModels().length === 0 || selectedModels().includes(row.model)) &&
    (selectedAgents().length === 0 || selectedAgents().includes(row.agent))));
  const total = (key: MetricKey) => filteredRows().reduce((sum, row) => sum + metricValue(row, key), 0);
  const chartTotal = createMemo(() => filteredCostRows().reduce((sum, row) => sum + row.costUSD, 0));
  const rangeLabel = createMemo(() => range() === "custom" ? `${customStart()} – ${customEnd()}` : quickRanges.find(([value]) => value === range())?.[1] ?? "Selected period");
  const filterLabel = createMemo(() => selectedModels().length === 0 ? "All models" : `${selectedModels().length} selected`);
  const errorMessage = createMemo(() => catalog.error?.message ?? period.error?.message ?? costSeries.error?.message ?? budget.error?.message);
  const isLoading = createMemo(() => catalog.loading || period.loading || costSeries.loading || budget.loading);
  const toggle = (value: string, values: () => string[], setter: (next: string[]) => void) => setter(values().includes(value) ? values().filter((item) => item !== value) : [...values(), value]);
  const refresh = () => { void refreshCatalog(); void refreshPeriod(); void refreshCostSeries(); void refreshBudget(); };

  return (
    <div class="app-shell">
      <aside class="model-sidebar" aria-label="Usage filters">
        <div class="brand-mark" aria-hidden="true"><span /></div>
        <div><p class="eyebrow">FILTER USAGE</p><h2>Models</h2></div>
        <button classList={{ "model-choice": true, active: selectedModels().length === 0 }} onClick={() => setSelectedModels([])}><span>All models</span></button>
        <div class="model-list">
          <For each={models()} fallback={<p class="muted">{period.loading ? "Loading models…" : "No models in the selected period."}</p>}>{(model) => (
            <label classList={{ "model-choice": true, active: selectedModels().includes(model) }}>
              <input type="checkbox" checked={selectedModels().includes(model)} onChange={() => toggle(model, selectedModels, setSelectedModels)} />
              <span title={model}>{model}</span>
            </label>
          )}</For>
        </div>
        <div class="agent-filter"><p class="eyebrow">AGENTS</p><div class="agent-buttons">
          <For each={agents()}>{(agent) => <button classList={{ active: selectedAgents().includes(agent) }} onClick={() => toggle(agent, selectedAgents, setSelectedAgents)}>{agent}</button>}</For>
        </div></div>
        <p class="filter-note">Each row is an exact ccusage daily agent/model breakdown. Costs and tokens are summed only from matching rows.</p>
      </aside>

      <main class="content" aria-busy={isLoading()}>
        <header>
          <div><p class="eyebrow">CCUSAGE DETAILED METRICS</p><h1>ccusage-gauge</h1></div>
          <div class="period-control" aria-label="Aggregation period">
            <div class="range-buttons">
              <For each={quickRanges}>{([value, label]) => <button classList={{ active: range() === value }} onClick={() => setRange(value)}>{label}</button>}</For>
              <button classList={{ active: range() === "custom" }} onClick={() => setRange("custom")}>Custom</button>
              <button class="refresh" onClick={refresh}>Refresh</button>
            </div>
            <Show when={range() === "custom"}><div class="custom-calendar" role="group" aria-label="Custom date range">
              <label>From<input aria-label="Custom range start" type="date" value={customStart()} max={customEnd()} onInput={(event) => setCustomStart(event.currentTarget.value)} /></label>
              <span>to</span>
              <label>To<input aria-label="Custom range end" type="date" value={customEnd()} min={customStart()} onInput={(event) => setCustomEnd(event.currentTarget.value)} /></label>
            </div></Show>
          </div>
        </header>

        <Show when={!errorMessage()} fallback={<section class="error"><span>{errorMessage()}</span><button onClick={refresh}>Retry</button></section>}>
          <Show when={!isLoading()} fallback={<LoadingState />}>
            <section class="stats metric-stats">
            <article><span>Selected cost</span><strong>{currency.format(total("costUSD"))}</strong><small>{rangeLabel()} · {filterLabel()}</small></article>
            <article><span>Total tokens</span><strong>{integer.format(total("totalTokens"))}</strong><small>All token categories</small></article>
            <article><span>Input / output</span><strong>{integer.format(total("inputTokens"))} / {integer.format(total("outputTokens"))}</strong><small>Prompt and generated</small></article>
            <article><span>Cache read / creation</span><strong>{integer.format(total("cacheReadTokens"))} / {integer.format(total("cacheCreationTokens"))}</strong><small>Reported by ccusage</small></article>
            </section>

            <section class="panel usage-panel">
            <div class="panel-title"><div><p class="eyebrow">AGGREGATED COST</p><h2>Cost over time</h2></div>
              <div class="granularity-control" aria-label="Graph aggregation">
                <div><button classList={{ active: granularity() === "hourly" }} onClick={() => setGranularity("hourly")}>Hourly</button><button classList={{ active: granularity() === "daily" }} onClick={() => setGranularity("daily")}>Daily</button></div>
                <strong>{currency.format(chartTotal())}</strong>
              </div>
            </div>
            <Bars rows={filteredCostRows()} granularity={granularity()} label={rangeLabel()} />
            </section>

            <section class="panel block-panel">
            <div class="panel-title"><div><p class="eyebrow">CCUSAGE BREAKDOWNS</p><h2>Daily agent and model detail</h2></div><strong>{filteredRows().length}</strong></div>
            <div class="metric-table" role="table">
              <div class="metric-row metric-head" role="row"><span>Date</span><span>Agent</span><span>Model</span><span>Cost</span><span>Total tokens</span></div>
              <For each={filteredRows().slice().reverse()} fallback={<p class="empty compact">No matching metric rows.</p>}>{(row) => (
                <div class="metric-row" role="row"><time>{row.date}</time><span class="agent-tag">{row.agent}</span><strong title={row.model}>{row.model}</strong><span>{currency.format(row.costUSD)}</span><span>{integer.format(row.totalTokens)}</span></div>
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
