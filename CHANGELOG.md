# Changelog

All notable changes to claude-brain will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-03-03

### Added
- Initial release
- Brain sync via Git (`/brain-init`, `/brain-join`, `/brain-sync`)
- Semantic merge for CLAUDE.md and memory using `claude -p`
- Structured merge for settings, keybindings, MCP configs
- LLM-powered 2-way merge (consolidated + current snapshot); all machines converge intelligently
- Auto-sync hooks on session start/end
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
