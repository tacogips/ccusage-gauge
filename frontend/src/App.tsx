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
  const max = () => Math.max(...points().map(([, value]) => value), 0.01);
  return (
    <div class="chart" role="img" aria-label={`${props.label} cost by ${props.granularity}`}>
      <Show when={points().length > 0} fallback={<p class="empty">No usage matches this period and model filter.</p>}>
        <For each={points()}>{([timestamp, value]) => (
          <div class="bar-column" title={`${new Date(timestamp).toLocaleString()}: ${currency.format(value)}`}>
            <div class="bar" style={{ height: `${Math.max(3, (value / max()) * 100)}%` }} />
            <span>{props.granularity === "hourly"
              ? new Date(timestamp).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
              : new Date(timestamp).toLocaleDateString([], { month: "short", day: "numeric" })}</span>
          </div>
        )}</For>
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
              Menu budget: {currency.format(budget()?.spentUSD ?? 0)} since reset · {budget()?.usagePercentage == null ? "No budget set" : `${percentage.format(budget()!.usagePercentage!)}% used`} · {budget()?.remainingUSD == null ? "No remaining amount" : `${currency.format(budget()!.remainingUSD!)} remaining`}
            </section>
          </Show>
        </Show>
      </main>
    </div>
  );
}
