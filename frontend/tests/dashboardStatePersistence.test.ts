import { describe, expect, test } from "bun:test";
import type { DashboardUIState } from "../src/api";
import { initializeDashboardState } from "../src/dashboardStatePersistence";

const state: DashboardUIState = {
  range: "today",
  customStart: "2026-07-01",
  customEnd: "2026-07-02",
  selectedModels: ["gpt-test"],
  selectedAgents: ["codex"],
  selectedMachines: ["local"],
  granularity: "hourly",
  chartMetric: "costUSD",
  stackBy: "subdirectory",
};

describe("dashboard state initialization", () => {
  test("applies confirmed state before enabling persistence", async () => {
    const order: string[] = [];
    await initializeDashboardState({
      load: async () => {
        order.push("load");
        return { state };
      },
      apply: (loaded) => {
        expect(loaded).toEqual(state);
        order.push("apply");
      },
      setPersistenceEnabled: (enabled) => order.push(`persistence:${enabled}`),
      setLoaded: (loaded) => order.push(`loaded:${loaded}`),
    });

    expect(order).toEqual(["load", "apply", "persistence:true", "loaded:true"]);
  });

  test("does not enable autosave after an initial load failure", async () => {
    const order: string[] = [];
    let applied = false;
    await initializeDashboardState({
      load: async () => {
        order.push("load");
        throw new Error("state unavailable");
      },
      apply: () => {
        applied = true;
      },
      setPersistenceEnabled: (enabled) => order.push(`persistence:${enabled}`),
      setLoaded: (loaded) => order.push(`loaded:${loaded}`),
    });

    expect(applied).toBe(false);
    expect(order).toEqual(["load", "persistence:false", "loaded:true"]);
  });
});
