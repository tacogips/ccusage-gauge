Publish the final review decision from the latest payload. Do not run commands or
modify files. Return JSON with `status`, `findings`, `verificationGaps`,
`residualRisks`, and `reviewSummary`. Set `status` to `accepted` only when the
review accepted the implementation and no required verification gap remains.

```json
{{workflowInput}}
```

```json
{{_rielaInput.latest.payload}}
```
