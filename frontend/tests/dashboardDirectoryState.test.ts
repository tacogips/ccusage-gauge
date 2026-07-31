import { describe, expect, test } from "bun:test";
import {
  applyDirectoryName,
  beginDirectoryRename,
  costSeriesDataPath,
  dashboardDataPath,
  defaultStackBy,
  directoryCatalogRefreshWarning,
  directoryCatalogWithConfirmedFallback,
  directoryCatalogConfirmsName,
  directoryRenameIntent,
  directoryRenameRequestName,
  failedDirectoryRename,
  restoredStackBy,
  submitDirectoryRename,
  visibleDirectoryChoices,
} from "../src/dashboardDirectoryState";
import { DashboardRequestError, type CostRow, type SubdirectoriesResponse } from "../src/api";
import { clearUncheckedDirectorySelections, directoryLabels } from "../src/machineScope";
import { seriesColor } from "../src/seriesColors";
import { chartSeriesIdentity, chartSeriesLabel } from "../src/usageChartSeries";

describe("dashboard directory integration state", () => {
  const selections = {
    local: ["/work/b", "/work/a"],
    remote: ["/srv/remote"],
  };

  test("applies the active machine's directory filters to every dashboard data route", () => {
    const active = ["local"];
    const suffix = "machine=local&directory=local%3A%2Fwork%2Fa&directory=local%3A%2Fwork%2Fb";

    expect(dashboardDataPath("/api/metrics?range=today", active, selections))
      .toBe(`/api/metrics?range=today&${suffix}`);
    expect(costSeriesDataPath(
      "/api/cost-series?range=today&granularity=hourly",
      active,
      selections,
      "model",
    )).toBe(`/api/cost-series?range=today&granularity=hourly&${suffix}`);
    expect(dashboardDataPath("/api/budget", active, selections))
      .toBe(`/api/budget?${suffix}`);
  });

  test("requests directory breakdown only for subdirectory stacking", () => {
    const base = "/api/cost-series?range=today&granularity=hourly";

    expect(costSeriesDataPath(base, ["local"], {}, defaultStackBy))
      .toBe(`${base}&machine=local`);
    expect(costSeriesDataPath(base, ["local"], {}, "machine"))
      .toBe(`${base}&machine=local`);
    expect(costSeriesDataPath(base, ["local"], {}, "subdirectory"))
      .toBe(`${base}&directoryBreakdown=true&machine=local`);
  });

  test("shows only expanded nonempty inventories and clears unchecked selections", () => {
    expect(visibleDirectoryChoices(true, ["/work/a"]))
      .toEqual(["/work/a"]);
    expect(visibleDirectoryChoices(false, ["/srv/remote"]))
      .toBeUndefined();
    expect(visibleDirectoryChoices(true, []))
      .toBeUndefined();
    expect(clearUncheckedDirectorySelections(selections, ["local"]))
      .toEqual({ local: ["/work/b", "/work/a"] });
  });

  test("defaults missing or unknown saved stack values while retaining supported values", () => {
    expect(defaultStackBy).toBe("model");
    expect(restoredStackBy(undefined)).toBe("model");
    expect(restoredStackBy("future-value")).toBe("model");
    expect(restoredStackBy("machine")).toBe("machine");
    expect(restoredStackBy("subdirectory")).toBe("subdirectory");
  });

  test("starts rename from the explicit value and maps blank input to clear", () => {
    expect(beginDirectoryRename("local", "/work/a", "Billing")).toEqual({
      machine: "local",
      directory: "/work/a",
      value: "Billing",
      saving: false,
    });
    expect(beginDirectoryRename("local", "/work/a").value).toBe("");
    expect(directoryRenameRequestName("  ")).toBeNull();
    expect(directoryRenameRequestName(" Billing ")).toBe(" Billing ");
    expect(failedDirectoryRename({
      machine: "local",
      directory: "/work/a",
      value: "Billing",
      saving: true,
    }, "Save failed")).toEqual({
      machine: "local",
      directory: "/work/a",
      value: "Billing",
      saving: false,
      error: "Save failed",
    });
  });

  test("maps Enter and blur to save while Escape and cancel discard the edit", () => {
    expect(directoryRenameIntent({ type: "keydown", key: "Enter" })).toBe("save");
    expect(directoryRenameIntent({ type: "blur" })).toBe("save");
    expect(directoryRenameIntent({ type: "keydown", key: "Escape" })).toBe("cancel");
    expect(directoryRenameIntent({ type: "cancel" })).toBe("cancel");
    expect(directoryRenameIntent({ type: "keydown", key: "Tab" })).toBeUndefined();
  });

  test("patches confirmed set and clear responses without changing directory identity", () => {
    const catalog = {
      machines: [{
        machine: "local",
        directories: ["/work/a"],
      }],
    };
    const renamed = applyDirectoryName(catalog, {
      status: "ok",
      machine: "local",
      directory: "/work/a",
      name: "Billing",
    });
    const cleared = applyDirectoryName(renamed, {
      status: "ok",
      machine: "local",
      directory: "/work/a",
      name: null,
    });

    expect(renamed?.machines[0]).toEqual({
      machine: "local",
      directories: ["/work/a"],
      names: { "/work/a": "Billing" },
    });
    expect(cleared?.machines[0]).toEqual({
      machine: "local",
      directories: ["/work/a"],
      names: undefined,
    });
  });

  test("confirms normalized set and clear outcomes only for discovered directories", () => {
    const catalog: SubdirectoriesResponse = {
      machines: [{
        machine: "local",
        directories: ["/work/project"],
        names: { "/work/project": "Billing" },
      }],
    };

    expect(directoryCatalogConfirmsName(catalog, {
      machine: "local",
      directory: "/work/project",
      name: " Billing ",
    })).toBe(true);
    expect(directoryCatalogConfirmsName({
      machines: [{ machine: "local", directories: ["/work/project"] }],
    }, {
      machine: "local",
      directory: "/work/project",
      name: null,
    })).toBe(true);
    expect(directoryCatalogConfirmsName(catalog, {
      machine: "local",
      directory: "/work/missing",
      name: null,
    })).toBe(false);
  });

  test("applies a confirmed rename to sidebar and chart before refetching persisted names", async () => {
    let catalog: SubdirectoriesResponse = {
      machines: [
        { machine: "local", directories: ["/work/project"] },
        { machine: "remote", directories: ["/srv/project"] },
      ],
    };
    const persistedCatalog: SubdirectoriesResponse = {
      machines: [
        {
          machine: "local",
          directories: ["/work/project"],
          names: { "/work/project": "Billing" },
        },
        {
          machine: "remote",
          directories: ["/srv/project"],
          names: { "/srv/project": "Remote" },
        },
      ],
    };
    const row: CostRow = {
      timestamp: "2026-07-16T00:00:00Z",
      agent: "codex",
      model: "gpt",
      costUSD: 1,
      inputTokens: 1,
      outputTokens: 2,
      cacheCreationTokens: 0,
      cacheReadTokens: 3,
      totalTokens: 6,
      dataQuality: "timestamped",
      machine: "local",
      directory: "/work/project",
    };
    const identity = chartSeriesIdentity(row, "subdirectory");
    const color = seriesColor("light", "subdirectory", identity);
    const editorTransitions: Array<string | undefined> = [];
    const order: string[] = [];

    await submitDirectoryRename(
      beginDirectoryRename("local", "/work/project", "Billing"),
      {
        rename: async (request) => {
          order.push("rename");
          expect(request).toEqual({
            machine: "local",
            directory: "/work/project",
            name: "Billing",
          });
          catalog = {
            machines: [
              { machine: "local", directories: ["/work/project"] },
              {
                machine: "remote",
                directories: ["/srv/project"],
                names: { "/srv/project": "Remote" },
              },
            ],
          };
          return {
            status: "ok",
            machine: request.machine,
            directory: request.directory,
            name: "Billing",
          };
        },
        setEditor: (editor) => {
          editorTransitions.push(editor == null
            ? undefined
            : `${editor.saving ? "saving" : "editing"}:${editor.value}`);
        },
        currentCatalog: () => catalog,
        applyConfirmedCatalog: (confirmed) => {
          order.push("apply");
          catalog = confirmed ?? { machines: [] };
          const labels = directoryLabels(catalog.machines);
          const sidebarLabel = labels.get("local")?.get("/work/project");
          expect(sidebarLabel).toBe("Billing");
          expect(labels.get("remote")?.get("/srv/project")).toBe("Remote");
          expect(chartSeriesLabel(row, "subdirectory", () => sidebarLabel ?? "Directory"))
            .toBe("Billing");
          expect(chartSeriesIdentity(row, "subdirectory")).toBe(identity);
          expect(seriesColor("light", "subdirectory", identity)).toBe(color);
        },
        refreshCatalog: async () => {
          order.push("refresh");
          catalog = persistedCatalog;
        },
      },
    );

    expect(order).toEqual(["rename", "apply", "refresh"]);
    expect(editorTransitions).toEqual(["saving:Billing", undefined]);
    expect(directoryLabels(catalog.machines).get("local")?.get("/work/project"))
      .toBe("Billing");
  });

  test("retains confirmed labels and recoverable input when rename fails", async () => {
    const catalog: SubdirectoriesResponse = {
      machines: [{
        machine: "local",
        directories: ["/work/project"],
        names: { "/work/project": "Confirmed" },
      }],
    };
    let applied = false;
    let refreshed = false;
    let latestEditor = beginDirectoryRename("local", "/work/project", "Replacement");

    await submitDirectoryRename(latestEditor, {
      rename: async () => {
        throw new DashboardRequestError(503, "Save failed", {});
      },
      setEditor: (editor) => {
        if (editor != null) latestEditor = editor;
      },
      currentCatalog: () => catalog,
      applyConfirmedCatalog: () => {
        applied = true;
      },
      refreshCatalog: async () => {
        refreshed = true;
      },
    });

    expect(latestEditor).toEqual({
      machine: "local",
      directory: "/work/project",
      value: "Replacement",
      saving: false,
      error: "Save failed",
    });
    expect(applied).toBe(false);
    expect(refreshed).toBe(false);
    expect(directoryLabels(catalog.machines).get("local")?.get("/work/project"))
      .toBe("Confirmed");
  });

  test("reconciles a committed rename after its response is lost", async () => {
    let catalog: SubdirectoriesResponse = {
      machines: [{
        machine: "local",
        directories: ["/work/project"],
        names: { "/work/project": "Original" },
      }],
    };
    let confirmedCatalog: SubdirectoriesResponse | undefined;
    let latestEditor: ReturnType<typeof beginDirectoryRename> | undefined =
      beginDirectoryRename("local", "/work/project", "Replacement");

    await submitDirectoryRename(latestEditor, {
      rename: async () => {
        catalog = {
          machines: [{
            machine: "local",
            directories: ["/work/project"],
            names: { "/work/project": "Replacement" },
          }],
        };
        throw new TypeError("Response connection closed");
      },
      setEditor: (editor) => {
        latestEditor = editor;
      },
      currentCatalog: () => catalog,
      applyConfirmedCatalog: (confirmed) => {
        confirmedCatalog = confirmed;
      },
      refreshCatalog: async () => catalog,
    });

    expect(latestEditor).toBeUndefined();
    expect(confirmedCatalog).toEqual(catalog);
    expect(directoryLabels(confirmedCatalog?.machines ?? []).get("local")?.get("/work/project"))
      .toBe("Replacement");
  });

  test("keeps ambiguous input recoverable when reconciliation cannot confirm it", async () => {
    const catalog: SubdirectoriesResponse = {
      machines: [{
        machine: "local",
        directories: ["/work/project"],
        names: { "/work/project": "Original" },
      }],
    };
    let latestEditor = beginDirectoryRename("local", "/work/project", "Replacement");

    await submitDirectoryRename(latestEditor, {
      rename: async () => {
        throw new TypeError("Response connection closed");
      },
      setEditor: (editor) => {
        if (editor != null) latestEditor = editor;
      },
      currentCatalog: () => catalog,
      applyConfirmedCatalog: () => {},
      refreshCatalog: async () => catalog,
    });

    expect(latestEditor.saving).toBe(false);
    expect(latestEditor.value).toBe("Replacement");
    expect(latestEditor.error).toContain("not confirmed");
  });

  test("does not claim success when an ambiguous rename cannot be refreshed", async () => {
    const catalog: SubdirectoriesResponse = {
      machines: [{
        machine: "local",
        directories: ["/work/project"],
        names: { "/work/project": "Original" },
      }],
    };
    let latestEditor = beginDirectoryRename("local", "/work/project", "Replacement");
    let refreshFailure: unknown;
    let refreshWarning: string | undefined;

    await submitDirectoryRename(latestEditor, {
      rename: async () => {
        throw new TypeError("Response connection closed");
      },
      setEditor: (editor) => {
        if (editor != null) latestEditor = editor;
      },
      currentCatalog: () => catalog,
      applyConfirmedCatalog: () => {},
      refreshCatalog: async () => {
        throw new Error("catalog unavailable");
      },
      reportCatalogRefreshFailure: (error, kind) => {
        refreshFailure = error;
        refreshWarning = directoryCatalogRefreshWarning(kind);
      },
    });

    expect((refreshFailure as Error).message).toBe("catalog unavailable");
    expect(refreshWarning).toBe(
      "Directory rename may have been saved, but its outcome could not be refreshed. Review the current label and retry to confirm.",
    );
    expect(refreshWarning?.startsWith("Directory name was saved")).toBe(false);
    expect(latestEditor.saving).toBe(false);
    expect(latestEditor.value).toBe("Replacement");
    expect(latestEditor.error).toContain("may have been saved");
  });

  test("preserves confirmed labels and reports reconciliation when post-save refetch fails", async () => {
    const initialCatalog: SubdirectoriesResponse = {
      machines: [{
        machine: "local",
        directories: ["/work/project"],
        names: { "/work/project": "Original" },
      }],
    };
    let confirmedCatalog: SubdirectoriesResponse | undefined = initialCatalog;
    let editorClosed = false;
    let refreshFailure: unknown;
    let refreshWarning: string | undefined;

    await submitDirectoryRename(
      beginDirectoryRename("local", "/work/project", "Replacement"),
      {
        rename: async (request) => ({
          status: "ok",
          ...request,
          name: "Replacement",
        }),
        setEditor: (editor) => {
          if (editor == null) editorClosed = true;
        },
        currentCatalog: () => initialCatalog,
        applyConfirmedCatalog: (catalog) => {
          confirmedCatalog = catalog;
        },
        refreshCatalog: async () => {
          throw new Error("catalog unavailable");
        },
        reportCatalogRefreshFailure: (error, kind) => {
          refreshFailure = error;
          refreshWarning = directoryCatalogRefreshWarning(kind);
        },
      },
    );

    const visibleCatalog = directoryCatalogWithConfirmedFallback(undefined, confirmedCatalog);
    expect(editorClosed).toBe(true);
    expect((refreshFailure as Error).message).toBe("catalog unavailable");
    expect(refreshWarning).toBe(
      "Directory name was saved, but labels could not be refreshed. The dashboard will retry automatically.",
    );
    expect(directoryLabels(visibleCatalog?.machines ?? []).get("local")?.get("/work/project"))
      .toBe("Replacement");
  });
});
