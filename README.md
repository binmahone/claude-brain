<p align="center">
  <h1 align="center">claude-brain</h1>
  <p align="center">
    <strong>Sync your Claude Code brain across machines — portable, intelligent, user-controlled.</strong>
  </p>
  <p align="center">
    <a href="docs/i18n/README.zh.md">🇨🇳 中文</a>
  </p>
  <p align="center">
    <b>claude-brain</b> is a Claude Code plugin for <b>brain sync</b> — sync Claude Code memory, skills, agents, rules, and settings across all your machines with semantic merge. Cross-machine, portable, and always under your control.
  </p>
  <p align="center">
    <a href="https://github.com/toroleapinc/claude-brain/stargazers"><img src="https://img.shields.io/github/stars/toroleapinc/claude-brain?style=social" alt="Stars"></a>
    <a href="https://github.com/toroleapinc/claude-brain/blob/main/LICENSE"><img src="https://img.shields.io/github/license/toroleapinc/claude-brain" alt="License"></a>
    <a href="https://github.com/toroleapinc/claude-brain/issues"><img src="https://img.shields.io/github/issues/toroleapinc/claude-brain" alt="Issues"></a>
    <img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-blue" alt="Platform">
    <img src="https://img.shields.io/badge/Claude%20Code-Plugin-blueviolet" alt="Claude Code Plugin">
    <a href="https://github.com/toroleapinc/claude-brain/commits/main"><img src="https://img.shields.io/github/last-commit/toroleapinc/claude-brain" alt="Last Commit"></a>
    <a href="https://github.com/toroleapinc/claude-brain/network/members"><img src="https://img.shields.io/github/forks/toroleapinc/claude-brain?style=social" alt="Forks"></a>
  </p>
</p>

---

```
# Machine A (work laptop) — first time setup
> /brain-init git@github.com:you/my-brain.git
✓ Brain exported: 42 memory entries, 3 skills, 5 rules
✓ Pushed to remote

# Machine B (home desktop) — join existing brain
> /brain-join git@github.com:you/my-brain.git
✓ Pulled brain: 42 memory entries, 3 skills, 5 rules
✓ Merged with local state — review changes with /brain-sync

# Later... sync from any machine
> /brain-sync
✓ 2 incoming changes (1 rule, 1 skill). Apply? [y/n]
```

<p align="center">
  <em>Two commands to set up. One command to sync. You approve every change.</em>
</p>

---

## The Problem

You use Claude Code on multiple machines. Your laptop has learned your coding patterns. Your desktop has custom skills. Your cloud VM has different rules. **None of them talk to each other.**

Every time you switch machines, you lose context. You re-teach Claude the same things. Your carefully crafted CLAUDE.md stays behind.

## The Solution

```
# Machine A (work laptop)
> /brain-init git@github.com:you/my-brain.git
✓ Brain exported: 42 memory entries, 3 skills, 5 rules
✓ Pushed to remote

# Machine B (home desktop)
> /brain-join git@github.com:you/my-brain.git
✓ Pulled brain: 42 memory entries, 3 skills, 5 rules
✓ Changes ready for review

> /brain-sync
✓ 2 incoming changes: 1 new rule, 1 updated skill
✓ Apply? Yes
✓ Applied and pushed.
```

Two commands to set up. `/brain-sync` when you switch machines. You review and approve every change before it touches your config.

## Why claude-brain?

| Tool | What it does | What claude-brain adds |
|------|-------------|----------------------|
| **claude-mem** | Enhances memory on one machine | Syncs your *entire brain* across all machines |
| **chezmoi / dotfiles** | Copies config files | **Intelligently merges** knowledge — resolves contradictions, deduplicates |
| **Manual CLAUDE.md copy** | Works but tedious | One-command sync with change review and approval |

**No other tool does cross-machine semantic merge of Claude Code's brain state.**

## Key Features

- **Manual sync with approval** — you trigger `/brain-sync`, review changes, approve before apply
- **Semantic merge** — LLM-powered deduplication of memory and CLAUDE.md (not just overwrite)
- **LLM-powered 2-way merge** — consolidated brain + current snapshot merged by Claude; laptop, desktop, and cloud VM all converge intelligently
- **Encryption** — optional `age` encryption for brain snapshots at rest
- **Team sharing** — share skills, agents, and rules with teammates
- **Evolve** — analyze memory and promote stable patterns to CLAUDE.md or rules
- **Security-first** — secrets stripped, env vars excluded, private repo enforced, backups before every import
- **Dirt cheap** — ~$0.50-2.00/month typical usage via `claude -p`

## Quick Start

### Install

```bash
# Add the marketplace and install
/plugin marketplace add toroleapinc/claude-brain
/plugin install claude-brain-sync
```

### Initialize (first machine)

```
/brain-init git@github.com:you/my-brain.git
```

### Join (other machines)

```
/brain-join git@github.com:you/my-brain.git
```

### With encryption

```
/brain-init git@github.com:you/my-brain.git --encrypt
```

Done. Run `/brain-sync` whenever you want to pull changes from other machines.

## Commands

| Command | Description |
|---------|-------------|
| `/brain-init <remote>` | Initialize brain network with a Git remote |
| `/brain-join <remote>` | Join an existing brain network |
| `/brain-sync` | Sync with remote — shows changes for your approval before applying |
| `/brain-status` | Show brain inventory and sync status |
| `/brain-evolve` | Analyze memory and propose promotions to CLAUDE.md or rules |
| `/brain-conflicts` | Resolve merge conflicts skipped during sync/join |
| `/brain-share <type> <name>` | Share a skill, agent, or rule with the team |
| `/brain-shared-list` | List all shared artifacts in the network |
| `/brain-log` | Show sync history |

