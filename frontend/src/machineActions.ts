import { DashboardRequestError, type MachineRefreshResponse } from "./api";

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
