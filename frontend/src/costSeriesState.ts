import {
  DashboardRequestError,
  type AvailabilityErrorResponse,
  type CostSeriesResponse,
  type MachineScope,
  type MachineLatestEvent,
  requestJSON,
} from "./api";

export interface CostSeriesState extends CostSeriesResponse {
  availabilityError?: {
    code: AvailabilityCode;
    message: string;
  };
  refreshIntervalSeconds?: number;
  requestedCoverageStart?: string;
  availableCoverageStart?: string;
}

export type AvailabilityCode = "snapshot_unavailable" | "current_data_unavailable" | "range_unavailable";

const recognizedCodes = new Set([
  "snapshot_unavailable",
  "current_data_unavailable",
  "range_unavailable",
]);

export async function getCostSeriesState(path: string): Promise<CostSeriesState> {
  try {
    return await requestJSON<CostSeriesResponse>(path);
  } catch (error) {
    if (!(error instanceof DashboardRequestError)) throw error;
    const payload = error.payload as AvailabilityErrorResponse;
    const code = availabilityErrorCode(error);
    if (code == null || !isScope(payload.scope) || !isMarkers(payload.machineLatestEvents)) {
      throw error;
    }
    const query = new URL(path, "http://127.0.0.1").searchParams;
    const granularity = query.get("granularity");
    if (!["15min", "hourly", "6hour", "daily"].includes(granularity ?? "")) throw error;
    return {
      range: query.get("range") ?? "today",
      granularity: granularity as CostSeriesResponse["granularity"],
      rows: [],
      totalUSD: 0,
      scope: payload.scope,
      machineLatestEvents: payload.machineLatestEvents,
      availabilityError: {
        code,
        message: typeof payload.error === "string" ? error.message : payload.error.message,
      },
      refreshIntervalSeconds: payload.refreshIntervalSeconds,
      requestedCoverageStart: payload.requestedCoverageStart,
      availableCoverageStart: payload.availableCoverageStart,
    };
  }
}

export function availabilityErrorCode(error: unknown): AvailabilityCode | undefined {
  if (!(error instanceof DashboardRequestError)) return undefined;
  const payload = error.payload as AvailabilityErrorResponse;
  const code = typeof payload.error === "string" ? payload.error : payload.error?.code;
  return recognizedCodes.has(code) ? code as AvailabilityCode : undefined;
}

export function dashboardErrorMessage(...errors: unknown[]): string | undefined {
  const ordinaryError = errors.find((error) => error != null && availabilityErrorCode(error) == null);
  return ordinaryError instanceof Error ? ordinaryError.message : undefined;
}

function isScope(value: MachineScope | undefined): value is MachineScope {
  return value != null
    && Array.isArray(value.machineAvailability)
    && Array.isArray(value.lastHourDataGaps)
    && typeof value.evaluatedAt === "string";
}

function isMarkers(value: MachineLatestEvent[] | undefined): value is MachineLatestEvent[] {
  return Array.isArray(value) && value.every((marker) =>
    typeof marker.machine === "string"
    && typeof marker.markerState === "string"
    && typeof marker.inLastHour === "boolean");
}
