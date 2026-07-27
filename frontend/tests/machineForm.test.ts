import { describe, expect, test } from "bun:test";
import { changingProxyKind, draftFromMachine, machineDraftErrors, machineRequestBody, machineSessionSourceBody } from "../src/machineForm";
import type { Machine } from "../src/api";

const jumpMachine: Machine = {
  id: "remote-a",
  displayName: "Remote A",
  kind: "ssh",
  enabled: false,
  codexSessionDirs: ["/srv/codex-a"],
  claudeConfigDirs: ["~/claude-a"],
  includeDefaultCodexDir: false,
  includeDefaultClaudeDir: true,
  ssh: {
    host: "target.internal",
    port: 2222,
    user: "ccusage",
    identityFile: "/tmp/target-key",
    extraOptions: ["-o ConnectTimeout=10", "-4"],
    remoteCcusagePath: "/usr/local/bin/ccusage",
    proxy: {
      kind: "jump",
      host: "jump.internal",
      port: 2200,
      user: "relay",
      identityFile: "/tmp/jump-key",
      knownHostsFile: "/tmp/known-hosts",
    },
  },
};

describe("machine form", () => {
  test("initializes and serializes every persisted SSH and jump field", () => {
    const draft = draftFromMachine(jumpMachine);
    expect(draft.enabled).toBe(false);
    expect(draft.extraOptions).toEqual(["-o ConnectTimeout=10", "-4"]);
    expect(machineRequestBody(draft, false)).toEqual({
      displayName: "Remote A",
      kind: "ssh",
      enabled: false,
      codexSessionDirs: ["/srv/codex-a"],
      claudeConfigDirs: ["~/claude-a"],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: true,
      ssh: {
        host: "target.internal",
        port: 2222,
        user: "ccusage",
        identityFile: "/tmp/target-key",
        extraOptions: ["-o ConnectTimeout=10", "-4"],
        remoteCcusagePath: "/usr/local/bin/ccusage",
        proxy: {
          kind: "jump",
          host: "jump.internal",
          port: 2200,
          user: "relay",
          identityFile: "/tmp/jump-key",
          knownHostsFile: "/tmp/known-hosts",
        },
      },
    });
  });

  test("clears fields owned by a previous proxy variant", () => {
    const direct = changingProxyKind(draftFromMachine(jumpMachine), "direct");
    expect(direct.proxyHost).toBe("");
    expect(direct.proxyIdentityFile).toBe("");
    expect(machineRequestBody(direct, false)).not.toHaveProperty("ssh.proxy");
  });

  test("rejects raw proxy commands and unallowlisted SSH options", () => {
    const draft = {
      ...draftFromMachine(jumpMachine),
      proxyKind: "command" as const,
      proxyExecutable: "helper --token secret",
      extraOptions: ["-o ProxyCommand=sh -c bad"],
    };
    expect(machineDraftErrors(draft)).toMatchObject({
      proxyExecutable: "Proxy executable must be an absolute path.",
      extraOptions: "Every SSH option must use the supported allowlist.",
    });
  });

  test("supports local source-only edits and indexed path validation", () => {
    const local: Machine = {
      id: "local",
      displayName: "Local",
      kind: "local",
      enabled: true,
      codexSessionDirs: ["/srv/codex"],
      claudeConfigDirs: [],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: true,
    };
    const draft = draftFromMachine(local);
    expect(machineSessionSourceBody(draft)).toEqual({
      codexSessionDirs: ["/srv/codex"],
      claudeConfigDirs: [],
      includeDefaultCodexDir: false,
      includeDefaultClaudeDir: true,
    });
    expect(machineDraftErrors({ ...draft, claudeConfigDirs: ["relative"] })).toEqual({
      "claudeConfigDirs[0]": "Use an absolute or ~-prefixed path without control characters.",
    });
  });
});
