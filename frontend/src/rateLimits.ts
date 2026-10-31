import type { PieChartID, ProviderRateLimits, RateLimitCredits, RateLimitsResponse, RateLimitWindow } from "./api";

export const pieChartIds: PieChartID[] = ["budget", "claude5h", "claudeWeekly", "claudeCredit", "codex5h", "codexWeekly", "codexCredit"];
export function normalizePieCharts(value: unknown): PieChartID[] {
  const values = Array.isArray(value) ? value : [];
  const selected = pieChartIds.filter((id) => values.includes(id));
  return selected.length ? selected : ["budget"];
}
export function togglePieChart(id: PieChartID, selection: PieChartID[]): PieChartID[] {
  const current = normalizePieCharts(selection);
  if (current.includes(id) && current.length === 1) return current;
  return normalizePieCharts(current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
}
export function normalizeHiddenPieRatios(value: unknown): PieChartID[] {
  const values = Array.isArray(value) ? value : [];
  return pieChartIds.filter((id) => values.includes(id));
}
export function toggleHiddenPieRatio(id: PieChartID, hidden: PieChartID[]): PieChartID[] {
  return normalizeHiddenPieRatios(hidden.includes(id) ? hidden.filter((item) => item !== id) : [...hidden, id]);
}
export function isCreditChart(id: PieChartID): boolean { return id === "claudeCredit" || id === "codexCredit"; }
export function rateLimitWindowFor(id: PieChartID, response?: RateLimitsResponse): { provider?: ProviderRateLimits; window?: RateLimitWindow | null } {
  if (id === "budget") return {};
  const provider = response?.providers.find((item) => item.provider === (id.startsWith("claude") ? "claude" : "codex"));
  if (isCreditChart(id)) return { provider };
  return { provider, window: id.endsWith("5h") ? provider?.fiveHour : provider?.weekly };
}
export function rateLimitCreditsFor(id: PieChartID, response?: RateLimitsResponse): { provider?: ProviderRateLimits; credits?: RateLimitCredits | null } {
  if (!isCreditChart(id)) return {};
  const { provider } = rateLimitWindowFor(id, response);
  return { provider, credits: provider?.credits };
}
export function creditFraction(credits: RateLimitCredits | null | undefined): number | undefined {
  const percent = credits?.usedPercent;
  return percent == null || !Number.isFinite(percent) ? undefined : Math.min(Math.max(percent, 0), 100) / 100;
}
function formatUSD(value: number): string {
  return value.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: Number.isInteger(value) ? 0 : 2, maximumFractionDigits: 2 });
}
export function formatCredits(credits: RateLimitCredits): string {
  if (credits.unlimited) return "unlimited";
  if (!credits.enabled) return credits.unit === "usd" ? "not enabled" : "no credits";
  const percent = credits.usedPercent == null ? undefined : `${Math.round(credits.usedPercent)}%`;
  if (credits.unit === "credits") return credits.balance == null ? "available" : `${credits.balance.toLocaleString("en-US", { maximumFractionDigits: 2 })} credits left`;
  if (credits.used != null && credits.limit != null) return `${formatUSD(credits.used)} / ${formatUSD(credits.limit)} used${percent ? ` (${percent})` : ""}`;
  if (credits.used != null) return `${formatUSD(credits.used)} used`;
  return percent ? `${percent} used` : "enabled";
}
export function formatResetIn(resetsAt: string | null | undefined, now: Date): string {
  if (resetsAt == null || !Number.isFinite(Date.parse(resetsAt))) return "reset time unknown";
  const minutes = Math.floor((Date.parse(resetsAt) - now.getTime()) / 60000);
  if (Date.parse(resetsAt) <= now.getTime()) return "reset due";
  if (minutes < 1) return "resets in <1m";
  if (minutes >= 1440) return `resets in ${Math.floor(minutes / 1440)}d ${Math.floor(minutes % 1440 / 60)}h`;
  if (minutes >= 60) return `resets in ${Math.floor(minutes / 60)}h ${minutes % 60}m`;
  return `resets in ${minutes}m`;
}
export function rateLimitStatusLabel(provider: ProviderRateLimits | undefined, _now: Date): string {
  if (!provider) return "Unavailable";
  if (provider.status === "unauthorized") return "Sign in again with the CLI";
  if (provider.status === "stale") {
    const date = provider.fetchedAt == null ? undefined : new Date(provider.fetchedAt);
    return date && Number.isFinite(date.getTime()) ? `as of ${date.toLocaleString()}` : "Stale";
  }
  if (provider.status === "unavailable") return provider.message ?? "Unavailable";
  return "";
}
export function pieFraction(window: RateLimitWindow): number { return Math.min(Math.max(window.usedPercent, 0), 100) / 100; }

export function formatResetCompact(resetsAt: string | null | undefined, now: Date): string {
  if (resetsAt == null || !Number.isFinite(Date.parse(resetsAt))) return "reset unknown";
  const seconds = (Date.parse(resetsAt) - now.getTime()) / 1000;
  if (seconds <= 0) return "reset due";
  if (seconds >= 86400) return `reset in ${Math.floor(seconds / 86400)}d`;
  if (seconds >= 3600) return `reset in ${Math.floor(seconds / 3600)}h`;
  return `reset in ${Math.max(1, Math.ceil(seconds / 60))}m`;
}
