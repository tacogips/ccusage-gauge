# Multi-machine Docker validation captures

These captures were taken from the live Docker emulation with `machine-a` and
`machine-b` registered as independent SSH machines. The sequence demonstrates
aggregate display, filters, machine lifecycle state, and recovery.

1. Responsive filter layout with all three machine scopes visible:
   ![Responsive all-machine filter](01-all-machines-today.png)
2. Daily aggregate stacked by model:
   ![Daily stack by model](02-daily-stack-by-model.png)
3. Daily aggregate stacked by machine:
   ![Daily stack by machine](03-daily-stack-by-machine.png)
4. Per-host/per-model breakdowns and machine-attributed table rows:
   ![Aggregate breakdown and table](04-all-machines-breakdown-table.png)
5. `machine-a` filter, showing only its model and totals:
   ![machine-a filter](05-filter-machine-a.png)
6. `machine-b` filter, showing only its model and totals:
   ![machine-b filter](06-filter-machine-b.png)
7. Local-only filter, showing the expected empty local scope:
   ![Local-only filter](07-filter-local.png)
8. Model filter for `emulated-model-1`:
   ![Model filter](08-filter-model-1.png)
9. Codex agent filter with both matching models selected:
   ![Agent filter](09-filter-agent-codex.png)
10. Machine configuration with both Docker remotes healthy:
    ![Healthy machine configuration](10-machine-configuration-healthy.png)
11. Partial availability after stopping `machine-b`; cached aggregate data stays
    visible while the stale machine is identified:
    ![machine-b stale](11-degraded-machine-b-stale.png)
12. Recovered aggregate after restarting and refreshing `machine-b`:
    ![machine-b recovered](12-recovered-machine-b.png)