## What Gets Synced

| Component | Synced? | Merge Strategy |
|-----------|---------|----------------|
| CLAUDE.md | Yes | Semantic merge |
| Rules | Yes | Union by filename |
| Skills | Yes | Union by name |
| Agents | Yes | Union by name |
| Auto memory | Yes | Semantic merge |
| Agent memory | Yes | Semantic merge |
| Settings (hooks, permissions) | Yes | Deep merge |
| Keybindings | Yes | Union |
| MCP servers | Yes | Union (env vars stripped) |
| Shared team artifacts | Yes | Union via shared namespace |
| **OAuth tokens** | **Never** | Security |
| **Env vars** | **Never** | Machine-specific |
| **API keys** | **Never** | Stripped automatically |

## Architecture

```
Machine A              Machine B              Machine C
┌──────────┐          ┌──────────┐          ┌──────────┐
│ claude-   │          │ claude-   │          │ claude-   │
│ brain     │          │ brain     │          │ brain     │
│ plugin    │          │ plugin    │          │ plugin    │
└─────┬─────┘          └─────┬─────┘          └─────┬─────┘
      │                      │                      │
      └──────────┬───────────┴──────────┬───────────┘
                 │     Git Remote       │
                 │  (your private       │
                 │       repo)          │
                 └──────────────────────┘
```

No central server. Git handles transport. You run `/brain-sync` to pull, merge, review, and push.

**Merge strategy:**
- **Structured data** (settings, keybindings, MCP) -> deterministic JSON deep-merge (free)
- **Unstructured data** (memory, CLAUDE.md) -> LLM-powered semantic merge via `claude -p` (~$0.01-0.05)

**Sync flow:**
1. `/brain-sync` exports your current state, pulls remote changes, merges
2. Shows you a summary of incoming changes (including new MCP servers)
3. You approve -> backup + import to local + push to remote

## Security

claude-brain is designed with security as a first-class concern:

- **Secrets are never exported** — OAuth tokens, API keys, env vars, `.claude.json` are all excluded
- **Pattern-based secret scanning** — warns if potential secrets are detected in memory
- **MCP env vars stripped** — server configs sync without credentials
- **Private repo enforced** — warns if public repo detected
- **Automatic backups** — every import creates a backup in `~/.claude/brain-backups/` (includes memory, settings, ~/.claude.json)
- **User approval required** — no changes are applied to your local config without your explicit approval
- **New MCP servers highlighted** — sync summary calls out new MCP servers since they grant Claude access to new tools
- **Machine trust model** — only add machines you fully control
- **Optional encryption** — `age` encryption for snapshots at rest

See the full [Security Notice](#security-notice) below.

## API Costs

| Operation | Cost | When |
|-----------|------|------|
| Structured merge | **Free** | Every sync |
| Semantic merge | ~$0.01-0.05 | Only when content differs |
| Evolve analysis | ~$0.02-0.10 | When you run /brain-evolve |
| Export / import | **Free** | Every sync |

**Typical monthly cost: $0.50-2.00** for active multi-machine use. Budget cap: $0.50/call (configurable).

## Platform Support

| Platform | Status |
|----------|--------|
| Linux | Fully supported |
| macOS | Fully supported (Apple Silicon + Intel) |
| WSL | Fully supported (WSL2 recommended) |
| Windows native | Not supported (use WSL) |

## Dependencies

- `git` — sync transport
- `jq` — JSON processing (`apt install jq` / `brew install jq`)
- `claude` CLI — semantic merge (already installed with Claude Code)
- `age` — optional, for encryption

## Team Sharing

Share skills, agents, and rules with teammates:

```
/brain-share skill my-useful-tool.md
/brain-share agent debugger.md
/brain-share rule security.md
```

Shared artifacts live in `shared/` in the brain repo. Memory is **never** shared — personal only. Team members receive shared artifacts on their next `/brain-sync`.

## Evolve

Analyze accumulated memory and promote stable patterns to durable config:

```
/brain-evolve
```

- Analyzes memory for stable, repeated patterns across projects
- Presents each recommendation for your approval (Accept / Skip / Edit)
- Creates a backup before applying any changes
- Run `/brain-sync` afterward to push changes to other machines

## Encryption

```
/brain-init git@github.com:you/my-brain.git --encrypt
```

- Generates an `age` keypair per machine
- Snapshots encrypted before push, decrypted on pull
- Recipients file controls access: `meta/recipients.txt`
- Backward compatible with unencrypted snapshots

## Security Notice

**Read this before using claude-brain.** This plugin syncs your Claude Code configuration via a Git remote. Understand what data leaves your machine:

### What IS exported
- CLAUDE.md, rules, skills, agents
- Auto memory and agent memory
- Settings (hooks, permissions — NOT env vars)
- MCP server configurations (env vars stripped)
- Keybindings
- Machine hostname and project directory names

### What is NEVER exported
- OAuth tokens and API keys
- `~/.claude.json` (credentials)
- Environment variables from settings
- MCP server `env` fields
- `.local` config files
- Session transcripts

### Important considerations
1. **Use a PRIVATE Git repository.** Plugin warns if public repo detected.
2. **Memory may contain sensitive context.** Review before initializing.
3. **Git history is permanent.** Use `git-filter-repo` to purge if needed.
4. **All changes require your approval.** Nothing is applied without you reviewing and confirming.
5. **Semantic merge uses Claude API.** Memory content is sent to `claude -p`.
6. **Trust all machines in your network.** Imported skills execute with Claude's permissions.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT
