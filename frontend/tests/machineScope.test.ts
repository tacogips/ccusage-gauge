import { describe, expect, test } from "bun:test";
import {
  initialMachineLimit,
  machineProgressDetail,
  machineQuery,
  matchesMachineSelection,
  requestedMachineIDs,
  toggledMachineSelection,
  visibleMachineItems,
} from "../src/machineScope";
import type { LoadStatusResponse, Machine } from "../src/api";

describe("machine scope", () => {
  test("shows five machines until the list is expanded", () => {
    const machines = ["local", "gce-1", "gce-2", "gce-3", "gce-4", "gce-5"];

    expect(initialMachineLimit).toBe(5);
    expect(visibleMachineItems(machines, false)).toEqual(machines.slice(0, 5));
    expect(visibleMachineItems(machines, true)).toEqual(machines);
  });

  test("an empty selection means all machines", () => {
    expect(matchesMachineSelection([], "local")).toBe(true);
    expect(matchesMachineSelection([], "gce")).toBe(true);
  });

  test("supports selecting and deselecting multiple machines", () => {
    const localAndGCE = toggledMachineSelection(toggledMachineSelection([], "local"), "gce");

    expect(localAndGCE).toEqual(["local", "gce"]);
    expect(matchesMachineSelection(localAndGCE, "local")).toBe(true);
    expect(matchesMachineSelection(localAndGCE, "another-machine")).toBe(false);
    expect(toggledMachineSelection(localAndGCE, "local")).toEqual(["gce"]);
  });

  test("builds repeated query parameters for exactly the selected enabled machines", () => {
    const machines: Machine[] = [
      { id: "local", displayName: "Local", kind: "local", enabled: true },
      { id: "remote", displayName: "Remote", kind: "ssh", enabled: true },
      { id: "disabled", displayName: "Disabled", kind: "ssh", enabled: false },
    ];

    expect(requestedMachineIDs(machines, ["local", "missing"])).toEqual(["local"]);
    expect(requestedMachineIDs(machines, ["missing"])).toEqual(["local"]);
    expect(machineQuery(["local", "remote"])).toBe("machine=local&machine=remote");
  });

  test("formats per-machine progress details", () => {
    const status: LoadStatusResponse = {
      phase: "refreshing",
      message: "Refreshing 2 machines",
      completed: 3,
      total: 7,
      isLoading: true,
      requested: "local,remote",
      machines: [
        { id: "local", phase: "refreshing", message: "Refreshing usage data", completed: 3, total: 5, isLoading: true },
        { id: "remote", phase: "refreshing", message: "Refreshing usage data", completed: 0, total: 2, isLoading: true },
      ],
    };

    expect(machineProgressDetail(status)).toBe("local 3/5 · remote 0/2");
  });
});
