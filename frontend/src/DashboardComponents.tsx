import { For, Show, createMemo } from "solid-js";
import type { LoadStatusResponse, MachineStatus, MetricRow } from "./api";
import { machineHealthDiagnosticContent, machineHealthSummary } from "./machineObservability";

export type MetricKey = "costUSD" | "totalTokens" | "inputTokens" | "outputTokens" | "cacheReadTokens" | "cacheCreationTokens";

const currency = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });
const integer = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const percentage = new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 });

export function LoadingState(props: { status?: LoadStatusResponse }) {
  const completed = () => props.status?.completed ?? 0;
  const total = () => Math.max(props.status?.total ?? 3, 1);
  return (
    <section class="loading-state" role="status" aria-live="polite">
      <div class="loading-spinner" aria-hidden="true" />
      <div>
        <strong>{props.status?.message ?? "Loading this week"}…</strong>
        <p>Reading ccusage metrics and preparing the dashboard. {completed()}/{total()}</p>
        <progress class="load-progress" value={completed()} max={total()} aria-label="Usage loading progress" />
        <Show when={(props.status?.machines.length ?? 0) > 0}>
          <ul class="machine-load-progress" aria-label="Per-machine loading progress">
            <For each={props.status?.machines ?? []}>{(machine) => (
              <li>
                <span>{machine.id}</span>
                <span>{machine.message}</span>
                <strong>{machine.completed}/{Math.max(machine.total, 1)}</strong>
                <progress value={machine.completed} max={Math.max(machine.total, 1)} aria-label={`${machine.id} loading progress`} />
              </li>
            )}</For>
          </ul>
        </Show>
      </div>
    </section>
  );
}

const timestampLabel = (value?: string) => value == null ? "not recorded" : new Date(value).toLocaleString();

export function MachineHealthPanel(props: {
  statuses: MachineStatus[];
  excludedMachineIDs: string[];
}) {
  return (
    <section class="machine-health-panel" aria-label="Remote machine data health">
      <For each={props.statuses}>{(status) => (
        (() => {
          const diagnostic = machineHealthDiagnosticContent(status);
          return <article classList={{ "machine-health-item": true, [status.collectionState]: true }}>
            <div>
              <strong class="machine-health-heading">
                <svg class="machine-warning-icon" viewBox="0 0 24 24" role="img" aria-label="Machine collection warning">
                  <path d="M12 3 2.7 20h18.6L12 3Z" />
                  <path d="M12 9v5M12 17.5v.5" />
                </svg>
                {status.displayName}: {machineHealthSummary(status)}
              </strong>
              <span>{diagnostic.message}</span>
              <Show when={diagnostic.detail}>{(detail) => (
                <p class="machine-health-detail">{detail()}</p>
              )}</Show>
              <Show when={diagnostic.remediation}>{(remediation) => (
                <p class="machine-health-remediation"><b>Suggested action:</b> {remediation()}</p>
              )}</Show>
              <Show when={diagnostic.excluded}>
                <p class="machine-health-exclusion">
                  No current data since {timestampLabel(diagnostic.unavailableSince)}.
                  This machine is excluded from current rows, totals, budgets, and summaries.
                </p>
              </Show>
            </div>
            <dl>
              <dt>Last success</dt><dd>{timestampLabel(status.lastSuccessAt)}</dd>
              <dt>Unavailable since</dt><dd>{timestampLabel(diagnostic.unavailableSince)}</dd>
              <dt>Last-hour gap</dt><dd>{status.lastHourDataGap == null ? "none" : `${timestampLabel(status.lastHourDataGap.startAt)} – ${timestampLabel(status.lastHourDataGap.endAt)}`}</dd>
            </dl>
          </article>;
        })()
      )}</For>
      <Show when={props.excludedMachineIDs.length > 0}>
        <p class="excluded-machines">Excluded from current rows, totals, budgets, and summaries: {props.excludedMachineIDs.join(", ")}.</p>
      </Show>
    </section>
  );
}

export function BreakdownBars(props: {
  rows: MetricRow[];
  metric: MetricKey;
  keyOf: (row: MetricRow) => string;
  colorFor: (key: string) => string;
  label: string;
}) {
  const totals = createMemo(() => {
    const map = new Map<string, number>();
    for (const row of props.rows) {
      map.set(props.keyOf(row), (map.get(props.keyOf(row)) ?? 0) + row[props.metric]);
    }
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
