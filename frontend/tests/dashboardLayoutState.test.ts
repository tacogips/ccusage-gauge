import { describe, expect, test } from "bun:test";
import type { DashboardUIState } from "../src/api";
import { restoredFoldState } from "../src/dashboardLayoutState";

describe("restored dashboard fold state", () => {
  test("expands both regions for missing legacy state", () => {
    expect(restoredFoldState(undefined)).toEqual({ sidebarCollapsed: false, headerCollapsed: false });
    expect(restoredFoldState({})).toEqual({ sidebarCollapsed: false, headerCollapsed: false });
  });

  test("restores only literal true values", () => {
    expect(restoredFoldState({ sidebarCollapsed: true })).toEqual({
      sidebarCollapsed: true,
      headerCollapsed: false,
    });
    expect(restoredFoldState({ headerCollapsed: "yes" } as unknown as Partial<DashboardUIState>))
      .toEqual({ sidebarCollapsed: false, headerCollapsed: false });
  });
});
