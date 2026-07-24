import type { MachineRefreshResponse } from "./api";

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
