import type { DashboardUIState, DashboardUIStateResponse } from "./api";

export interface DashboardStateInitializationWorkflow {
  load: () => Promise<DashboardUIStateResponse>;
  apply: (state: DashboardUIState) => void;
  setLoaded: (loaded: boolean) => void;
  setPersistenceEnabled: (enabled: boolean) => void;
}

export async function initializeDashboardState(
  workflow: DashboardStateInitializationWorkflow,
): Promise<void> {
  try {
    const { state } = await workflow.load();
    if (state != null) workflow.apply(state);
    workflow.setPersistenceEnabled(true);
  } catch {
    workflow.setPersistenceEnabled(false);
  } finally {
    workflow.setLoaded(true);
  }
}
