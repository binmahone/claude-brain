# Changelog

All notable changes to claude-brain will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **All sync is now manual** — removed SessionStart auto-sync hook; use `/brain-sync` explicitly
- **All changes require user approval** — sync, join, and evolve show a summary and wait for approval before importing or pushing
- **Conflicts resolved inline** — conflicts are presented during sync/join/evolve instead of requiring separate `/brain-conflicts`; that command is now a fallback for skipped conflicts
- `/brain-init` now checks if remote is non-empty and blocks unless `--force` is passed
- `/brain-evolve` is analysis-only; no auto-apply, no auto-trigger from sync
- Push moved into `--apply` — default sync only commits locally
- MCP servers added from other machines are highlighted in sync summary

### Fixed
- `backup_before_import()` now includes memory (auto_memory per project), agent-memory, and `~/.claude.json`
- `restore_from_backup()` updated to match

### Removed
- SessionStart auto-sync hook
- `--auto` mode in evolve.sh
- `evolve_interval_days` config (no longer auto-triggered)

## [0.1.0] - 2026-03-03

### Added
- Initial release
- Brain sync via Git (`/brain-init`, `/brain-join`, `/brain-sync`)
- Semantic merge for CLAUDE.md and memory using `claude -p`
- Structured merge for settings, keybindings, MCP configs
- LLM-powered 2-way merge (consolidated + current snapshot); all machines converge intelligently
- Brain status and inventory (`/brain-status`)
- Sync history log (`/brain-log`)
- Brain evolution — promote stable patterns from memory to config (`/brain-evolve`)
- Conflict detection and resolution (`/brain-conflicts`)
- Team sharing of skills, agents, and rules (`/brain-share`)
- Secret scanning with pattern-based detection
- Optional age encryption for snapshots at rest
- Automatic backups before import
- `--dry-run` flag for push/pull (community contribution by @a638011)
- Sync statistics in status output
- WSL support with path handling
- Chinese README translation
