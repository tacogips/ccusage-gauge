export interface MetricRow {
  date: string;
  agent: string;
  model: string;
  costUSD: number;
  inputTokens: number;
  outputTokens: number;
  cacheCreationTokens: number;
  cacheReadTokens: number;
  totalTokens: number;
}
export interface MetricTotals extends Omit<MetricRow, "date" | "agent" | "model"> {}
export interface MetricsResponse { range: string; rows: MetricRow[]; totals: MetricTotals }
export interface CostRow { timestamp: string; agent: string; model: string; costUSD: number }
export interface CostSeriesResponse { range: string; granularity: "hourly" | "daily"; rows: CostRow[]; totalUSD: number }
export interface BudgetResponse {
  budgetUSD?: number; spentUSD: number; remainingUSD?: number; overageUSD: number;
  visualFraction?: number; resetCycle: string; activeBoundaryAt: string;
}
export async function getJSON<T>(path: string): Promise<T> {
  const response = await fetch(path);
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    throw new Error(payload?.error?.message ?? `Request failed (${response.status})`);
  }
  return response.json() as Promise<T>;
}
