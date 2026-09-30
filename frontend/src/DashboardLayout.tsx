import type { JSX } from "solid-js";
import type { ColorScheme } from "./colorScheme";

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

export function ThemeToggle(props: { scheme: ColorScheme; onToggle: () => void }) {
  const label = () => props.scheme === "dark" ? "Switch to light theme" : "Switch to dark theme";
  return (
    <button type="button" class="theme-toggle" aria-label={label()} title={label()} onClick={props.onToggle}>
      {props.scheme === "dark"
        ? <svg viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="8" height="8" /><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1" /></svg>
        : <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 14.2A8.5 8.5 0 1 1 9.8 4a7 7 0 0 0 10.2 10.2Z" /></svg>}
    </button>
  );
}
