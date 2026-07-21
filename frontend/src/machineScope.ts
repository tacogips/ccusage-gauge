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
