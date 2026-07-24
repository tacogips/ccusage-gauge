import { describe, expect, test } from "bun:test";
import { runMachineRefreshLifecycle, type MachineActionDiagnostic } from "../src/machineActions";
import type { MachineRefreshResponse } from "../src/api";

const response = (status: "ok" | "failed"): MachineRefreshResponse => ({
  status,
  requested: "remote-a",
  refreshedMachineIds: status === "ok" ? ["remote-a"] : [],
  failedMachineIds: status === "failed" ? ["remote-a"] : [],
  generatedAt: "2026-07-24T00:00:00.000Z",
  diagnostic: status === "failed"
    ? { code: "timeout", message: "Collection timed out", remediation: "Retry later." }
    : undefined,
});

describe("machine refresh lifecycle", () => {
  test("settles and retains the action diagnostic when a post-refresh refetch fails", async () => {
    let diagnostic: MachineActionDiagnostic | undefined;
    let refetchError: unknown;
    let settled = false;

    await runMachineRefreshLifecycle({
      request: async () => response("failed"),
      refetch: async () => { throw new Error("status refetch failed"); },
      setDiagnostic: (value) => { diagnostic = value; },
      reportRefetchError: (error) => { refetchError = error; },
      settled: () => { settled = true; },
    });

    expect(diagnostic).toEqual({
      message: "Collection timed out Retry later.",
      failed: true,
    });
    expect((refetchError as Error).message).toBe("status refetch failed");
    expect(settled).toBe(true);
  });

  test("settles after a rejected refresh request and still attempts state refetch", async () => {
    let refetched = false;
    let settled = false;

    await runMachineRefreshLifecycle({
      request: async () => { throw new Error("network unavailable"); },
      refetch: async () => { refetched = true; },
      setDiagnostic: (value) => expect(value).toEqual({ message: "network unavailable", failed: true }),
      settled: () => { settled = true; },
    });

    expect(refetched).toBe(true);
    expect(settled).toBe(true);
  });

  test("settles after successful request and refetch", async () => {
    let diagnostic: MachineActionDiagnostic | undefined;
    let settled = false;

    await runMachineRefreshLifecycle({
      request: async () => response("ok"),
      refetch: async () => undefined,
      setDiagnostic: (value) => { diagnostic = value; },
      settled: () => { settled = true; },
    });

    expect(diagnostic).toEqual({ message: "Refresh completed.", failed: false });
    expect(settled).toBe(true);
  });
});
