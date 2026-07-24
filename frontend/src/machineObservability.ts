import type { MachineStatus } from "./api";

export function machineHealthSummary(status: MachineStatus | undefined) {
  if (status == null) return "Status unavailable";
  if (status.collectionState === "healthy") return "Healthy";
  if (status.collectionState === "disabled") return "Disabled";
  if (status.collectionState === "neverCollected") return "No successful collection";
  if (status.collectionState === "error") return status.lastError?.message ?? "Collection failed";
  return status.lastError?.message ?? "Retained data is stale";
}

export function machineHealthDiagnosticContent(status: MachineStatus) {
  return {
    message: status.lastError?.message ?? "Collection has not produced current data.",
    detail: status.lastError?.detail,
    remediation: status.lastError?.remediation,
    unavailableSince: status.unavailableSince ?? status.staleSince,
    excluded: status.collectionState !== "healthy",
  };
}

export function actionRefetchTargets(action: "test-connection" | "refresh", failed: boolean) {
  // A reachable connection can clear an error/stale badge, so refresh the
  // status panel; a failed test changes no server-side state.
  if (action === "test-connection") return failed ? [] : ["status"];
  return ["status", "metrics", "cost-series", "budget"] as const;
}

export function isMachineExcluded(status: MachineStatus | undefined) {
  return status != null && ["disabled", "neverCollected", "error", "stale"].includes(status.collectionState);
}
