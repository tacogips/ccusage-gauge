import type { LoadStatusResponse, Machine, MachineSubdirectories } from "./api";

export const initialMachineLimit = 5;
export const initialDirectoryLimit = 10;

export function visibleMachineItems<Item>(items: Item[], expanded: boolean): Item[] {
  return expanded ? items : items.slice(0, initialMachineLimit);
}

export function orderedDirectoryItems(
  directories: readonly string[],
  selectedDirectories: readonly string[],
  labels: ReadonlyMap<string, string> = new Map(),
): string[] {
  const selected = new Set(selectedDirectories);
  return [...new Set(directories)].sort((left, right) => {
    const selectionOrder = Number(selected.has(right)) - Number(selected.has(left));
    if (selectionOrder !== 0) return selectionOrder;
    const nameOrder = (labels.get(left) ?? left).localeCompare(labels.get(right) ?? right);
    return nameOrder !== 0 ? nameOrder : left.localeCompare(right);
  });
}

export function allDirectoryItemsSelected(
  directories: readonly string[],
  selectedDirectories: readonly string[],
): boolean {
  const items = [...new Set(directories)];
  const selected = new Set(selectedDirectories);
  return items.length > 0 && items.every((directory) => selected.has(directory));
}

export function directoryItemSelected(
  selectedDirectories: readonly string[],
  directory: string,
  wholeMachineIsSelected: boolean,
): boolean {
  return wholeMachineIsSelected || selectedDirectories.includes(directory);
}

export function toggledDirectoryItems(
  directories: readonly string[],
  selectedDirectories: readonly string[],
  directory: string,
  wholeMachineIsSelected: boolean,
): string[] {
  const selected = new Set(wholeMachineIsSelected ? directories : selectedDirectories);
  if (selected.has(directory)) {
    selected.delete(directory);
  } else {
    selected.add(directory);
  }
  return [...new Set(directories)].filter((item) => selected.has(item));
}

export function visibleDirectoryItems(
  directories: readonly string[],
  selectedDirectories: readonly string[],
  expanded: boolean,
  labels: ReadonlyMap<string, string> = new Map(),
): string[] {
  const ordered = orderedDirectoryItems(directories, selectedDirectories, labels);
  return expanded ? ordered : ordered.slice(0, initialDirectoryLimit);
}

export function matchesMachineSelection(selectedMachines: string[], machine: string): boolean {
  return selectedMachines.length === 0 || selectedMachines.includes(machine);
}

export function toggledMachineSelection(selectedMachines: string[], machine: string): string[] {
  return selectedMachines.includes(machine)
    ? selectedMachines.filter((item) => item !== machine)
    : [...selectedMachines, machine];
}

export function requestedMachineIDs(machines: Machine[], selectedMachines: string[]): string[] {
  const enabled = machines.filter((machine) => machine.enabled);
  if (selectedMachines.length === 0) return enabled.map((machine) => machine.id);
  const enabledIDs = new Set(enabled.map((machine) => machine.id));
  const selected = selectedMachines.filter((id) => enabledIDs.has(id));
  if (selected.length > 0) return selected;
  const local = enabled.find((machine) => machine.id === "local");
  return local == null ? enabled.slice(0, 1).map((machine) => machine.id) : [local.id];
}

export function machineQuery(ids: string[]): string {
  return ids.map((id) => `machine=${encodeURIComponent(id)}`).join("&");
}

export type DirectorySelections = Readonly<Record<string, readonly string[]>>;

export function wholeMachineSelected(
  activeMachineIDs: readonly string[],
  selections: DirectorySelections,
  machine: string,
): boolean {
  return activeMachineIDs.includes(machine) && (selections[machine]?.length ?? 0) === 0;
}

export function directoryQuery(selections: DirectorySelections, activeMachineIDs: string[]): string {
  const active = new Set(activeMachineIDs);
  return Object.entries(selections)
    .filter(([machine]) => active.has(machine))
    .sort(([left], [right]) => left.localeCompare(right))
    .flatMap(([machine, directories]) => [...new Set(directories)].sort()
      .map((directory) => `directory=${encodeURIComponent(`${machine}:${directory}`)}`))
    .join("&");
}

export function clearUncheckedDirectorySelections(
  selections: DirectorySelections,
  checkedMachineIDs: string[],
): Record<string, string[]> {
  const checked = new Set(checkedMachineIDs);
  return Object.fromEntries(Object.entries(selections)
    .filter(([machine, directories]) => checked.has(machine) && directories.length > 0)
    .map(([machine, directories]) => [machine, [...directories]]));
}

export function directoryFiltersVisible(checkedMachineIDs: string[], machine: string): boolean {
  return checkedMachineIDs.includes(machine);
}

function directoryBaseLabel(directory: string): string {
  const withoutTrailingSeparators = directory.replace(/\/+$/u, "");
  const component = withoutTrailingSeparators.split("/").filter(Boolean).at(-1)
    ?? (directory.startsWith("/") ? "/" : directory);
  return [...component].slice(0, 10).join("");
}

export function directoryLabels(
  catalog: readonly MachineSubdirectories[],
): Map<string, Map<string, string>> {
  const labels = new Map<string, Map<string, string>>();
  const allocated = new Set<string>();
  const entries = catalog
    .flatMap((machine) => [...new Set(machine.directories)].map((directory) => ({
      machine: machine.machine,
      directory,
      explicitName: machine.names?.[directory],
    })))
    .sort((left, right) => {
      if (left.machine !== right.machine) return left.machine < right.machine ? -1 : 1;
      if (left.directory === right.directory) return 0;
      return left.directory < right.directory ? -1 : 1;
    });
  for (const entry of entries) {
    const base = typeof entry.explicitName === "string" && entry.explicitName.length > 0
      ? entry.explicitName
      : directoryBaseLabel(entry.directory);
    let label = base;
    for (let sequence = 2; allocated.has(label); sequence += 1) {
      label = `${base}-${sequence}`;
    }
    allocated.add(label);
    const machineLabels = labels.get(entry.machine) ?? new Map<string, string>();
    machineLabels.set(entry.directory, label);
    labels.set(entry.machine, machineLabels);
  }
  return labels;
}

export function machineProgressDetail(status?: LoadStatusResponse): string {
  if (status == null || status.machines.length === 0) return "";
  return status.machines
    .map((machine) => `${machine.id} ${machine.completed}/${Math.max(machine.total, 1)}`)
    .join(" · ");
}
