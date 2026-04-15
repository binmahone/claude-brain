<p align="center">
  <h1 align="center">claude-brain</h1>
  <p align="center">
    <strong>Sync your Claude Code brain across machines.</strong><br>
    Memory, skills, agents, rules, settings — merged intelligently, applied with your approval.
  </p>
  <p align="center">
    <a href="docs/i18n/README.zh.md">🇨🇳 中文</a>
  </p>
  <p align="center">
    <a href="https://github.com/toroleapinc/claude-brain/stargazers"><img src="https://img.shields.io/github/stars/toroleapinc/claude-brain?style=social" alt="Stars"></a>
    <a href="https://github.com/toroleapinc/claude-brain/blob/main/LICENSE"><img src="https://img.shields.io/github/license/toroleapinc/claude-brain" alt="License"></a>
    <img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-blue" alt="Platform">
    <img src="https://img.shields.io/badge/Claude%20Code-Plugin-blueviolet" alt="Claude Code Plugin">
  </p>
</p>

---

```
> /brain-init git@github.com:you/my-brain.git     # first machine
> /brain-join git@github.com:you/my-brain.git     # other machines

> /brain-sync                                      # whenever you switch
  Incoming: 1 new rule, 2 memory updates, 1 new MCP server (filesystem)
  Apply and push? [y/n]
```

---

## Why

You use Claude Code on multiple machines. Your laptop learned your preferences. Your desktop has custom skills. **They don't talk to each other.** Every switch means re-teaching Claude the same things.

claude-brain fixes this: one command to sync, you review every change before it lands.

## How it works

```
/brain-sync
  1. Export your current state (snapshot)
  2. Pull other machines' changes
  3. 3-way merge (only real conflicts flagged — local-only or remote-only changes just work)
  4. Show you what changed ← you approve here
  5. Backup → import → push
```

Nothing touches your local config until you say yes.

## Safety model

| Principle | How |
|-----------|-----|
| **You approve everything** | Sync shows a diff summary; import + push only after your OK |
| **Backup before every import** | `~/.claude/brain-backups/` — memory, settings, ~/.claude.json included |
| **Secrets never leave** | OAuth tokens, API keys, env vars, ~/.claude.json credentials — all excluded |
| **MCP servers highlighted** | New servers called out explicitly (they grant Claude new tool access) |
| **Bad merge can't corrupt** | JSON validation before overwriting settings or ~/.claude.json |
| **Private repo enforced** | Warns on public repos; `--force` required to override |
| **Optional encryption** | `age` encryption for snapshots at rest |

## Quick start

```bash
# Install
/plugin marketplace add toroleapinc/claude-brain
/plugin install claude-brain-sync

# First machine
/brain-init git@github.com:you/my-brain.git

# Other machines
/brain-join git@github.com:you/my-brain.git

# Sync anytime
/brain-sync
```

## What gets synced

| Synced | Never synced |
|--------|--------------|
| CLAUDE.md, rules, skills, agents | OAuth tokens, API keys |
| Memory (auto + agent, per-project) | Environment variables |
| Settings (permissions, hooks) | `~/.claude.json` credentials |
| MCP servers (env vars **stripped**) | `.local` config files |
| Keybindings | Session transcripts |

## Commands

| Command | What it does |
|---------|--------------|
| `/brain-sync` | Pull + merge + show changes + approve + push |
| `/brain-status` | Show inventory, machines, sync timestamps |
| `/brain-evolve` | Analyze memory, propose promotions to CLAUDE.md or rules |
| `/brain-conflicts` | Resolve conflicts skipped during sync |
| `/brain-share <type> <name>` | Share a skill/agent/rule with teammates |
| `/brain-log` | Show sync history |

## Merge strategy

| Data type | Method | Cost |
|-----------|--------|------|
| Rules, skills, agents | File union (same name = compare content) | Free |
| Settings, keybindings, MCP | JSON deep merge | Free |
| Memory, CLAUDE.md | 3-way merge with baseline; LLM for real conflicts | ~$0.01-0.05 per conflict |

**3-way merge** uses the last-synced state as baseline:
- Only you changed a file? Your version wins. No conflict.
- Only the other machine changed? Their version wins. No conflict.
- Both changed differently? Real conflict — you decide.

Typical monthly cost: **$0.50-2.00** for active multi-machine use.

## Architecture

```
Machine A              Machine B              Machine C
┌──────────┐          ┌──────────┐          ┌──────────┐
│ snapshot  │          │ snapshot  │          │ snapshot  │
│ + merge   │          │ + merge   │          │ + merge   │
└─────┬─────┘          └─────┬─────┘          └─────┬─────┘
      └──────────┬───────────┴──────────┬───────────┘
                 │   Git (private repo) │
                 └──────────────────────┘
```

No central server. Git is the transport. Each machine merges on sync.

## Evolve

```
/brain-evolve
```

Scans all your memory for stable cross-project patterns and proposes promotions:
- Repeated preference &rarr; CLAUDE.md instruction
- Language-specific convention &rarr; rule file
- Multi-step workflow &rarr; skill suggestion

You review each one. Backup before apply. Run `/brain-sync` to push.

## Team sharing

```
/brain-share skill my-tool.md
/brain-shared-list
```

Skills, agents, and rules go to `shared/` in the brain repo. **Memory is never shared.** Teammates receive shared artifacts on their next `/brain-sync`.

## Encryption

```
/brain-init git@github.com:you/my-brain.git --encrypt
```

Per-machine `age` keypair. Snapshots encrypted before push, decrypted on pull.

## Platform & dependencies

**Supported:** Linux, macOS (Apple Silicon + Intel), WSL2

**Required:** `git`, `jq`, `claude` CLI. **Optional:** `age` (encryption).

## Security notice

This plugin syncs Claude Code configuration via Git. Before using:

1. **Use a PRIVATE repository.** Plugin warns if public.
2. **Memory may contain sensitive context** from your conversations. Review `~/.claude/projects/*/memory/` before initializing.
3. **Git history is permanent.** Use `git-filter-repo` to purge secrets if needed.
4. **All changes require your approval.** No auto-sync, no silent imports.
5. **Semantic merge sends memory to Claude API** via `claude -p`.
6. **Trust all machines in your network.** Imported skills execute with Claude's permissions.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
