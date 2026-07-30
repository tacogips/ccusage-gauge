import type {
  DirectoryNameRequest,
  DirectoryNameResponse,
  SubdirectoriesResponse,
} from "./api";
import { DashboardRequestError } from "./api";
import type { DirectorySelections } from "./machineScope";
import { directoryFiltersVisible, directoryQuery, machineQuery } from "./machineScope";
import type { StackBy } from "./usageChartSeries";

export const defaultStackBy: StackBy = "model";

function appendQuery(path: string, suffix: string): string {
  if (suffix.length === 0) return path;
  return `${path}${path.includes("?") ? "&" : "?"}${suffix}`;
}

export function dashboardDataPath(
  path: string,
  activeMachineIDs: string[],
  selections: DirectorySelections,
): string {
  return appendQuery(
    appendQuery(path, machineQuery(activeMachineIDs)),
    directoryQuery(selections, activeMachineIDs),
  );
}

export function costSeriesDataPath(
  path: string,
  activeMachineIDs: string[],
  selections: DirectorySelections,
  stackBy: StackBy,
): string {
  const breakdownPath = appendQuery(
    path,
    stackBy === "subdirectory" ? "directoryBreakdown=true" : "",
  );
  return dashboardDataPath(breakdownPath, activeMachineIDs, selections);
}

export function restoredStackBy(value: unknown): StackBy {
  return value === "model" || value === "machine" || value === "subdirectory"
    ? value
    : defaultStackBy;
}

export function visibleDirectoryChoices(
  activeMachineIDs: string[],
  machine: string,
  directories: readonly string[],
): readonly string[] | undefined {
  return directoryFiltersVisible(activeMachineIDs, machine) && directories.length > 0
    ? directories
    : undefined;
}

export interface DirectoryRenameEditor {
  machine: string;
  directory: string;
  value: string;
  saving: boolean;
  error?: string;
}

export type DirectoryRenameInteraction =
  | { type: "blur" }
  | { type: "cancel" }
  | { type: "keydown"; key: string };

export type DirectoryRenameIntent = "save" | "cancel";
export type DirectoryCatalogRefreshFailureKind = "confirmed-save" | "ambiguous-outcome";

export interface DirectoryRenameWorkflow {
  rename: (request: DirectoryNameRequest) => Promise<DirectoryNameResponse>;
  setEditor: (editor: DirectoryRenameEditor | undefined) => void;
  currentCatalog: () => SubdirectoriesResponse | undefined;
  applyConfirmedCatalog: (catalog: SubdirectoriesResponse | undefined) => void;
  refreshCatalog: () => unknown | Promise<unknown>;
  reportCatalogRefreshFailure?: (
    error: unknown,
    kind: DirectoryCatalogRefreshFailureKind,
  ) => void;
}

export function directoryCatalogRefreshWarning(
  kind: DirectoryCatalogRefreshFailureKind,
): string {
  return kind === "confirmed-save"
    ? "Directory name was saved, but labels could not be refreshed. The dashboard will retry automatically."
    : "Directory rename may have been saved, but its outcome could not be refreshed. Review the current label and retry to confirm.";
}

export function beginDirectoryRename(
  machine: string,
  directory: string,
  explicitName?: string,
): DirectoryRenameEditor {
  return {
    machine,
    directory,
    value: explicitName ?? "",
    saving: false,
  };
}

export function directoryRenameRequestName(value: string): string | null {
  return value.trim().length === 0 ? null : value;
}

export function failedDirectoryRename(
  editor: DirectoryRenameEditor,
  message: string,
): DirectoryRenameEditor {
  return { ...editor, saving: false, error: message };
}

export function directoryRenameIntent(
  interaction: DirectoryRenameInteraction,
): DirectoryRenameIntent | undefined {
  if (interaction.type === "blur") return "save";
  if (interaction.type === "cancel") return "cancel";
  if (interaction.key === "Enter") return "save";
  if (interaction.key === "Escape") return "cancel";
  return undefined;
}

