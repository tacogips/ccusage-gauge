import { For, Show, createSignal, onCleanup, onMount, type Accessor } from "solid-js";
import type { PieChartID, RateLimitsResponse } from "./api";
import { formatCredits, formatResetCompact, isCreditChart, rateLimitCreditsFor, rateLimitStatusLabel, rateLimitWindowFor } from "./rateLimits";

export function RateLimitPanel(props: {
  response: Accessor<RateLimitsResponse | undefined>; error: boolean; selection: Accessor<PieChartID[]>;
}) {
  const [now, setNow] = createSignal(new Date());
  onMount(() => {
    const timer = window.setInterval(() => setNow(new Date()), 30_000);
    onCleanup(() => window.clearInterval(timer));
  });
  const selected = (weekly: PieChartID, five: PieChartID, credit: PieChartID) =>
    ([ ["Weekly", weekly], ["5h", five], ["Credit", credit] ] as const).filter(([, id]) => props.selection().includes(id));
  const usage = (id: PieChartID) => {
    if (isCreditChart(id)) {
      const credits = rateLimitCreditsFor(id, props.response()).credits;
      return credits == null ? "unavailable" : formatCredits(credits);
    }
    const window = rateLimitWindowFor(id, props.response()).window;
    return window == null ? "unavailable" : `${window.usedPercent.toLocaleString(undefined, { maximumFractionDigits: 1 })}% used`;
  };
  return <Show when={props.selection().some((id) => id !== "budget")}>
    <div class="rate-limit-panel">
      <Show when={!props.error} fallback={<p>Rate limits unavailable. Retrying automatically.</p>}>
        <For each={([ ["Claude Code", "claudeWeekly", "claude5h", "claudeCredit"], ["Codex", "codexWeekly", "codex5h", "codexCredit"] ] as const)}>{([name, weekly, five, credit]) =>
          <Show when={selected(weekly, five, credit).length > 0}>
            <div class="rate-limit-provider-line">
              <strong class="rate-limit-provider-name">{name}</strong>
              <div class="rate-limit-windows"><For each={selected(weekly, five, credit)}>{([label, id]) => {
                const data = () => rateLimitWindowFor(id, props.response());
                return <span class="rate-limit-window">
                  <span>{label} {usage(id)}</span>
                  <Show when={data().window?.resetsAt}><span class="rate-limit-reset">{formatResetCompact(data().window?.resetsAt, now())}</span></Show>
                  <Show when={rateLimitStatusLabel(data().provider, now())}><span class="rate-limit-status">{rateLimitStatusLabel(data().provider, now())}</span></Show>
                </span>;
              }}</For></div>
            </div>
          </Show>
        }</For>
      </Show>
    </div>
  </Show>;
}
