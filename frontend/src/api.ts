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
  machine: string;
}
export interface MetricTotals extends Omit<MetricRow, "date" | "agent" | "model" | "machine"> {}
export interface MachineScope {
  requested: string;
  includedMachineIds: string[];
  staleMachineIds: string[];
  unavailableMachineIds: string[];
  generatedAt?: string;
}
export interface MetricsResponse { range: string; rows: MetricRow[]; totals: MetricTotals; scope: MachineScope }
export interface CostRow {
  timestamp: string; agent: string; model: string; costUSD: number;
  inputTokens: number; outputTokens: number; cacheCreationTokens: number;
  cacheReadTokens: number; totalTokens: number;
  dataQuality: "timestamped" | "sessionEstimated" | "daily";
  machine: string;
}
export interface CostSeriesResponse {
  range: string;
  granularity: "15min" | "hourly" | "6hour" | "daily";
  timelineStart?: string;
  timelineEndExclusive?: string;
  rows: CostRow[];
  totalUSD: number;
  scope: MachineScope;
}
export interface BudgetResponse {
  budgetUSD?: number; spentUSD: number; remainingUSD?: number; overageUSD: number;
  usagePercentage?: number; visualFraction?: number; resetCycle: string; activeBoundaryAt: string;
  refreshIntervalSeconds: number;
  scope: MachineScope;
}
export interface LoadStatusResponse {
  phase: "idle" | "loadingWeek" | "loadingHistory" | "refreshing" | "ready" | "failed";
  message: string;
  completed: number;
  total: number;
  isLoading: boolean;
  requested: string;
  machines: Array<{
    id: string; phase: LoadStatusResponse["phase"]; message: string;
    completed: number; total: number; isLoading: boolean;
    coverageStart?: string; requestedCoverageStart?: string;
  }>;
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
export interface SSHConnection {
  host: string; port: number; user: string; identityFile?: string;
  extraOptions: string[]; remoteCcusagePath: string;
}
export interface Machine {
  id: string; displayName: string; kind: "local" | "ssh"; enabled: boolean; ssh?: SSHConnection;
}
export interface MachineStatus {
  id: string; displayName: string; kind: "local" | "ssh"; enabled: boolean;
  collectionState: "disabled" | "neverCollected" | "healthy" | "stale" | "error";
  snapshotAvailable: boolean; collectionInProgress: boolean; stale: boolean;
  coverageStart?: string; snapshotGeneratedAt?: string; lastAttemptAt?: string;
  lastSuccessAt?: string; lastErrorAt?: string;
  lastError?: { code: string; message: string }; refreshIntervalSeconds: number;
}
export interface MachinesResponse { machines: Machine[] }
export interface MachineStatusResponse { requested: string; generatedAt: string; machines: MachineStatus[] }
export async function getJSON<T>(path: string): Promise<T> {
  return requestJSON<T>(path);
}

export async function requestJSON<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, init);
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    throw new Error(payload?.error?.message ?? `Request failed (${response.status})`);
  }
  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

export function mutationJSON<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("X-CCUsage-Gauge-Mutation", "1");
  if (init.body != null) headers.set("Content-Type", "application/json");
  return requestJSON<T>(path, { ...init, headers });
}