export function applyDirectoryName(
  catalog: SubdirectoriesResponse | undefined,
  response: DirectoryNameResponse,
): SubdirectoriesResponse | undefined {
  if (catalog == null) return catalog;
  return {
    machines: catalog.machines.map((machine) => {
      if (machine.machine !== response.machine) return machine;
      const names = { ...(machine.names ?? {}) };
      if (response.name == null) delete names[response.directory];
      else names[response.directory] = response.name;
      return {
        ...machine,
        names: Object.keys(names).length === 0 ? undefined : names,
      };
    }),
  };
}

export function directoryCatalogWithConfirmedFallback(
  catalog: SubdirectoriesResponse | undefined,
  confirmedCatalog: SubdirectoriesResponse | undefined,
): SubdirectoriesResponse | undefined {
  return catalog ?? confirmedCatalog;
}

export function directoryCatalogConfirmsName(
  catalog: SubdirectoriesResponse | undefined,
  request: DirectoryNameRequest,
): boolean {
  const machine = catalog?.machines.find((item) => item.machine === request.machine);
  if (machine == null || !machine.directories.includes(request.directory)) return false;
  const expectedName = request.name?.trim() || null;
  const actualName = machine.names?.[request.directory] ?? null;
  return actualName === expectedName;
}

function reportDirectoryCatalogRefreshFailure(
  workflow: DirectoryRenameWorkflow,
  error: unknown,
  kind: DirectoryCatalogRefreshFailureKind,
): void {
  try {
    workflow.reportCatalogRefreshFailure?.(error, kind);
  } catch {
    // A reconciliation diagnostic must not change rename outcome handling.
  }
}

async function reconcileAmbiguousDirectoryRename(
  request: DirectoryNameRequest,
  savingEditor: DirectoryRenameEditor,
  workflow: DirectoryRenameWorkflow,
): Promise<void> {
  try {
    await workflow.refreshCatalog();
  } catch (error) {
    reportDirectoryCatalogRefreshFailure(workflow, error, "ambiguous-outcome");
    workflow.setEditor(failedDirectoryRename(
      savingEditor,
      "Directory rename may have been saved, but its outcome could not be refreshed. Retry to confirm.",
    ));
    return;
  }

  const catalog = workflow.currentCatalog();
  if (catalog != null) workflow.applyConfirmedCatalog(catalog);
  if (directoryCatalogConfirmsName(catalog, request)) {
    workflow.setEditor(undefined);
    return;
  }
  workflow.setEditor(failedDirectoryRename(
    savingEditor,
    "Directory rename was not confirmed by the latest catalog. Review the current label and retry.",
  ));
}

export async function submitDirectoryRename(
  editor: DirectoryRenameEditor,
  workflow: DirectoryRenameWorkflow,
): Promise<void> {
  const savingEditor = { ...editor, saving: true, error: undefined };
  const request = {
    machine: editor.machine,
    directory: editor.directory,
    name: directoryRenameRequestName(editor.value),
  };
  workflow.setEditor(savingEditor);
  let response: DirectoryNameResponse;
  try {
    response = await workflow.rename(request);
  } catch (error) {
    if (!(error instanceof DashboardRequestError)) {
      await reconcileAmbiguousDirectoryRename(request, savingEditor, workflow);
      return;
    }
    const message = error instanceof Error ? error.message : "Directory rename failed.";
    workflow.setEditor(failedDirectoryRename(savingEditor, message));
    return;
  }

  const confirmedCatalog = applyDirectoryName(workflow.currentCatalog(), response);
  workflow.applyConfirmedCatalog(confirmedCatalog);
  workflow.setEditor(undefined);
  try {
    await workflow.refreshCatalog();
  } catch (error) {
    reportDirectoryCatalogRefreshFailure(workflow, error, "confirmed-save");
  }
}
