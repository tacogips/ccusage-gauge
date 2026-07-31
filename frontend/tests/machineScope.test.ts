import { describe, expect, test } from "bun:test";
import {
  allDirectoryItemsSelected,
  clearUncheckedDirectorySelections,
  directoryFiltersVisible,
  directoryLabels,
  directoryQuery,
  initialDirectoryLimit,
  initialMachineLimit,
  machineProgressDetail,
  machineQuery,
  matchesMachineSelection,
  orderedDirectoryItems,
  requestedMachineIDs,
  toggledMachineSelection,
  visibleDirectoryItems,
  visibleMachineItems,
  wholeMachineSelected,
} from "../src/machineScope";
import type { LoadStatusResponse, Machine } from "../src/api";

describe("machine scope", () => {
  test("shows five machines until the list is expanded", () => {
    const machines = ["local", "gce-1", "gce-2", "gce-3", "gce-4", "gce-5"];

    expect(initialMachineLimit).toBe(5);
    expect(visibleMachineItems(machines, false)).toEqual(machines.slice(0, 5));
    expect(visibleMachineItems(machines, true)).toEqual(machines);
  });

  test("puts checked directories first and limits long directory lists", () => {
    const directories = [
      "/work/a", "/work/b", "/work/c", "/work/d", "/work/e", "/work/f",
      "/work/g", "/work/h", "/work/i", "/work/j", "/work/k",
    ];
    const labels = new Map(directories.map((directory) => [
      directory,
      directory.split("/").at(-1) ?? directory,
    ]));
    labels.set("/work/a", "Zulu");
    labels.set("/work/b", "Alpha");

    expect(initialDirectoryLimit).toBe(10);
    expect(orderedDirectoryItems(directories, ["/work/f", "/work/c"], labels)).toEqual([
      "/work/c", "/work/f", "/work/b", "/work/d", "/work/e", "/work/g",
      "/work/h", "/work/i", "/work/j", "/work/k", "/work/a",
    ]);
    expect(visibleDirectoryItems(directories, ["/work/f"], false, labels)).toEqual([
      "/work/f", "/work/b", "/work/c", "/work/d", "/work/e",
      "/work/g", "/work/h", "/work/i", "/work/j", "/work/k",
    ]);
    expect(visibleDirectoryItems(directories, ["/work/f"], true, labels)).toEqual([
      "/work/f", "/work/b", "/work/c", "/work/d", "/work/e", "/work/g",
      "/work/h", "/work/i", "/work/j", "/work/k", "/work/a",
    ]);
    expect(allDirectoryItemsSelected(directories, directories)).toBe(true);
    expect(allDirectoryItemsSelected(directories, ["/work/a", "/work/stale"])).toBe(false);
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

  test("distinguishes whole-machine selection from directory-only selection", () => {
    expect(wholeMachineSelected(["local"], {}, "local")).toBe(true);
    expect(wholeMachineSelected(["local"], { local: ["/work/project"] }, "local")).toBe(false);
    expect(wholeMachineSelected([], {}, "local")).toBe(false);
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

  test("builds machine-scoped encoded directory queries and omits unchecked machines", () => {
    expect(directoryQuery({
      local: ["/home/dev/my project", "/home/dev/another"],
      remote: ["/srv/hidden"],
    }, ["local"])).toBe(
      "directory=local%3A%2Fhome%2Fdev%2Fanother&directory=local%3A%2Fhome%2Fdev%2Fmy%20project",
    );
  });

  test("clears directory selections and visibility for unchecked machines", () => {
    const selections = clearUncheckedDirectorySelections({
      local: ["/work/a"],
      remote: ["/work/b"],
    }, ["local"]);

    expect(selections).toEqual({ local: ["/work/a"] });
    expect(directoryFiltersVisible(["local"], "local")).toBe(true);
    expect(directoryFiltersVisible(["local"], "remote")).toBe(false);
  });

  test("derives ten-code-point labels with deterministic collision suffixes", () => {
    expect(Object.fromEntries(directoryLabels([{
      machine: "local",
      directories: [
        "/work/abcdefghijk-one",
        "/work/abcdefghijk-two",
        "/work/abcdefghij-2",
        "/",
        "/work/123456789😀extra/",
      ],
    }]).get("local") ?? [])).toEqual({
      "/": "/",
      "/work/123456789😀extra/": "123456789😀",
      "/work/abcdefghij-2": "abcdefghij",
      "/work/abcdefghijk-one": "abcdefghij-2",
      "/work/abcdefghijk-two": "abcdefghij-3",
    });
  });

  test("avoids generated suffix collisions with another directory base label", () => {
    expect(Object.fromEntries(directoryLabels([{
      machine: "local",
      directories: ["/a/foo", "/b/foo", "/c/foo-2"],
    }]).get("local") ?? [])).toEqual({
      "/a/foo": "foo",
      "/b/foo": "foo-2",
      "/c/foo-2": "foo-2-2",
    });
  });

  test("allocates derived collisions across machines in machine-path order", () => {
    const labels = directoryLabels([
      { machine: "remote", directories: ["/srv/shared-project"] },
      { machine: "local", directories: ["/work/shared-project"] },
    ]);

    expect(labels.get("local")?.get("/work/shared-project")).toBe("shared-pro");
    expect(labels.get("remote")?.get("/srv/shared-project")).toBe("shared-pro-2");
  });

  test("uses explicit names before globally allocating every collision class", () => {
    const labels = directoryLabels([
      {
        machine: "local",
        directories: ["/a/derived", "/b/other"],
        names: { "/b/other": "derived" },
      },
      {
        machine: "remote",
        directories: ["/c/third", "/d/fourth"],
        names: { "/c/third": "derived", "/d/fourth": "derived-2" },
      },
    ]);

    expect(labels.get("local")?.get("/a/derived")).toBe("derived");
    expect(labels.get("local")?.get("/b/other")).toBe("derived-2");
    expect(labels.get("remote")?.get("/c/third")).toBe("derived-3");
    expect(labels.get("remote")?.get("/d/fourth")).toBe("derived-2-2");
  });
});
