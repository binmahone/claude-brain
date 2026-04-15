# Session: Bug Fixes + Integration Tests (2025-04-15)

## Overview

Fixed 5 critical bugs in the sync/merge pipeline and built a comprehensive integration test suite (13 tests, all passing).

## Bugs Fixed

### 1. Recursive sync via `check_llm_available` (critical)

**Symptom**: `merge.sh` erased auto_memory data during merge.

**Root cause**: `check_llm_available()` in `common.sh` ran `claude -p -` to probe the API. This started a full Claude session, which triggered the brain-sync `SessionStart` hook (`hooks.json`), causing a recursive `sync.sh -> merge.sh` cycle that overwrote `consolidated/brain.json` with empty data.

**Fix**: 
- Removed `check_llm_available` call from `merge.sh` entirely.
- Simplified `check_llm_available()` to only check `command -v claude` (no probe).

**Files**: `scripts/common.sh`, `scripts/merge.sh`

### 2. `append_merge_log` after commit

**Symptom**: Third sync on a machine failed with "cannot pull with rebase: You have unstaged changes."

**Root cause**: `sync.sh` called `append_merge_log` *after* `git add + commit + push`, leaving `meta/merge-log.json` as an unstaged modification. The next sync's `git pull --rebase` refused to run.

**Fix**: Moved `append_merge_log` before `git add consolidated/ meta/` so it's included in the same commit.

**Files**: `scripts/sync.sh`

### 3. `snapshot.sh` missed new (untracked) files

**Symptom**: First snapshot on a machine was never committed; `git diff --quiet` returned 0 for untracked files.

**Root cause**: `git diff --quiet` only checks tracked files. On first sync, `machines/<id>/brain-snapshot.json` was a new untracked file — invisible to `git diff`.

**Fix**: Added `git ls-files --others` check alongside `git diff --quiet`.

**Files**: `scripts/snapshot.sh`

### 4. Wrong path encoding functions

**Symptom**: N/A (dead code producing wrong results).

**Root cause**: `decode_project_path`, `encode_project_path`, `project_name_from_encoded` used a doubled-hyphen algorithm that doesn't match Claude Code's actual `tr '/_' '-'` encoding.

**Fix**: Deleted all three functions. Replaced callers with `sed 's/.*-//'`.

**Files**: `scripts/common.sh`, `scripts/register-machine.sh`, `scripts/status.sh`

### 5. `merge.sh` LLM calls via `claude -p` (architectural)

**Symptom**: Any CLAUDE.md or memory file conflict triggered `claude -p` inside `merge.sh`, which started a Claude session and triggered recursive sync hooks (same root cause as bug #1).

**Root cause**: `merge.sh` ran inline LLM merges via `llm_merge_text()` -> `claude -p`. Every `claude -p` invocation started a new session, firing `SessionStart` hooks.

**Fix**: 
- Removed ALL `claude -p` calls from `merge.sh`.
- Conflicts are now recorded to `brain-conflicts.json` (deferred resolution).
- Created `scripts/resolve-conflicts.sh` which reads conflicts, calls `claude -p` with `HOME=/tmp` (prevents hooks), and applies resolutions.
- Subshell gotcha: conflict recording initially used a bash array (`_new_conflicts`), but arrays modified inside `$(...)` subshells are invisible to the parent. Also tried a staging file via `brain_mktemp`, but the EXIT trap in subshells deleted it. Final solution: write directly to `CONFLICTS_FILE` on each conflict.

**Files**: `scripts/merge.sh` (rewrite), `scripts/resolve-conflicts.sh` (new)

## Integration Test Suite

Created `tests/run-it.sh` — 13 tests, all passing in ~43 seconds.

### Architecture
- Each test gets an isolated bare git repo as remote + separate HOME dirs per machine
- `sync_machine()` wraps `sync.sh` with correct env vars
- `resolve_conflicts()` wraps `resolve-conflicts.sh` with `REAL_HOME` for claude auth
- Tests run in subshells; exit code 0=pass, 1=fail, 77=skip

### Test Categories

**Structural merge tests (10):**
1. `test_basic_two_machine_sync` — memory written on A appears on B
2. `test_no_import_for_missing_project` — memory not imported to missing project dirs
3. `test_accumulated_memory_across_syncs` — multiple session accumulation
4. `test_three_machine_fan_out` — A+B push, C receives both
5. `test_non_conflicting_merge_no_llm` — different files union without LLM
6. `test_global_claude_md_propagates` — CLAUDE.md one-way propagation
7. `test_group_sync_one_way` — group copies files to other member
8. `test_group_sync_bidirectional` — group bidirectional sync
9. `test_offline_then_rejoin` — offline machine preserves local + receives remote
10. `test_sequential_edits_same_file_no_conflict` — same content no conflict

**Lifecycle test (1):**
11. `test_full_lifecycle` — 3 machines (alice/bob/carol), 7 projects, 32 sessions over 9 simulated days. Covers: gradual project creation, session-start-only sync model, group configuration, convergence verification, cross-machine consistency.

**Conflict resolution tests with LLM (2):**
12. `test_memory_conflict_resolve` — conflicting memory file -> detect -> LLM merge -> verify both sides preserved
13. `test_claude_md_conflict_resolve` — conflicting CLAUDE.md -> detect -> LLM merge -> verify both sides preserved

### Session-start-only sync model

Sync only fires on session START (not end). Memory written during session N is not available to other machines until session N+1's sync. The lifecycle test faithfully models this: `write_mem` always happens AFTER `sync_machine`, and mid-test assertions account for the one-session delay.

## Key Design Decisions

1. **merge.sh is pure bash, no LLM** — conflicts are deferred to `brain-conflicts.json`. This eliminates the recursive hook problem entirely.

2. **`resolve-conflicts.sh` uses `HOME=/tmp`** — prevents `SessionStart` hooks from firing when `claude -p` starts a session. The hook checks `$HOME/.claude/brain-config.json` which doesn't exist under `/tmp`.

3. **Direct file writes for conflict tracking** — not bash arrays (lost in subshells) or `brain_mktemp` files (deleted by EXIT traps in subshells). Each `record_conflict` call writes directly to `CONFLICTS_FILE` via `mktemp + jq + mv`.
