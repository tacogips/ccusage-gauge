import { describe, expect, test } from "bun:test";
import {
  machineSaveErrors,
  machineMetadataCleanupWarning,
  removeMachineCatalog,
  runMachineCatalogMutation,
  runMachineRefreshLifecycle,
  saveMachineCatalog,
  toggleMachineCatalog,
  type MachineActionDiagnostic,
  type MachineCatalogRefreshers,
  type MachineMutationClient,
} from "../src/machineActions";
import {
  DashboardRequestError,
  type Machine,
  type MachineRefreshResponse,
} from "../src/api";
import { emptyMachineDraft } from "../src/machineForm";

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

describe("machine catalog mutation refresh", () => {
  const machine = (enabled: boolean): Machine => ({
    id: "remote-a",
    displayName: "Remote A",
    kind: "ssh",
    enabled,
    codexSessionDirs: [],
    claudeConfigDirs: [],
    includeDefaultCodexDir: true,
    includeDefaultClaudeDir: true,
    ssh: {
      host: "remote.internal",
      port: 22,
      user: "operator",
      extraOptions: [],
      remoteCcusagePath: "ccusage",
    },
  });
  const draft = {
    ...emptyMachineDraft(),
    id: "remote-a",
    displayName: "Remote A",
    host: "remote.internal",
    user: "operator",
  };
  const refreshers = (calls: string[]): MachineCatalogRefreshers => ({
    refreshMachines: async () => { calls.push("machines"); },
    refreshMachineStatuses: async () => { calls.push("statuses"); },
    refreshSubdirectories: async () => { calls.push("subdirectories"); },
  });
  const expectCatalogRefreshes = (calls: string[], mutation: string) => {
    expect(calls[0]).toBe(mutation);
    expect(calls.slice(1).sort()).toEqual([
      "machines",
      "statuses",
      "subdirectories",
    ]);
  };

  test("executes production create and edit mutations before refreshing every catalog", async () => {
    for (const editingID of [undefined, "remote-a"]) {
      const calls: string[] = [];
      const operation = editingID == null ? "create" : "edit";
      const request: MachineMutationClient = async (path, init) => {
        calls.push(`${operation}:${init.method}:${path}`);
        expect(JSON.parse(String(init.body))).toMatchObject({
          displayName: "Remote A",
          kind: "ssh",
        });
        return machine(true) as never;
      };

      await saveMachineCatalog({
        draft,
        editingID,
        request,
        saved: () => { calls.push(`${operation}:saved`); },
        ...refreshers(calls),
      });

      expect(calls[1]).toBe(`${operation}:saved`);
      expectCatalogRefreshes(
        [calls[0], ...calls.slice(2)],
        editingID == null
          ? "create:POST:/api/machines"
          : "edit:PUT:/api/machines/remote-a",
      );
    }
  });

  test("executes production enable and disable mutations before refreshing every catalog", async () => {
    for (const enabled of [false, true]) {
      const calls: string[] = [];
      const operation = enabled ? "disable" : "enable";
      const request: MachineMutationClient = async (path, init) => {
        calls.push(`${operation}:${init.method}:${path}:${String(init.body)}`);
        return machine(!enabled) as never;
      };

      await toggleMachineCatalog({
        machine: machine(enabled),
        request,
        ...refreshers(calls),
      });

      expectCatalogRefreshes(
        calls,
        `${operation}:PATCH:/api/machines/remote-a:${JSON.stringify({ enabled: !enabled })}`,
      );
    }
  });

  test("executes the production remove mutation before selection and catalog refreshes", async () => {
    const calls: string[] = [];
    const request: MachineMutationClient = async (path, init) => {
      calls.push(`remove:${init.method}:${path}`);
      return undefined as never;
    };

    await removeMachineCatalog({
      machine: machine(true),
      request,
      removed: (machineID) => { calls.push(`removed:${machineID}`); },
      ...refreshers(calls),
    });

    expect(calls[1]).toBe("removed:remote-a");
    expectCatalogRefreshes(
      [calls[0], ...calls.slice(2)],
      "remove:DELETE:/api/machines/remote-a",
    );
  });

  test("does not publish removal or catalog refreshes when the production mutation fails", async () => {
    const calls: string[] = [];

    await expect(removeMachineCatalog({
      machine: machine(true),
      request: async () => {
        calls.push("remove");
        throw new Error("mutation failed");
      },
      removed: () => { calls.push("removed"); },
      ...refreshers(calls),
    })).rejects.toThrow("mutation failed");

    expect(calls).toEqual(["remove"]);
  });

  test("preserves committed mutation success and reports catalogs still stale after retry", async () => {
    const calls: string[] = [];
    const reported: string[][] = [];
    const result = await runMachineCatalogMutation({
      mutate: async () => {
        calls.push("mutation");
        return "committed";
      },
      refreshMachines: async () => {
        calls.push("machines");
        throw new Error("machines unavailable");
      },
      refreshMachineStatuses: async () => {
        calls.push("statuses");
        throw new Error("statuses unavailable");
      },
      refreshSubdirectories: async () => {
        calls.push("subdirectories");
        throw new Error("subdirectories unavailable");
      },
      reportCatalogRefreshFailures: (failures) => {
        reported.push(failures.map((failure) => failure.catalog));
      },
    });

    expect(result).toBe("committed");
    expect(calls.filter((call) => call === "mutation")).toHaveLength(1);
    expect(calls.filter((call) => call === "machines")).toHaveLength(2);
    expect(calls.filter((call) => call === "statuses")).toHaveLength(2);
    expect(calls.filter((call) => call === "subdirectories")).toHaveLength(2);
    expect(reported).toEqual([["machines", "statuses", "subdirectories"]]);
  });

  test("does not reclassify committed create, edit, toggle, or remove when refresh stays unavailable", async () => {
    const operations: Array<() => Promise<unknown>> = [];
    const calls: string[] = [];
    const failingRefreshers = {
      refreshMachines: async () => { throw new Error("offline"); },
      refreshMachineStatuses: async () => { throw new Error("offline"); },
      refreshSubdirectories: async () => { throw new Error("offline"); },
      reportCatalogRefreshFailures: () => { calls.push("refresh-warning"); },
    };
    const request: MachineMutationClient = async (path, init) => {
      calls.push(`${init.method}:${path}`);
      return machine(true) as never;
    };

    operations.push(
      () => saveMachineCatalog({
        draft,
        request,
        saved: () => { calls.push("create-saved"); },
        ...failingRefreshers,
      }),
      () => saveMachineCatalog({
        draft,
        editingID: "remote-a",
        request,
        saved: () => { calls.push("edit-saved"); },
        ...failingRefreshers,
      }),
      () => toggleMachineCatalog({
        machine: machine(false),
        request,
        ...failingRefreshers,
      }),
      () => removeMachineCatalog({
        machine: machine(true),
        request,
        removed: () => { calls.push("removed"); },
        ...failingRefreshers,
      }),
    );

    for (const operation of operations) await operation();

    expect(calls.filter((call) => call === "refresh-warning")).toHaveLength(4);
    expect(calls).toContain("create-saved");
    expect(calls).toContain("edit-saved");
    expect(calls).toContain("removed");
    expect(calls.filter((call) => call.startsWith("POST:/api/machines"))).toHaveLength(1);
    expect(calls.filter((call) => call.startsWith("PUT:/api/machines/remote-a"))).toHaveLength(1);
    expect(calls.filter((call) => call.startsWith("PATCH:/api/machines/remote-a"))).toHaveLength(1);
    expect(calls.filter((call) => call.startsWith("DELETE:/api/machines/remote-a"))).toHaveLength(1);
  });
});

describe("machine metadata cleanup warning", () => {
  test("reports pending cleanup without exposing directory metadata", () => {
    expect(machineMetadataCleanupWarning([])).toBeUndefined();
    expect(machineMetadataCleanupWarning(["alpha", "remote-a"]))
      .toBe("Directory-name cleanup is pending for: alpha, remote-a. The dashboard will retry automatically.");
  });
});

describe("machine save errors", () => {
  test("preserves indexed server field errors", () => {
    const result = machineSaveErrors(new DashboardRequestError(
      422,
      "Machine validation failed",
      { error: { fieldErrors: { "codexSessionDirs[1]": "invalid path" } } },
    ));
    expect(result.fieldErrors).toEqual({ "codexSessionDirs[1]": "invalid path" });
    expect(result.message).toBe("Correct the highlighted fields. codexSessionDirs[1]: invalid path");
  });

  test("keeps unmapped server field errors visible in the form alert", () => {
    const result = machineSaveErrors(new DashboardRequestError(
      422,
      "Machine validation failed",
      { error: { fieldErrors: { unexpectedSourceField: "invalid value" } } },
    ));
    expect(result.message).toContain("unexpectedSourceField: invalid value");
  });
});
