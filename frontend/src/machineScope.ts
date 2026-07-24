import type { LoadStatusResponse, Machine } from "./api";

export const initialMachineLimit = 5;

export function visibleMachineItems<Item>(items: Item[], expanded: boolean): Item[] {
  return expanded ? items : items.slice(0, initialMachineLimit);
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

export function machineProgressDetail(status?: LoadStatusResponse): string {
  if (status == null || status.machines.length === 0) return "";
  return status.machines
    .map((machine) => `${machine.id} ${machine.completed}/${Math.max(machine.total, 1)}`)
    .join(" · ");
}
