import { For, Show, type Accessor } from "solid-js";
// @ts-expect-error TS5097: explicit .ts disambiguates the case-only rangeControls.ts and RangeControls.tsx modules.
import { quickRanges, rangeButtonPressed, type QuickRange, type Range } from "./rangeControls.ts";

export function RangeControls(props: {
  range: Accessor<Range>;
  select: (range: QuickRange) => void;
  isCustomEditorOpen: Accessor<boolean>;
  setIsCustomEditorOpen: (open: boolean) => void;
  customStart: Accessor<string>;
  customEnd: Accessor<string>;
  updateCustomStart: (value: string) => void;
  updateCustomEnd: (value: string) => void;
  applyCustomRange: () => void;
}) {
  return (
    <>
      <div class="range-buttons toggle-group">
        <For each={quickRanges}>{([value, label]) => (
          <button
            type="button"
            aria-pressed={rangeButtonPressed(props.range(), value) ? "true" : "false"}
            onClick={() => props.select(value)}
          >{label}</button>
        )}</For>
        <button
          type="button"
          aria-pressed={rangeButtonPressed(props.range(), "custom") ? "true" : "false"}
          aria-expanded={props.isCustomEditorOpen() ? "true" : "false"}
          onClick={() => props.setIsCustomEditorOpen(true)}
        >Custom</button>
      </div>
      <Show when={props.isCustomEditorOpen()}>
        <div class="custom-calendar" role="group" aria-label="Custom date range">
          <label>From<input aria-label="Custom range start" type="date" value={props.customStart()} max={props.customEnd()} onInput={(event) => props.updateCustomStart(event.currentTarget.value)} /></label>
          <span>to</span>
          <label>To<input aria-label="Custom range end" type="date" value={props.customEnd()} min={props.customStart()} onInput={(event) => props.updateCustomEnd(event.currentTarget.value)} /></label>
          <button
            type="button"
            class="apply-custom-range"
            disabled={!props.customStart() || !props.customEnd() || props.customStart() > props.customEnd()}
            onClick={props.applyCustomRange}
          >Apply</button>
        </div>
      </Show>
    </>
  );
}
