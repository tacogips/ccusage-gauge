import type { JSX } from "solid-js";

export function PaneFoldBar(props: {
  collapsed: boolean;
  onToggle: () => void;
  summary: string;
}) {
  return (
    <div class="pane-fold-bar">
      <button
        type="button"
        class="fold-toggle"
        aria-expanded={!props.collapsed ? "true" : "false"}
        aria-controls="usage-filters-content"
        aria-label={props.collapsed ? "Expand filters" : "Collapse filters"}
        onClick={props.onToggle}
      >
        <span class="fold-icon" aria-hidden="true">{props.collapsed ? "\u00bb" : "\u00ab"}</span>
        <span class="fold-label">{props.collapsed ? "Expand" : "Collapse"}</span>
      </button>
      <span class="pane-fold-summary">{props.summary}</span>
    </div>
  );
}

export function HeaderFoldBar(props: {
  title: JSX.Element;
  rangeLabel: string;
  collapsed: boolean;
  onToggle: () => void;
}) {
  return (
    <div class="header-fold-bar">
      {props.title}
      <span class="header-range-summary">{props.rangeLabel}</span>
      <button
        type="button"
        class="fold-toggle header-fold-toggle"
        aria-expanded={!props.collapsed ? "true" : "false"}
        aria-controls="dashboard-header-content"
        aria-label={props.collapsed ? "Expand header" : "Collapse header"}
        onClick={props.onToggle}
      >{props.collapsed ? "Expand" : "Collapse"}</button>
    </div>
  );
}
