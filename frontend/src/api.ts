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
  dataDisposition: "current" | "historical";
  includedMachineIds: string[];
  staleMachineIds: string[];
  unavailableMachineIds: string[];
  excludedFromCurrentTotalsMachineIds: string[];
  machineAvailability: MachineAvailability[];
  lastHourDataGaps: MachineDataGap[];
  evaluatedAt: string;
  generatedAt?: string;
}
export interface MachineAvailability {
  machine: string; available: boolean; unavailableSince?: string;
  reasonCode: string;
}
export interface MachineDataGap {
  machine: string; startAt: string; endAt: string; reasonCode: string;
}
export interface MachineLatestEvent {
  machine: string; latestEventAt?: string;
  markerState: "observed" | "noEvent" | "stale" | "unavailable";
  inLastHour: boolean;
  dataQuality?: "timestamped" | "sessionEstimated";
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
  machineLatestEvents: MachineLatestEvent[];
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
  selectedMachines: string[];
  granularity: "15min" | "hourly" | "6hour" | "daily";
  chartMetric: "costUSD" | "totalTokens" | "inputTokens" | "outputTokens" | "cacheReadTokens" | "cacheCreationTokens";
  stackBy: "model" | "machine";
}
export interface DashboardUIStateResponse { state?: DashboardUIState }
export interface SSHConnection {
  host: string; port: number; user: string; identityFile?: string;
  extraOptions: string[]; remoteCcusagePath: string;
  proxy?: SSHProxy;
}
export type SSHProxy =
  | { kind: "direct" }
  | { kind: "jump"; host: string; port: number; user: string; identityFile?: string; knownHostsFile?: string }
  | { kind: "command"; executable: string };
export interface Machine {
  id: string; displayName: string; kind: "local" | "ssh"; enabled: boolean; ssh?: SSHConnection;
}
export interface MachineStatus {
  id: string; displayName: string; kind: "local" | "ssh"; enabled: boolean;
  collectionState: "disabled" | "neverCollected" | "healthy" | "stale" | "error";
  snapshotAvailable: boolean; collectionInProgress: boolean; stale: boolean;
  coverageStart?: string; snapshotGeneratedAt?: string; lastAttemptAt?: string;
  lastSuccessAt?: string; consecutiveFailureCount: number; unavailableSince?: string;
  staleSince?: string; lastErrorAt?: string;
  lastError?: SanitizedDiagnostic; lastHourDataGap?: { startAt: string; endAt: string };
  refreshIntervalSeconds: number;
}
export interface SanitizedDiagnostic {
  code: string; message: string; detail?: string; remediation?: string;
}
export interface MachineConnectionTestResponse {
  machine: string; status: "reachable" | "failed"; testedAt: string;
  diagnostic?: SanitizedDiagnostic;
}
export interface MachineRefreshResponse {
  status: "ok" | "failed"; requested: string; refreshedMachineIds: string[];
  failedMachineIds: string[]; generatedAt: string; diagnostic?: SanitizedDiagnostic;
}
export interface AvailabilityErrorResponse {
  error: string | { code: string; message: string };
  machine?: string; collectionState?: MachineStatus["collectionState"];
  refreshIntervalSeconds?: number; scope?: MachineScope;
  machineLatestEvents?: MachineLatestEvent[];
  requestedCoverageStart?: string;
  availableCoverageStart?: string;
}
export interface MachinesResponse { machines: Machine[] }
export interface ChartColorScheme { machines: Record<string, string>; models: Record<string, string> }
export interface ChartColorsResponse { light: ChartColorScheme; dark: ChartColorScheme }
export interface MachineStatusResponse { requested: string; generatedAt: string; machines: MachineStatus[] }
export const dashboardRequestTimeoutMilliseconds = 120_000;

export async function getJSON<T>(path: string): Promise<T> {
  return requestJSON<T>(path);
}

export async function requestJSON<T>(
  path: string,
  init: RequestInit = {},
  timeoutMilliseconds = dashboardRequestTimeoutMilliseconds,
): Promise<T> {
  const controller = new AbortController();
  let timedOut = false;
  const abortFromCaller = () => controller.abort(init.signal?.reason);
  if (init.signal?.aborted) abortFromCaller();
  else init.signal?.addEventListener("abort", abortFromCaller, { once: true });
  const timer = globalThis.setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, Math.max(1, timeoutMilliseconds));

  try {
    const response = await fetch(path, { ...init, signal: controller.signal });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      const message = typeof payload?.error === "string"
        ? payload.error
        : payload?.error?.message ?? `Request failed (${response.status})`;
      throw new DashboardRequestError(response.status, message, payload);
    }
    if (response.status === 204) return undefined as T;
    return await response.json() as T;
  } catch (error) {
    if (timedOut) throw new DashboardRequestTimeoutError(timeoutMilliseconds);
    throw error;
  } finally {
    globalThis.clearTimeout(timer);
    init.signal?.removeEventListener("abort", abortFromCaller);
  }
}

export class DashboardRequestError<T = unknown> extends Error {
  constructor(
    public readonly status: number,
    message: string,
    public readonly payload: T,
  ) {
    super(message);
    this.name = "DashboardRequestError";
  }
}

export class DashboardRequestTimeoutError extends Error {
  constructor(public readonly timeoutMilliseconds: number) {
    super(`Dashboard request timed out after ${Math.ceil(timeoutMilliseconds / 1_000)} seconds.`);
    this.name = "DashboardRequestTimeoutError";
  }
}

export function mutationJSON<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("X-CCUsage-Gauge-Mutation", "1");
  if (init.body != null) headers.set("Content-Type", "application/json");
  return requestJSON<T>(path, { ...init, headers });
}
