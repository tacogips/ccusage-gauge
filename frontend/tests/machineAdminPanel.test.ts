import { describe, expect, test } from "bun:test";
import { machineControlsDisabled } from "../src/MachineAdminPanel";

describe("machine administration controls", () => {
  test("disables every row control only for the active machine lifecycle", () => {
    const inFlight = { "remote-a": true, "remote-b": false };
    expect(machineControlsDisabled(inFlight, "remote-a")).toBe(true);
    expect(machineControlsDisabled(inFlight, "remote-b")).toBe(false);
    expect(machineControlsDisabled(inFlight, "remote-c")).toBe(false);
  });
});
