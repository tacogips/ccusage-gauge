import { afterEach, describe, expect, test } from "bun:test";
import { availabilityErrorCode, dashboardErrorMessage, getCostSeriesState } from "../src/costSeriesState";
import { DashboardRequestError } from "../src/api";

const originalFetch = globalThis.fetch;
afterEach(() => { globalThis.fetch = originalFetch; });

describe("cost-series availability state", () => {
  test("preserves range-unavailable observability metadata", async () => {
    globalThis.fetch = (async () => new Response(JSON.stringify({
      error: "range_unavailable",
      refreshIntervalSeconds: 20,
      requestedCoverageStart: "2026-07-01",
      availableCoverageStart: "2026-07-10",
      scope: {
        requested: "remote-a",
        dataDisposition: "historical",
        includedMachineIds: [],
        staleMachineIds: [],
        unavailableMachineIds: ["remote-a"],
        excludedFromCurrentTotalsMachineIds: [],
        machineAvailability: [{
          machine: "remote-a", available: false,
          unavailableSince: "2026-07-24T00:00:00.000Z", reasonCode: "range_unavailable",
        }],
        lastHourDataGaps: [{
          machine: "remote-a",
          startAt: "2026-07-23T23:30:00.000Z",
          endAt: "2026-07-24T00:00:00.000Z",
          reasonCode: "range_unavailable",
        }],
        evaluatedAt: "2026-07-24T00:00:00.000Z",
      },
      machineLatestEvents: [{
        machine: "remote-a",
        latestEventAt: "2026-07-23T22:00:00.000Z",
        markerState: "stale",
        inLastHour: false,
        dataQuality: "sessionEstimated",
      }],
    }), { status: 503, headers: { "Content-Type": "application/json" } })) as typeof fetch;

    const state = await getCostSeriesState("/api/cost-series?range=custom&granularity=hourly");

    expect(state.availabilityError?.code).toBe("range_unavailable");
    expect(state.requestedCoverageStart).toBe("2026-07-01");
    expect(state.availableCoverageStart).toBe("2026-07-10");
    expect(state.scope.lastHourDataGaps).toHaveLength(1);
    expect(state.machineLatestEvents[0]?.markerState).toBe("stale");
    expect(state.rows).toEqual([]);
  });

  test("rejects malformed recognized responses through the ordinary error boundary", async () => {
    globalThis.fetch = (async () => new Response(JSON.stringify({
      error: "snapshot_unavailable",
      scope: { requested: "remote-a" },
    }), { status: 503, headers: { "Content-Type": "application/json" } })) as typeof fetch;

    expect(getCostSeriesState("/api/cost-series?range=today&granularity=hourly")).rejects.toThrow(
      "snapshot_unavailable",
    );
  });

  test("availability failures do not replace machine-health diagnostics", () => {
    const unavailable = new DashboardRequestError("snapshot_unavailable", 503, {
      error: "snapshot_unavailable",
    });
    const ordinary = new Error("Unexpected dashboard failure");

    expect(availabilityErrorCode(unavailable)).toBe("snapshot_unavailable");
    expect(dashboardErrorMessage(unavailable)).toBeUndefined();
    expect(dashboardErrorMessage(unavailable, ordinary)).toBe("Unexpected dashboard failure");
  });
});
