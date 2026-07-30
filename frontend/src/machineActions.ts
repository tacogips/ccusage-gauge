import {
  DashboardRequestError,
  type Machine,
  type MachineRefreshResponse,
} from "./api";
import {
  machineRequestBody,
  machineSessionSourceBody,
  type MachineDraft,
} from "./machineForm";

export interface MachineActionDiagnostic {
  message: string;
  failed: boolean;
}

export interface MachineRefreshLifecycle {
  request: () => Promise<MachineRefreshResponse>;
  refetch: () => Promise<unknown>;
  setDiagnostic: (diagnostic: MachineActionDiagnostic) => void;
  reportRefetchError?: (error: unknown) => void;
  settled: () => void;
}

export interface MachineCatalogRefreshers {
  refreshMachines: () => unknown | Promise<unknown>;
  refreshMachineStatuses: () => unknown | Promise<unknown>;
  refreshSubdirectories: () => unknown | Promise<unknown>;
  reportCatalogRefreshFailures?: (failures: MachineCatalogRefreshFailure[]) => void;
}

export interface MachineCatalogMutation<Result> extends MachineCatalogRefreshers {
  mutate: () => Promise<Result>;
}

export type MachineCatalogName = "machines" | "statuses" | "subdirectories";

export interface MachineCatalogRefreshFailure {
  catalog: MachineCatalogName;
  error: unknown;
}

export type MachineMutationClient = <Result>(
  path: string,
  init: RequestInit,
) => Promise<Result>;

export function machineMetadataCleanupWarning(machineIDs: readonly string[]): string | undefined {
  if (machineIDs.length === 0) return undefined;
  return `Directory-name cleanup is pending for: ${machineIDs.join(", ")}. The dashboard will retry automatically.`;
}

interface MachineCatalogRequest extends MachineCatalogRefreshers {
  request: MachineMutationClient;
}

export interface SaveMachineCatalogRequest extends MachineCatalogRequest {
  draft: MachineDraft;
  editingID?: string;
  saved: () => void;
}

export interface ToggleMachineCatalogRequest extends MachineCatalogRequest {
  machine: Machine;
}

export interface RemoveMachineCatalogRequest extends MachineCatalogRequest {
  machine: Machine;
  removed: (machineID: string) => void;
}

export async function refreshMachineCatalogs(
  refreshers: MachineCatalogRefreshers,
): Promise<MachineCatalogRefreshFailure[]> {
  const refreshes: Array<[MachineCatalogName, () => unknown | Promise<unknown>]> = [
    ["machines", refreshers.refreshMachines],
    ["statuses", refreshers.refreshMachineStatuses],
    ["subdirectories", refreshers.refreshSubdirectories],
  ];
  const results = await Promise.all(refreshes.map(async ([catalog, refresh]) => {
    try {
      await refresh();
      return undefined;
    } catch {
      try {
        await refresh();
        return undefined;
      } catch (error) {
        return { catalog, error };
      }
    }
  }));
  return results.filter((failure): failure is MachineCatalogRefreshFailure => failure != null);
}

export async function runMachineCatalogMutation<Result>(
  lifecycle: MachineCatalogMutation<Result>,
): Promise<Result> {
  const result = await lifecycle.mutate();
  const failures = await refreshMachineCatalogs(lifecycle);
  if (failures.length > 0) {
    try {
      lifecycle.reportCatalogRefreshFailures?.(failures);
    } catch {
      // A diagnostic callback must not reclassify an already committed mutation.
    }
  }
  return result;
}

export function saveMachineCatalog(
  lifecycle: SaveMachineCatalogRequest,
): Promise<Machine> {
  const isLocal = lifecycle.draft.kind === "local";
  return runMachineCatalogMutation({
    ...lifecycle,
    mutate: async () => {
      const result = await lifecycle.request<Machine>(
        lifecycle.editingID == null ? "/api/machines" : `/api/machines/${lifecycle.editingID}`,
        {
          method: lifecycle.editingID == null ? "POST" : isLocal ? "PATCH" : "PUT",
          body: JSON.stringify(
            isLocal
              ? machineSessionSourceBody(lifecycle.draft)
              : machineRequestBody(lifecycle.draft, lifecycle.editingID == null),
          ),
        },
      );
      lifecycle.saved();
      return result;
    },
  });
}

export function toggleMachineCatalog(
  lifecycle: ToggleMachineCatalogRequest,
): Promise<Machine> {
  return runMachineCatalogMutation({
    ...lifecycle,
    mutate: () => lifecycle.request<Machine>(`/api/machines/${lifecycle.machine.id}`, {
      method: "PATCH",
      body: JSON.stringify({ enabled: !lifecycle.machine.enabled }),
    }),
  });
}

export function removeMachineCatalog(
  lifecycle: RemoveMachineCatalogRequest,
): Promise<void> {
  return runMachineCatalogMutation({
    ...lifecycle,
    mutate: async () => {
      await lifecycle.request<void>(
        `/api/machines/${lifecycle.machine.id}`,
        { method: "DELETE" },
      );
      lifecycle.removed(lifecycle.machine.id);
    },
  });
}

export async function runMachineRefreshLifecycle(lifecycle: MachineRefreshLifecycle): Promise<void> {
  try {
    try {
      const result = await lifecycle.request();
      lifecycle.setDiagnostic(refreshDiagnostic(result));
    } catch (error) {
      lifecycle.setDiagnostic({
        message: error instanceof Error ? error.message : "Refresh failed.",
        failed: true,
      });
    }

    try {
      await lifecycle.refetch();
    } catch (error) {
      lifecycle.reportRefetchError?.(error);
    }
  } finally {
    lifecycle.settled();
  }
}

export function refreshDiagnostic(result: MachineRefreshResponse): MachineActionDiagnostic {
  if (result.status === "ok") return { message: "Refresh completed.", failed: false };
  return {
    message: `${result.diagnostic?.message ?? "Refresh failed."} ${result.diagnostic?.remediation ?? ""}`.trim(),
    failed: true,
  };
}

export function machineSaveErrors(error: unknown): {
  fieldErrors: Record<string, string>;
  message: string;
} {
  if (error instanceof DashboardRequestError) {
    const payload = error.payload as { error?: { fieldErrors?: Record<string, string> } };
    const fieldErrors = payload.error?.fieldErrors ?? {};
    const details = Object.entries(fieldErrors).map(([field, message]) => `${field}: ${message}`).join(" ");
    return {
      fieldErrors,
      message: details.length === 0 ? error.message : `Correct the highlighted fields. ${details}`,
    };
  }
  return {
    fieldErrors: {},
    message: error instanceof Error ? error.message : "Machine save failed.",
  };
}
