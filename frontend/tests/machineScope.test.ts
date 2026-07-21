import { describe, expect, test } from "bun:test";
import { initialMachineLimit, matchesMachineSelection, toggledMachineSelection, visibleMachineItems } from "../src/machineScope";

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
});
