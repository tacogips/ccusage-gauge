import { describe, expect, test } from "bun:test";
import { actionRefetchTargets, isMachineExcluded, machineHealthDiagnosticContent, machineHealthSummary } from "../src/machineObservability";
import type { MachineStatus } from "../src/api";

const status = (collectionState: MachineStatus["collectionState"]): MachineStatus => ({
  id: "remote-a",
  displayName: "Remote A",
  kind: "ssh",
  enabled: true,
  collectionState,
  snapshotAvailable: collectionState === "healthy" || collectionState === "stale",
  collectionInProgress: false,
  stale: collectionState === "stale",
  consecutiveFailureCount: 0,
  refreshIntervalSeconds: 20,
});

describe("machine observability", () => {
  test("marks every non-healthy state as excluded", () => {
    expect(isMachineExcluded(status("healthy"))).toBe(false);
    for (const value of ["disabled", "neverCollected", "error", "stale"] as const) {
      expect(isMachineExcluded(status(value))).toBe(true);
    }
  });

  test("uses sanitized diagnostics for stale summaries", () => {
    const value = { ...status("stale"), lastError: { code: "timeout", message: "Connection timed out" } };
    expect(machineHealthSummary(value)).toBe("Connection timed out");
  });

  test("exposes persistent diagnostic, remediation, and exclusion details to the health panel", () => {
    const value: MachineStatus = {
      ...status("stale"),
      lastSuccessAt: "2026-07-24T00:15:00.000Z",
      unavailableSince: "2026-07-24T00:20:00.000Z",
      lastHourDataGap: {
        startAt: "2026-07-24T00:20:00.000Z",
        endAt: "2026-07-24T01:00:00.000Z",
      },
      lastError: {
        code: "host_key_verification_failed",
        message: "SSH host identity verification failed",
        detail: "The configured endpoint identity could not be verified.",
        remediation: "Verify the trusted host identity for the configured endpoint.",
      },
    };
    expect(machineHealthDiagnosticContent(value)).toEqual({
      message: "SSH host identity verification failed",
      detail: "The configured endpoint identity could not be verified.",
      remediation: "Verify the trusted host identity for the configured endpoint.",
      unavailableSince: "2026-07-24T00:20:00.000Z",
      excluded: true,
    });
  });

  test("refresh refetches every mutable dashboard surface", () => {
    expect(actionRefetchTargets("refresh", true)).toEqual([
      "status", "metrics", "cost-series", "budget",
    ]);
    expect(actionRefetchTargets("test-connection", true)).toEqual([]);
    expect(actionRefetchTargets("test-connection", false)).toEqual(["status"]);
  });
});
