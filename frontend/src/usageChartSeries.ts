import type { CostRow } from "./api";

export type StackBy = "model" | "machine" | "subdirectory";

export function chartSeriesIdentity(row: CostRow, stackBy: StackBy): string {
  if (stackBy === "machine") return row.machine;
  if (stackBy === "model") return row.model;
  return `${row.machine}\u001f${row.directory ?? ""}`;
}

export function chartSeriesLabel(
  row: CostRow,
  stackBy: StackBy,
  subdirectoryLabel: (row: CostRow) => string,
): string {
  return stackBy === "subdirectory" ? subdirectoryLabel(row) : chartSeriesIdentity(row, stackBy);
}

export function directorySeriesDisplayLabel(
  row: CostRow,
  derivedLabel: string | undefined,
  machineDisplayName: string | undefined,
  qualifyMachine: boolean,
): string {
  if (row.directory != null) return derivedLabel ?? "Directory";
  const label = "No directory";
  return qualifyMachine ? `${machineDisplayName ?? row.machine}: ${label}` : label;
}
