import { For, type Accessor } from "solid-js";
import type { BudgetResponse, PieChartID, RateLimitsResponse } from "./api";
import { normalizePieCharts, pieChartIds, pieFraction, rateLimitStatusLabel, rateLimitWindowFor } from "./rateLimits";
const labels: Record<PieChartID, string> = { budget: "Budget", claude5h: "Claude Code 5h", claudeWeekly: "Claude Code weekly", codex5h: "Codex 5h", codexWeekly: "Codex weekly" };
export function PieChartPanel(props: { selection: Accessor<PieChartID[]>; onToggle: (id: PieChartID) => void; budget: Accessor<BudgetResponse | undefined>; response: Accessor<RateLimitsResponse | undefined> }) {
  const selection = () => normalizePieCharts(props.selection());
  return <section class="panel pie-chart-panel"><div class="panel-title"><div><p class="eyebrow">DISPLAY</p><h2>Pie charts</h2></div></div>
    <div class="pie-toggles" aria-label="Choose pie charts"><For each={pieChartIds}>{(id) => <button type="button" aria-pressed={selection().includes(id)} disabled={selection().length === 1 && selection().includes(id)} onClick={() => props.onToggle(id)}>{labels[id]}</button>}</For></div>
    <div class="pie-list"><For each={selection()}>{(id) => {
      const data = () => rateLimitWindowFor(id, props.response());
      const fraction = () => id === "budget" ? props.budget()?.visualFraction : data().window == null ? undefined : pieFraction(data().window!);
      const value = () => Math.min(Math.max(fraction() ?? 0, 0), 1);
      const detail = () => id === "budget" ? (fraction() == null ? "No budget set" : `${Math.round(value() * 100)}% used`) : data().window == null ? (rateLimitStatusLabel(data().provider, new Date()) || "Unavailable") : `${Math.round(value() * 100)}% used`;
      return <div class="pie-item"><svg viewBox="0 0 36 36" role="img" aria-label={`${labels[id]}: ${detail()}`}><circle class="pie-track" cx="18" cy="18" r="15.9"/><circle class="pie-fill" cx="18" cy="18" r="8" stroke-dasharray={`${value() * 50.265} 50.265`} transform="rotate(-90 18 18)"/></svg><strong>{labels[id]}</strong><span>{detail()}</span></div>;
    }}</For></div>
  </section>;
}
