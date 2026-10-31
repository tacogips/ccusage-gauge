import type { PieChartID, ProviderRateLimits, RateLimitsResponse, RateLimitWindow } from "./api";

export const pieChartIds: PieChartID[] = ["budget", "claude5h", "claudeWeekly", "codex5h", "codexWeekly"];
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
export function rateLimitWindowFor(id: PieChartID, response?: RateLimitsResponse): { provider?: ProviderRateLimits; window?: RateLimitWindow | null } {
  if (id === "budget") return {};
  const provider = response?.providers.find((item) => item.provider === (id.startsWith("claude") ? "claude" : "codex"));
  return { provider, window: id.endsWith("5h") ? provider?.fiveHour : provider?.weekly };
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
