Publish the accepted result from the latest final review. Do not run commands or
modify files.

```json
{{workflowInput}}
```

```json
{{_rielaInput.latest.payload}}
```

Return JSON with `status`, `workflowId`, `resolvedFindings`, `changedFiles`,
`verification`, `verificationGaps`, `cleanup`, `residualRisks`, and
`operatorNotes`. Set `status` to `accepted` only when no high/medium finding or
required verification gap remains.
