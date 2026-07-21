Publish the accepted result from the latest direct final Codex review input.
Do not run commands or modify files.

Original workflow input:

```json
{{workflowInput}}
```

Accepted review payload:

```json
{{_rielaInput.latest.payload}}
```

Return JSON with `status`, `workflowId`, `resolvedFindings`, `changedFiles`,
`verification`, `verificationGaps`, `residualRisks`, and `operatorNotes`.
Set `status` to `accepted` only when the latest payload is accepted with no high
or medium findings and no missing required verification.
