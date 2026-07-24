import { For, Show } from "solid-js";
import type { Machine, MachineStatus } from "./api";
import type { MachineActionDiagnostic } from "./machineActions";
import type { MachineDraft, MachineProxyKind } from "./machineForm";

export function machineControlsDisabled(inFlight: Record<string, boolean>, machineID: string) {
  return inFlight[machineID] === true;
}

export function MachineAdminPanel(props: {
  machines: Machine[];
  statuses: MachineStatus[];
  actions: Record<string, MachineActionDiagnostic>;
  inFlight: Record<string, boolean>;
  formOpen: boolean;
  editingID?: string;
  draft: MachineDraft;
  error?: string;
  onTest: (machine: Machine) => void;
  onRefresh: (machine: Machine) => void;
  onEdit: (machine: Machine) => void;
  onToggle: (machine: Machine) => void;
  onRemove: (machine: Machine) => void;
  onToggleForm: () => void;
  onDraft: (draft: MachineDraft) => void;
  onProxyKind: (kind: MachineProxyKind) => void;
  onSave: () => void;
}) {
  const update = <K extends keyof MachineDraft>(key: K, value: MachineDraft[K]) =>
    props.onDraft({ ...props.draft, [key]: value });
  return <>
    <strong>Machines</strong>
    <div class="machine-admin-list">
      <For each={props.machines.filter((machine) => machine.kind === "ssh")} fallback={<small>No SSH machines registered.</small>}>{(machine) => {
        const status = () => props.statuses.find((item) => item.id === machine.id);
        return <div class="machine-admin-item">
          <div class="machine-admin-row">
            <div><b>{machine.displayName}</b><small>{machine.id} · {status()?.collectionState ?? "unknown"}</small></div>
            <button class="secondary" disabled={machineControlsDisabled(props.inFlight, machine.id)} onClick={() => props.onTest(machine)}>Test connection</button>
            <button class="secondary" disabled={machineControlsDisabled(props.inFlight, machine.id)} onClick={() => props.onRefresh(machine)}>Refresh now</button>
            <button class="secondary" disabled={machineControlsDisabled(props.inFlight, machine.id)} onClick={() => props.onEdit(machine)}>Edit</button>
            <button class="secondary" disabled={machineControlsDisabled(props.inFlight, machine.id)} onClick={() => props.onToggle(machine)}>{machine.enabled ? "Disable" : "Enable"}</button>
            <button class="danger" disabled={machineControlsDisabled(props.inFlight, machine.id)} onClick={() => props.onRemove(machine)}>Remove</button>
          </div>
          <Show when={props.actions[machine.id]}>{(result) => (
            <small classList={{ "machine-action-result": true, failed: result().failed }} role="status">{result().message}</small>
          )}</Show>
        </div>;
      }}</For>
    </div>
    <button class="secondary" onClick={props.onToggleForm}>{props.formOpen ? "Cancel" : "Add SSH machine"}</button>
    <Show when={props.formOpen}><div class="machine-form">
      <input aria-label="Machine id" placeholder="machine-id" value={props.draft.id} disabled={props.editingID != null} onInput={(event) => update("id", event.currentTarget.value)} />
      <input aria-label="Display name" placeholder="Display name" value={props.draft.displayName} onInput={(event) => update("displayName", event.currentTarget.value)} />
      <label class="machine-field"><input aria-label="Machine enabled" type="checkbox" checked={props.draft.enabled} onChange={(event) => update("enabled", event.currentTarget.checked)} /> Enabled</label>
      <input aria-label="SSH host" placeholder="Host" value={props.draft.host} onInput={(event) => update("host", event.currentTarget.value)} />
      <input aria-label="SSH port" type="number" min="1" max="65535" value={props.draft.port} onInput={(event) => update("port", event.currentTarget.value)} />
      <input aria-label="SSH user" placeholder="User" value={props.draft.user} onInput={(event) => update("user", event.currentTarget.value)} />
      <input aria-label="Identity file" placeholder="/absolute/path/to/key (optional)" value={props.draft.identityFile} onInput={(event) => update("identityFile", event.currentTarget.value)} />
      <textarea aria-label="Allowlisted SSH options" placeholder="-o ConnectTimeout=10 (one per line)" value={props.draft.extraOptions.join("\n")} onInput={(event) => update("extraOptions", event.currentTarget.value.split("\n").map((value) => value.trim()).filter(Boolean))} />
      <input aria-label="Remote ccusage executable" placeholder="ccusage" value={props.draft.remoteCcusagePath} onInput={(event) => update("remoteCcusagePath", event.currentTarget.value)} />
      <label class="machine-field">Connection route
        <select aria-label="Connection route" value={props.draft.proxyKind} onChange={(event) => props.onProxyKind(event.currentTarget.value as MachineProxyKind)}>
          <option value="direct">Direct SSH</option>
          <option value="jump">SSH jump host</option>
          <option value="command">Proxy command helper</option>
        </select>
      </label>
      <Show when={props.draft.proxyKind === "jump"}>
        <input aria-label="Jump host" placeholder="Jump host" value={props.draft.proxyHost} onInput={(event) => update("proxyHost", event.currentTarget.value)} />
        <input aria-label="Jump port" type="number" min="1" max="65535" value={props.draft.proxyPort} onInput={(event) => update("proxyPort", event.currentTarget.value)} />
        <input aria-label="Jump user" placeholder="Jump user" value={props.draft.proxyUser} onInput={(event) => update("proxyUser", event.currentTarget.value)} />
        <input aria-label="Jump identity file" placeholder="/absolute/path/to/jump-key (optional)" value={props.draft.proxyIdentityFile} onInput={(event) => update("proxyIdentityFile", event.currentTarget.value)} />
        <input aria-label="Jump known hosts file" placeholder="/absolute/path/to/known_hosts (optional)" value={props.draft.proxyKnownHostsFile} onInput={(event) => update("proxyKnownHostsFile", event.currentTarget.value)} />
      </Show>
      <Show when={props.draft.proxyKind === "command"}>
        <input aria-label="Proxy command executable" placeholder="/absolute/path/to/proxy-helper" value={props.draft.proxyExecutable} onInput={(event) => update("proxyExecutable", event.currentTarget.value)} />
      </Show>
      <button onClick={props.onSave}>{props.editingID == null ? "Register machine" : "Save machine"}</button>
      <Show when={props.error}>{(message) => <small class="machine-warning" role="alert">{message()}</small>}</Show>
    </div></Show>
  </>;
}
