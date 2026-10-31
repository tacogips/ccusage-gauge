import { For, Show, createSignal, onCleanup, onMount, type Accessor } from "solid-js";
import type { RateLimitsResponse } from "./api";
import { formatResetDate, formatResetHours, rateLimitStatusLabel, rateLimitWindowFor } from "./rateLimits";

export function RateLimitPanel(props: { response: Accessor<RateLimitsResponse | undefined>; error: boolean }) {
  const [now, setNow] = createSignal(new Date());
  onMount(() => {
    const timer = window.setInterval(() => setNow(new Date()), 30_000);
    onCleanup(() => window.clearInterval(timer));
  });
  return <div class="rate-limit-panel">
    <Show when={!props.error} fallback={<p>Rate limits unavailable. Retrying automatically.</p>}>
      <div class="rate-limit-providers"><For each={([ ["Claude Code", "claudeWeekly", "claude5h"], ["Codex", "codexWeekly", "codex5h"] ] as const)}>{([name, weekly, five]) =>
        <div class="rate-limit-provider"><h3>{name}</h3><For each={([ ["Weekly", weekly], ["5h", five] ] as const)}>{([label, id]) => {
          const data = () => rateLimitWindowFor(id, props.response());
          const resetsAt = () => data().window?.resetsAt;
          return <div class="rate-limit-row">
            <strong>{label}</strong>
            <span class="rate-limit-remaining">{data().window == null ? "Unavailable" : `${data().window!.remainingPercent.toLocaleString(undefined, { maximumFractionDigits: 1 })}% remaining`}</span>
            <div class="rate-limit-reset">
              <time dateTime={resetsAt() ?? undefined}>{formatResetDate(resetsAt())}</time>
              <span>{formatResetHours(resetsAt(), now())}</span>
            </div>
            <Show when={rateLimitStatusLabel(data().provider, now())}><span class="rate-limit-status">{rateLimitStatusLabel(data().provider, now())}</span></Show>
          </div>;
        }}</For></div>
      }</For></div>
    </Show>
    <p class="subscription-refresh-note">This Mac’s accounts · refreshes every minute</p>
  </div>;
}
