import { For, Show, type Accessor } from "solid-js";
import type { RateLimitsResponse } from "./api";
import { formatResetIn, rateLimitStatusLabel, rateLimitWindowFor } from "./rateLimits";

export function RateLimitPanel(props: { response: Accessor<RateLimitsResponse | undefined>; error: boolean; now: Accessor<Date> }) {
  return <section class="panel rate-limit-panel">
    <div class="panel-title"><div><p class="eyebrow">THIS MAC'S ACCOUNT</p><h2>Subscription rate limits</h2></div></div>
    <Show when={!props.error} fallback={<p>Rate limits unavailable</p>}>
      <div class="rate-limit-providers"><For each={([ ["Claude Code", "claude5h", "claudeWeekly"], ["Codex", "codex5h", "codexWeekly"] ] as const)}>{([name, five, weekly]) =>
        <div><h3>{name}</h3><For each={([ ["5h", five], ["Weekly", weekly] ] as const)}>{([label, id]) => {
          const data = () => rateLimitWindowFor(id, props.response());
          return <div class="rate-limit-row"><strong>{label}</strong><span>{data().window == null ? "Unavailable" : `${data().window!.remainingPercent.toLocaleString(undefined, { maximumFractionDigits: 1 })}% remaining`}</span><span>{formatResetIn(data().window?.resetsAt, props.now())}</span><span>{rateLimitStatusLabel(data().provider, props.now())}</span></div>;
        }}</For></div>
      }</For></div>
    </Show>
  </section>;
}
