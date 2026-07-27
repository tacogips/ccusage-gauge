import type { Machine, SSHProxy } from "./api";

export type MachineProxyKind = "direct" | "jump" | "command";

export interface MachineDraft {
  kind: "local" | "ssh";
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
  codexSessionDirs: string[];
  claudeConfigDirs: string[];
  includeDefaultCodexDir: boolean;
  includeDefaultClaudeDir: boolean;
}

export function emptyMachineDraft(): MachineDraft {
  return {
    kind: "ssh",
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
    codexSessionDirs: [],
    claudeConfigDirs: [],
    includeDefaultCodexDir: true,
    includeDefaultClaudeDir: true,
  };
}

export function draftFromMachine(machine: Machine): MachineDraft {
  const draft = emptyMachineDraft();
  if (machine.kind === "local") {
    return {
      ...draft,
      kind: "local",
      id: machine.id,
      displayName: machine.displayName,
      enabled: true,
      codexSessionDirs: [...(machine.codexSessionDirs ?? [])],
      claudeConfigDirs: [...(machine.claudeConfigDirs ?? [])],
      includeDefaultCodexDir: machine.includeDefaultCodexDir ?? true,
      includeDefaultClaudeDir: machine.includeDefaultClaudeDir ?? true,
    };
  }
  if (machine.ssh == null) throw new Error("SSH connection is required");
  const proxy = machine.ssh.proxy;
  return {
    ...draft,
    kind: "ssh",
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
    codexSessionDirs: [...(machine.codexSessionDirs ?? [])],
    claudeConfigDirs: [...(machine.claudeConfigDirs ?? [])],
    includeDefaultCodexDir: machine.includeDefaultCodexDir ?? true,
    includeDefaultClaudeDir: machine.includeDefaultClaudeDir ?? true,
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
  if (draft.kind === "ssh" && (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(draft.id) || ["local", "all"].includes(draft.id))) {
    errors.id = "Use a canonical lowercase machine id.";
  }
  if (draft.kind === "ssh") {
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
  }
  validateSourcePaths(draft.codexSessionDirs, "codexSessionDirs", errors);
  validateSourcePaths(draft.claudeConfigDirs, "claudeConfigDirs", errors);
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
    codexSessionDirs: draft.codexSessionDirs,
    claudeConfigDirs: draft.claudeConfigDirs,
    includeDefaultCodexDir: draft.includeDefaultCodexDir,
    includeDefaultClaudeDir: draft.includeDefaultClaudeDir,
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

export function machineSessionSourceBody(draft: MachineDraft): Record<string, unknown> {
  return {
    codexSessionDirs: draft.codexSessionDirs,
    claudeConfigDirs: draft.claudeConfigDirs,
    includeDefaultCodexDir: draft.includeDefaultCodexDir,
    includeDefaultClaudeDir: draft.includeDefaultClaudeDir,
  };
}

function validateSourcePaths(values: string[], field: string, errors: Record<string, string>) {
  values.forEach((value, index) => {
    const bytes = new TextEncoder().encode(value).length;
    if (bytes < 1 || bytes > 4_096 || (!value.startsWith("/") && value !== "~" && !value.startsWith("~/"))
      || [...value].some((character) => {
        const code = character.charCodeAt(0);
        return code < 0x20 || code === 0x7f;
      })) {
      errors[`${field}[${index}]`] = "Use an absolute or ~-prefixed path without control characters.";
    }
  });
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
