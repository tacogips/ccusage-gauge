import type { CostRow, MetricKey } from "./api";

export function currentViewMetricTotal(rows: readonly CostRow[], metric: MetricKey): number {
  return rows.reduce((sum, row) => sum + row[metric], 0);
}
