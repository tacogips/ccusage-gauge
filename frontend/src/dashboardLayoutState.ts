import type { DashboardUIState } from "./api";

export function restoredFoldState(state: Partial<DashboardUIState> | undefined): {
  sidebarCollapsed: boolean;
  headerCollapsed: boolean;
} {
  return {
    sidebarCollapsed: state?.sidebarCollapsed === true,
    headerCollapsed: state?.headerCollapsed === true,
  };
}
