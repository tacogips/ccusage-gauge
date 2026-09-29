import type { CostRow } from "./api";
import { effortLabel, effortRank } from "./effort";

export type StackBy = "model" | "machine" | "subdirectory" | "modelEffort";

export function chartSeriesIdentity(row: CostRow, stackBy: StackBy): string {
  if (stackBy === "machine") return row.machine;
  if (stackBy === "model") return row.model;
  if (stackBy === "modelEffort") return `${row.model}\u001f${row.effort ?? ""}`;
  return `${row.machine}\u001f${row.directory ?? ""}`;
}

export function modelEffortParts(identity: string): { model: string; effort?: string } {
  const separator = identity.lastIndexOf("\u001f");
  if (separator < 0) return { model: identity };
  const model = identity.slice(0, separator);
  const effort = identity.slice(separator + 1);
  return effort.length === 0 ? { model } : { model, effort };
}

export function compareSeriesIdentities(stackBy: StackBy, a: string, b: string): number {
  if (stackBy !== "modelEffort") return a.localeCompare(b);
  const left = modelEffortParts(a);
  const right = modelEffortParts(b);
  const modelOrder = left.model.localeCompare(right.model);
  if (modelOrder !== 0) return modelOrder;
  const effortOrder = effortRank(left.effort) - effortRank(right.effort);
  if (effortOrder !== 0) return effortOrder;
  return (left.effort ?? "").localeCompare(right.effort ?? "");
}

export function chartSeriesLabel(
  row: CostRow,
  stackBy: StackBy,
  subdirectoryLabel: (row: CostRow) => string,
): string {
  if (stackBy === "modelEffort") {
    const { model, effort } = modelEffortParts(chartSeriesIdentity(row, stackBy));
    return `${model} (${effortLabel(effort)})`;
  }
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
