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
export interface CostRow {
  timestamp: string; agent: string; model: string; costUSD: number;
  inputTokens: number; outputTokens: number; cacheCreationTokens: number;
  cacheReadTokens: number; totalTokens: number;
  dataQuality: "timestamped" | "sessionEstimated" | "daily";
}
export interface CostSeriesResponse {
  range: string;
  granularity: "15min" | "hourly" | "6hour" | "daily";
  timelineStart?: string;
  timelineEndExclusive?: string;
  rows: CostRow[];
  totalUSD: number;
}
export interface BudgetResponse {
  budgetUSD?: number; spentUSD: number; remainingUSD?: number; overageUSD: number;
  usagePercentage?: number; visualFraction?: number; resetCycle: string; activeBoundaryAt: string;
  refreshIntervalSeconds: number;
}
export interface LoadStatusResponse {
  phase: "idle" | "loadingWeek" | "loadingHistory" | "refreshing" | "ready" | "failed";
  message: string;
  completed: number;
  total: number;
  isLoading: boolean;
}
export interface DashboardUIState {
  range: "recent12h" | "today" | "yesterday" | "week" | "month" | "custom";
  customStart: string;
  customEnd: string;
  selectedModels: string[];
  selectedAgents: string[];
  granularity: "15min" | "hourly" | "6hour" | "daily";
  chartMetric: "costUSD" | "totalTokens" | "inputTokens" | "outputTokens" | "cacheReadTokens" | "cacheCreationTokens";
}
export interface DashboardUIStateResponse { state?: DashboardUIState }
export async function getJSON<T>(path: string): Promise<T> {
  return requestJSON<T>(path);
}

export async function requestJSON<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, init);
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    throw new Error(payload?.error?.message ?? `Request failed (${response.status})`);
  }
  return response.json() as Promise<T>;
}
