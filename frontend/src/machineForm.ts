import type { Machine, SSHProxy } from "./api";

export type MachineProxyKind = "direct" | "jump" | "command";

export interface MachineDraft {
  id: string;
  displayName: string;
  enabled: boolean;
  host: string;
  port: string;
  user: string;
  identityFile: string;
  extraOptions: string[];
  remoteCcusagePath: string;
  proxyKind: MachineProxyKind;
  proxyHost: string;
  proxyPort: string;
  proxyUser: string;
  proxyIdentityFile: string;
  proxyKnownHostsFile: string;
  proxyExecutable: string;
}

export function emptyMachineDraft(): MachineDraft {
  return {
    id: "",
    displayName: "",
    enabled: true,
    host: "127.0.0.1",
    port: "22",
    user: "",
    identityFile: "",
    extraOptions: [],
    remoteCcusagePath: "ccusage",
    proxyKind: "direct",
    proxyHost: "",
    proxyPort: "22",
    proxyUser: "",
    proxyIdentityFile: "",
    proxyKnownHostsFile: "",
    proxyExecutable: "",
  };
}

export function draftFromMachine(machine: Machine): MachineDraft {
  if (machine.kind !== "ssh" || machine.ssh == null) throw new Error("Only SSH machines can be edited");
  const draft = emptyMachineDraft();
  const proxy = machine.ssh.proxy;
  return {
    ...draft,
    id: machine.id,
    displayName: machine.displayName,
    enabled: machine.enabled,
    host: machine.ssh.host,
    port: String(machine.ssh.port),
    user: machine.ssh.user,
    identityFile: machine.ssh.identityFile ?? "",
    extraOptions: [...machine.ssh.extraOptions],
    remoteCcusagePath: machine.ssh.remoteCcusagePath,
    proxyKind: proxy?.kind ?? "direct",
    proxyHost: proxy?.kind === "jump" ? proxy.host : "",
    proxyPort: proxy?.kind === "jump" ? String(proxy.port) : "22",
    proxyUser: proxy?.kind === "jump" ? proxy.user : "",
    proxyIdentityFile: proxy?.kind === "jump" ? proxy.identityFile ?? "" : "",
    proxyKnownHostsFile: proxy?.kind === "jump" ? proxy.knownHostsFile ?? "" : "",
    proxyExecutable: proxy?.kind === "command" ? proxy.executable : "",
  };
}

export function changingProxyKind(draft: MachineDraft, proxyKind: MachineProxyKind): MachineDraft {
  return {
    ...draft,
    proxyKind,
    proxyHost: proxyKind === "jump" ? draft.proxyHost : "",
    proxyPort: proxyKind === "jump" ? draft.proxyPort : "22",
    proxyUser: proxyKind === "jump" ? draft.proxyUser : "",
    proxyIdentityFile: proxyKind === "jump" ? draft.proxyIdentityFile : "",
    proxyKnownHostsFile: proxyKind === "jump" ? draft.proxyKnownHostsFile : "",
    proxyExecutable: proxyKind === "command" ? draft.proxyExecutable : "",
  };
}

export function machineDraftErrors(draft: MachineDraft): Record<string, string> {
  const errors: Record<string, string> = {};
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(draft.id) || ["local", "all"].includes(draft.id)) {
    errors.id = "Use a canonical lowercase machine id.";
  }
  if (draft.displayName.trim().length === 0) errors.displayName = "Display name is required.";
  if (draft.host.trim().length === 0) errors.host = "Host is required.";
  if (!validPort(draft.port)) errors.port = "Port must be in 1...65535.";
  if (draft.user.trim().length === 0) errors.user = "User is required.";
  if (draft.remoteCcusagePath.trim().length === 0) errors.remoteCcusagePath = "Remote executable is required.";
  if (draft.extraOptions.some((option) => !isAllowlistedOption(option))) {
    errors.extraOptions = "Every SSH option must use the supported allowlist.";
  }
  if (draft.proxyKind === "jump") {
    if (draft.proxyHost.trim().length === 0) errors.proxyHost = "Jump host is required.";
    if (!validPort(draft.proxyPort)) errors.proxyPort = "Jump port must be in 1...65535.";
    if (draft.proxyUser.trim().length === 0) errors.proxyUser = "Jump user is required.";
  }
  if (draft.proxyKind === "command" && !draft.proxyExecutable.startsWith("/")) {
    errors.proxyExecutable = "Proxy executable must be an absolute path.";
  }
  return errors;
}

export function machineRequestBody(draft: MachineDraft, includeID: boolean): Record<string, unknown> {
  const proxy: SSHProxy | undefined = draft.proxyKind === "jump"
    ? {
      kind: "jump",
      host: draft.proxyHost,
      port: Number(draft.proxyPort),
      user: draft.proxyUser,
      ...(draft.proxyIdentityFile ? { identityFile: draft.proxyIdentityFile } : {}),
      ...(draft.proxyKnownHostsFile ? { knownHostsFile: draft.proxyKnownHostsFile } : {}),
    }
    : draft.proxyKind === "command"
      ? { kind: "command", executable: draft.proxyExecutable }
      : undefined;
  return {
    ...(includeID ? { id: draft.id } : {}),
    displayName: draft.displayName,
    kind: "ssh",
    enabled: draft.enabled,
    ssh: {
      host: draft.host,
      port: Number(draft.port),
      user: draft.user,
      ...(draft.identityFile ? { identityFile: draft.identityFile } : {}),
      extraOptions: draft.extraOptions,
      ...(proxy ? { proxy } : {}),
      remoteCcusagePath: draft.remoteCcusagePath,
    },
  };
}

function validPort(value: string) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 1 && number <= 65_535;
}

function isAllowlistedOption(value: string) {
  if (value === "-4" || value === "-6") return true;
  return /^-o (ConnectTimeout|ConnectionAttempts|ServerAliveInterval|ServerAliveCountMax)=\d+$/.test(value)
    || /^-o LogLevel=(ERROR|QUIET|FATAL)$/.test(value)
    || /^-o StrictHostKeyChecking=(yes|accept-new)$/.test(value)
    || /^-o UserKnownHostsFile=\/\S+$/.test(value);
}
