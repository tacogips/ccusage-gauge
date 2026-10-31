import { createSignal, type JSX } from "solid-js";
import { FoldIcon } from "./DashboardLayout";
import { readCollapsedSections, storeSectionCollapsed } from "./sectionCollapseState";

export function CollapsibleSection(props: {
  id: string; title: JSX.Element; label: string; eyebrow?: string; class?: string;
  summary?: JSX.Element; actions?: JSX.Element; children: JSX.Element;
}) {
  const [collapsed, setCollapsed] = createSignal(readCollapsedSections().includes(props.id));
  const toggle = () => {
    const next = !collapsed();
    setCollapsed(next);
    storeSectionCollapsed(props.id, next);
  };
  return <section class={`collapsible-section ${props.class ?? ""}`} classList={{ "section-collapsed": collapsed() }}>
    <div class="section-heading">
      <div class="section-heading-copy">
        {props.eyebrow && <p class="eyebrow">{props.eyebrow}</p>}
        <div class="section-heading-title"><h2>{props.title}</h2>{props.summary}</div>
      </div>
      <div class="section-heading-actions">
      <div class="section-actions" hidden={collapsed()}>{props.actions}</div>
      <button type="button" class="fold-toggle" aria-expanded={!collapsed()} aria-controls={`${props.id}-content`}
        aria-label={`${collapsed() ? "Expand" : "Collapse"} ${props.label}`}
        title={`${collapsed() ? "Expand" : "Collapse"} ${props.label}`} onClick={toggle}>
        <FoldIcon collapsed={collapsed()} />
      </button>
      </div>
    </div>
    <div id={`${props.id}-content`} class="section-content" hidden={collapsed()}>{props.children}</div>
  </section>;
}
