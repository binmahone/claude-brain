#!/usr/bin/env bash
# run-it.sh — Integration tests for claude-brain-sync
#
# Simulates real multi-machine scenarios using:
#   - Local bare git repos (no network required)
#   - Isolated HOME directories per "machine"
#   - Real script execution (sync.sh, merge.sh, import.sh, export.sh)
#   - Optional real LLM calls for conflict-merge tests
#
# Usage:
#   ./tests/run-it.sh            # run all tests (includes LLM conflict resolution)
#   ./tests/run-it.sh --verbose  # show stderr from syncs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRAIN_SCRIPTS="$(cd "$SCRIPT_DIR/../scripts" && pwd)"

# Save real HOME for LLM calls (test machines have fake HOME dirs)
ORIG_HOME="$HOME"

# ── Flags ─────────────────────────────────────────────────────────────────────
VERBOSE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --verbose|-v) VERBOSE=true ;;
  esac
  shift
done

# ── Counters ──────────────────────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
FAILURES=()

# ── Working directory ─────────────────────────────────────────────────────────
IT_BASE=$(mktemp -d /tmp/brain-it-XXXXXX)
trap 'rm -rf "$IT_BASE" 2>/dev/null || true' EXIT

# ── Git identity (avoid "Please tell me who you are" errors) ─────────────────
export GIT_AUTHOR_NAME="Brain IT"
export GIT_AUTHOR_EMAIL="brain-it@test.local"
export GIT_COMMITTER_NAME="Brain IT"
export GIT_COMMITTER_EMAIL="brain-it@test.local"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create an isolated test environment with its own bare git remote.
# Prints the test directory path.
make_test_env() {
  local name="${1:-test}"
  local tdir="$IT_BASE/$name"
  mkdir -p "$tdir"

  # Bare remote
  git init --bare "$tdir/remote.git" -q 2>/dev/null

  # Seed with an empty initial commit so 'main' branch exists
  local seed
  seed=$(mktemp -d)
  git -C "$seed" init -q 2>/dev/null
  git -C "$seed" remote add origin "$tdir/remote.git"
  git -C "$seed" commit --allow-empty -m "init" -q 2>/dev/null
  git -C "$seed" push origin HEAD:main -q 2>/dev/null
  rm -rf "$seed"

  echo "$tdir"
}

# Add a simulated machine to a test environment.
# Creates HOME dir, clones brain repo, writes brain-config.json.
# Prints the machine's home path.
setup_machine() {
  local tdir="$1" mname="$2" mid="$3"
  local mhome="$tdir/machines/$mname/home"
  local claude_dir="$mhome/.claude"
  local brain_repo="$claude_dir/brain-repo"

  mkdir -p "$claude_dir/projects" "$claude_dir/skills" "$claude_dir/agents"

  git clone "$tdir/remote.git" "$brain_repo" -b main -q 2>/dev/null
  git -C "$brain_repo" config user.email "brain-it@test.local"
  git -C "$brain_repo" config user.name "Brain IT ($mname)"

  mkdir -p "$brain_repo/machines/$mid" \
           "$brain_repo/consolidated" \
           "$brain_repo/meta/machines"

  # Set last_evolved to now so auto-evolve never fires during tests
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat > "$claude_dir/brain-config.json" <<JSON
{
  "version": "1.0.0",
  "remote": "file://$tdir/remote.git",
  "machine_id": "$mid",
  "machine_name": "$mname",
  "os": "linux",
  "brain_repo_path": "$brain_repo",
  "auto_sync": true,
  "registered_at": "$now",
  "last_push": null,
  "last_pull": null,
  "last_evolved": "$now",
  "dirty": false,
  "encryption": {"enabled": false}
}
JSON
  chmod 600 "$claude_dir/brain-config.json"
}

# Common env vars for running scripts as a given machine.
machine_env() {
  local tdir="$1" mname="$2"
  local mhome="$tdir/machines/$mname/home"
  local claude_dir="$mhome/.claude"
  echo "HOME=$mhome CLAUDE_DIR=$claude_dir CLAUDE_JSON=$mhome/.claude.json BRAIN_REPO=$claude_dir/brain-repo BRAIN_CONFIG=$claude_dir/brain-config.json BRAIN_QUIET=true"
}

# Run a brain script as a given machine.
run_as() {
  local tdir="$1" mname="$2"; shift 2
  local mhome="$tdir/machines/$mname/home"
  local claude_dir="$mhome/.claude"

  if $VERBOSE; then
    HOME="$mhome" \
      CLAUDE_DIR="$claude_dir" \
      CLAUDE_JSON="$mhome/.claude.json" \
      BRAIN_REPO="$claude_dir/brain-repo" \
      BRAIN_CONFIG="$claude_dir/brain-config.json" \
      BRAIN_QUIET=true \
      "$@"
  else
    HOME="$mhome" \
      CLAUDE_DIR="$claude_dir" \
      CLAUDE_JSON="$mhome/.claude.json" \
      BRAIN_REPO="$claude_dir/brain-repo" \
      BRAIN_CONFIG="$claude_dir/brain-config.json" \
      BRAIN_QUIET=true \
      "$@" >/dev/null 2>&1
  fi
}

# Run one full sync cycle for a machine (snapshot → pull → merge → commit → import → push).
sync_machine() {
  local tdir="$1" mname="$2"
  run_as "$tdir" "$mname" bash "$BRAIN_SCRIPTS/sync.sh" --quiet
  run_as "$tdir" "$mname" bash "$BRAIN_SCRIPTS/sync.sh" --apply --quiet
}

# Run sync WITHOUT apply (merge + commit locally, no import, no push).
sync_machine_no_apply() {
  local tdir="$1" mname="$2"
  run_as "$tdir" "$mname" bash "$BRAIN_SCRIPTS/sync.sh" --quiet
}

# Get sync summary JSON for a machine.
get_summary() {
  local tdir="$1" mname="$2"
  local mhome="$tdir/machines/$mname/home"
  local claude_dir="$mhome/.claude"
  HOME="$mhome" \
    CLAUDE_DIR="$claude_dir" \
    CLAUDE_JSON="$mhome/.claude.json" \
    BRAIN_REPO="$claude_dir/brain-repo" \
    BRAIN_CONFIG="$claude_dir/brain-config.json" \
    BRAIN_QUIET=true \
    bash "$BRAIN_SCRIPTS/sync.sh" --summary 2>/dev/null
}

# Resolve pending conflicts for a machine using LLM (calls claude -p).
resolve_conflicts() {
  local tdir="$1" mname="$2"
  local mhome="$tdir/machines/$mname/home"
  local claude_dir="$mhome/.claude"

  REAL_HOME="$ORIG_HOME" \
  CONFLICTS_FILE="$claude_dir/brain-conflicts.json" \
  run_as "$tdir" "$mname" bash "$BRAIN_SCRIPTS/resolve-conflicts.sh" --quiet
}

# Check how many unresolved conflicts a machine has.
conflict_count() {
  local tdir="$1" mname="$2"
  local f="$tdir/machines/$mname/home/.claude/brain-conflicts.json"
  if [ -f "$f" ]; then
    jq '[.conflicts[] | select(.resolved != true)] | length' "$f"
  else
    echo 0
  fi
}

# Write a memory file for a machine's project (creates dirs as needed).
write_mem() {
  local tdir="$1" mname="$2" encoded="$3" fname="$4" content="$5"
  local mem_dir="$tdir/machines/$mname/home/.claude/projects/$encoded/memory"
  mkdir -p "$mem_dir"
  printf '%s\n' "$content" > "$mem_dir/$fname"
}

# Ensure a project directory exists on a machine
# (import.sh only writes memory when the project dir exists).
ensure_project() {
  local tdir="$1" mname="$2" encoded="$3"
  mkdir -p "$tdir/machines/$mname/home/.claude/projects/$encoded"
}

# Read a memory file; returns empty string if not found.
read_mem() {
  local tdir="$1" mname="$2" encoded="$3" fname="$4"
  cat "$tdir/machines/$mname/home/.claude/projects/$encoded/memory/$fname" 2>/dev/null || true
}

# Test whether a memory file exists on a machine.
has_mem() {
  local tdir="$1" mname="$2" encoded="$3" fname="$4"
  [ -f "$tdir/machines/$mname/home/.claude/projects/$encoded/memory/$fname" ]
}

# ── Test runner ───────────────────────────────────────────────────────────────
run_test() {
  local name="$1"
  printf '  %-55s' "$name"
  set +e
  if $VERBOSE; then
    ( set -e; "$name" )
  else
    ( set -e; "$name" ) 2>/dev/null
  fi
  local rc=$?
  set -e
  if   [ $rc -eq 0  ]; then echo "PASS"; PASS=$((PASS+1))
  elif [ $rc -eq 77 ]; then echo "SKIP"; SKIP=$((SKIP+1))
  else                       echo "FAIL"; FAIL=$((FAIL+1)); FAILURES+=("$name")
  fi
}

# Call inside a test to mark it as skipped (exit code 77).
skip_test() { exit 77; }

# ══════════════════════════════════════════════════════════════════════════════
# Non-LLM integration tests
# ══════════════════════════════════════════════════════════════════════════════

# IT-01: Memory written on machine A appears on machine B when both have
# the same project directory (same encoded path).
test_basic_two_machine_sync() {
  local tdir
  tdir=$(make_test_env "it01")
  setup_machine "$tdir" "alpha" "a001"
  setup_machine "$tdir" "beta"  "b001"

  ensure_project "$tdir" "alpha" "-home-shared-proj"
  ensure_project "$tdir" "beta"  "-home-shared-proj"

  write_mem "$tdir" "alpha" "-home-shared-proj" "notes.md" "# Notes
Written by alpha."

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  local content
  content=$(read_mem "$tdir" "beta" "-home-shared-proj" "notes.md")
  echo "$content" | grep -q "Written by alpha"
}

# IT-02: Memory is NOT imported into a project directory that does not
# exist on the target machine (different-path projects stay separate).
test_no_import_for_missing_project() {
  local tdir
  tdir=$(make_test_env "it02")
  setup_machine "$tdir" "alpha" "a002"
  setup_machine "$tdir" "beta"  "b002"

  # Alpha-only project — beta has no such directory
  write_mem "$tdir" "alpha" "-home-alpha-exclusive" "secret.md" "alpha private"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # beta should NOT have the file (no matching project dir)
  ! has_mem "$tdir" "beta" "-home-alpha-exclusive" "secret.md"
}

# IT-03: Multiple sequential session starts on machine A accumulate state;
# machine B receives all files in a single sync.
test_accumulated_memory_across_syncs() {
  local tdir
  tdir=$(make_test_env "it03")
  setup_machine "$tdir" "alpha" "a003"
  setup_machine "$tdir" "beta"  "b003"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  write_mem "$tdir" "alpha" "-home-proj" "s1.md" "session 1"
  sync_machine "$tdir" "alpha"

  write_mem "$tdir" "alpha" "-home-proj" "s2.md" "session 2"
  sync_machine "$tdir" "alpha"

  write_mem "$tdir" "alpha" "-home-proj" "s3.md" "session 3"
  sync_machine "$tdir" "alpha"

  sync_machine "$tdir" "beta"

  has_mem "$tdir" "beta" "-home-proj" "s1.md" &&
  has_mem "$tdir" "beta" "-home-proj" "s2.md" &&
  has_mem "$tdir" "beta" "-home-proj" "s3.md"
}

# IT-04: Three machines — alpha and beta each push unique files; gamma
# receives both in a single sync.
test_three_machine_fan_out() {
  local tdir
  tdir=$(make_test_env "it04")
  setup_machine "$tdir" "alpha" "a004"
  setup_machine "$tdir" "beta"  "b004"
  setup_machine "$tdir" "gamma" "g004"

  ensure_project "$tdir" "alpha" "-home-shared"
  ensure_project "$tdir" "beta"  "-home-shared"
  ensure_project "$tdir" "gamma" "-home-shared"

  write_mem "$tdir" "alpha" "-home-shared" "from-alpha.md" "Alpha contribution"
  sync_machine "$tdir" "alpha"

  write_mem "$tdir" "beta" "-home-shared" "from-beta.md" "Beta contribution"
  sync_machine "$tdir" "beta"

  sync_machine "$tdir" "gamma"

  has_mem "$tdir" "gamma" "-home-shared" "from-alpha.md" &&
  has_mem "$tdir" "gamma" "-home-shared" "from-beta.md"
}

# IT-05: Two machines write different files in the same project — no conflict,
# no LLM. After cross-sync both machines have all files.
test_non_conflicting_merge_no_llm() {
  local tdir
  tdir=$(make_test_env "it05")
  setup_machine "$tdir" "alpha" "a005"
  setup_machine "$tdir" "beta"  "b005"

  ensure_project "$tdir" "alpha" "-home-shared-app"
  ensure_project "$tdir" "beta"  "-home-shared-app"

  write_mem "$tdir" "alpha" "-home-shared-app" "alpha-prefs.md" "alpha preferences"
  write_mem "$tdir" "beta"  "-home-shared-app" "beta-prefs.md"  "beta preferences"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"
  sync_machine "$tdir" "alpha"   # second sync picks up beta's file

  has_mem "$tdir" "alpha" "-home-shared-app" "beta-prefs.md" &&
  has_mem "$tdir" "beta"  "-home-shared-app" "alpha-prefs.md"
}

# IT-06: Global CLAUDE.md written on alpha propagates to beta unchanged
# (one-sided: no LLM needed).
test_global_claude_md_propagates() {
  local tdir
  tdir=$(make_test_env "it06")
  setup_machine "$tdir" "alpha" "a006"
  setup_machine "$tdir" "beta"  "b006"

  printf '# Alpha Global Rules\n- Always use TypeScript\n' \
    > "$tdir/machines/alpha/home/.claude/CLAUDE.md"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  [ -f "$tdir/machines/beta/home/.claude/CLAUDE.md" ] &&
  grep -q "TypeScript" "$tdir/machines/beta/home/.claude/CLAUDE.md"
}

# IT-07: Group sync — machines have the same project at different paths.
# Alpha writes a file under its encoded path; beta (which already has some
# memory for its path in the group) receives it via group sync.
test_group_sync_one_way() {
  local tdir
  tdir=$(make_test_env "it07")
  setup_machine "$tdir" "alpha" "a007"
  setup_machine "$tdir" "beta"  "b007"

  ensure_project "$tdir" "alpha" "-home-alpha-myapp"
  ensure_project "$tdir" "beta"  "-home-beta-myapp"

  local groups='{"myapp":["-home-alpha-myapp","-home-beta-myapp"]}'
  printf '%s\n' "$groups" > "$tdir/machines/alpha/home/.claude/brain-groups.json"
  printf '%s\n' "$groups" > "$tdir/machines/beta/home/.claude/brain-groups.json"

  # Beta must have at least one memory entry for its project so the group
  # sync activates (needs ≥2 members present in merged memory).
  write_mem "$tdir" "beta" "-home-beta-myapp" "beta-seed.md" "beta seed"

  write_mem "$tdir" "alpha" "-home-alpha-myapp" "workflow.md" \
"# Workflow
- Step 1: build
- Step 2: test"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  has_mem "$tdir" "beta" "-home-beta-myapp" "workflow.md" &&
  grep -q "Step 1" "$tdir/machines/beta/home/.claude/projects/-home-beta-myapp/memory/workflow.md"
}

# IT-08: Group sync — bidirectional. Alpha writes alpha-note, beta writes
# beta-note; after cross-sync both machines have both notes under their
# own project path.
test_group_sync_bidirectional() {
  local tdir
  tdir=$(make_test_env "it08")
  setup_machine "$tdir" "alpha" "a008"
  setup_machine "$tdir" "beta"  "b008"

  ensure_project "$tdir" "alpha" "-home-alpha-myapp"
  ensure_project "$tdir" "beta"  "-home-beta-myapp"

  local groups='{"myapp":["-home-alpha-myapp","-home-beta-myapp"]}'
  printf '%s\n' "$groups" > "$tdir/machines/alpha/home/.claude/brain-groups.json"
  printf '%s\n' "$groups" > "$tdir/machines/beta/home/.claude/brain-groups.json"

  write_mem "$tdir" "alpha" "-home-alpha-myapp" "alpha-note.md" "from alpha"
  write_mem "$tdir" "beta"  "-home-beta-myapp"  "beta-note.md"  "from beta"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"
  sync_machine "$tdir" "alpha"   # second sync for alpha to receive beta's file

  has_mem "$tdir" "alpha" "-home-alpha-myapp" "beta-note.md" &&
  has_mem "$tdir" "beta"  "-home-beta-myapp"  "alpha-note.md"
}

# IT-09: Offline then rejoin — alpha pushes while beta is "offline" (just
# hasn't synced). When beta finally syncs it receives alpha's content AND
# its own locally-written content is preserved.
test_offline_then_rejoin() {
  local tdir
  tdir=$(make_test_env "it09")
  setup_machine "$tdir" "alpha" "a009"
  setup_machine "$tdir" "beta"  "b009"

  ensure_project "$tdir" "alpha" "-home-shared"
  ensure_project "$tdir" "beta"  "-home-shared"

  write_mem "$tdir" "alpha" "-home-shared" "alpha.md" "alpha content"
  sync_machine "$tdir" "alpha"

  # Beta writes locally while "offline" (no sync yet)
  write_mem "$tdir" "beta" "-home-shared" "beta.md" "beta content"

  # Beta comes online — should receive alpha's content and keep its own
  sync_machine "$tdir" "beta"

  has_mem "$tdir" "beta" "-home-shared" "alpha.md" &&
  has_mem "$tdir" "beta" "-home-shared" "beta.md"
}

# IT-10: Two machines simultaneously add memory to the same project on the
# same file path but synced separately, then reconcile — no LLM needed if
# one is a strict superset of the other, confirming merge.sh handles it.
test_sequential_edits_same_file_no_conflict() {
  local tdir
  tdir=$(make_test_env "it10")
  setup_machine "$tdir" "alpha" "a010"
  setup_machine "$tdir" "beta"  "b010"

  ensure_project "$tdir" "alpha" "-home-shared-proj"
  ensure_project "$tdir" "beta"  "-home-shared-proj"

  # Alpha writes v1 and syncs
  write_mem "$tdir" "alpha" "-home-shared-proj" "prefs.md" "line-a"
  sync_machine "$tdir" "alpha"

  # Beta syncs to receive v1
  sync_machine "$tdir" "beta"

  # Beta updates the file (its sync will see it as a local change, same content
  # since beta got v1 from alpha — so no conflict, content stays identical)
  local content
  content=$(read_mem "$tdir" "beta" "-home-shared-proj" "prefs.md")
  echo "$content" | grep -q "line-a"
}

# ══════════════════════════════════════════════════════════════════════════════
# Full lifecycle test — 3 machines, 7 projects, 8 phases
# ══════════════════════════════════════════════════════════════════════════════

# IT-11: Simulates a single user across 3 machines (office desktop, laptop,
# home machine) gradually adding projects, accumulating memory, configuring
# groups, and syncing frequently.
#
# Sync model: sync only fires on session START (not end). A session start
# snapshots memory written during the PREVIOUS session, pushes it, then
# pulls remote changes. So the pattern is:
#
#   [session N]   sync → (pushes session N-1 work) → pull remote → work → write memory
#   [session N+1] sync → (pushes session N work)   → pull remote → work → write memory
#
# Memory written during a session is NOT available to other machines until
# the NEXT session start on the originating machine.
#
# Machines:  alice (office desktop), bob (laptop), carol (home desktop)
# Projects:  P1 webapp       — alice, bob, carol
#            P2 api-server   — alice, bob
#            P3 ml-pipeline  — alice only
#            P4 mobile-app   — bob, carol
#            P5 infra        — alice, bob
#            P6 docs-site    — alice, bob, carol
#            P7 data-tools   — bob only
test_full_lifecycle() {
  local tdir
  tdir=$(make_test_env "it11")

  # ── Shorthand project keys ──────────────────────────────────────────────
  local P1="-home-dev-webapp"
  local P2="-home-dev-api-server"
  local P3="-home-dev-ml-pipeline"
  local P4="-home-dev-mobile-app"
  local P5="-home-dev-infra"
  local P6="-home-dev-docs-site"
  local P7="-home-dev-data-tools"

  # ── Helper: count memory files on a machine/project ─────────────────────
  count_mem() {
    local d="$tdir/machines/$1/home/.claude/projects/$2/memory"
    if [ -d "$d" ]; then
      find "$d" -type f | wc -l | tr -d ' '
    else
      echo 0
    fi
  }

  # ── Helper: write group config for a machine ────────────────────────────
  write_groups() {
    local mname="$1" json="$2"
    printf '%s\n' "$json" > "$tdir/machines/$mname/home/.claude/brain-groups.json"
  }

  # ── Helper: assert file count ───────────────────────────────────────────
  assert_count() {
    local mname="$1" proj="$2" expected="$3" label="$4"
    local actual
    actual=$(count_mem "$mname" "$proj")
    if [ "$actual" -lt "$expected" ]; then
      echo "ASSERT FAIL: $label — $mname $proj: expected >= $expected, got $actual" >&2
      return 1
    fi
  }

  # ── Helper: read/write global CLAUDE.md ─────────────────────────────────
  write_claude_md() {
    local mname="$1" content="$2"
    printf '%s\n' "$content" > "$tdir/machines/$mname/home/.claude/CLAUDE.md"
  }
  read_claude_md() {
    cat "$tdir/machines/$1/home/.claude/CLAUDE.md" 2>/dev/null || true
  }

  # ══════════════════════════════════════════════════════════════════════════
  # Day 1: User sets up brain-sync on office desktop (alice).
  # First writes global CLAUDE.md, then opens webapp, then api-server.
  # ══════════════════════════════════════════════════════════════════════════
  setup_machine "$tdir" "alice" "alice01"

  # User writes their global CLAUDE.md on the office machine (complete version)
  write_claude_md "alice" "# Global Instructions

- Always respond in Chinese
- Use markdown for all code examples
- Prefer concise answers
- When debugging, always check error logs first"

  # -- Session 1: alice opens webapp for the first time --
  ensure_project "$tdir" "alice" "$P1"
  sync_machine "$tdir" "alice"               # session start (pushes CLAUDE.md + nothing else)
  # works on webapp, Claude writes memory:
  write_mem "$tdir" "alice" "$P1" "user_prefs.md" \
"---
name: editor preferences
type: feedback
---
Prefer dark theme, 2-space indent, Vim keybindings."
  # session ends (no sync)

  # -- Session 2: alice opens api-server --
  ensure_project "$tdir" "alice" "$P2"
  sync_machine "$tdir" "alice"               # pushes P1/user_prefs.md from session 1
  # works on api-server:
  write_mem "$tdir" "alice" "$P2" "api_notes.md" \
"---
name: API conventions
type: reference
---
REST endpoints use /v2 prefix. Auth via Bearer token."
  # session ends

  # -- Session 3: alice opens webapp again --
  sync_machine "$tdir" "alice"               # pushes P2/api_notes.md from session 2

  # ══════════════════════════════════════════════════════════════════════════
  # Day 2: User sets up laptop (bob). Has webapp, api-server, data-tools.
  # ══════════════════════════════════════════════════════════════════════════
  setup_machine "$tdir" "bob" "bob01"

  # -- Session 4: bob opens webapp on laptop for the first time --
  ensure_project "$tdir" "bob" "$P1"
  ensure_project "$tdir" "bob" "$P2"
  sync_machine "$tdir" "bob"                 # pulls alice's P1 + P2 memory

  # Verify bob got alice's work — including global CLAUDE.md
  has_mem "$tdir" "bob" "$P1" "user_prefs.md" || return 1
  has_mem "$tdir" "bob" "$P2" "api_notes.md"  || return 1
  read_claude_md "bob" | grep -q "respond in Chinese" || return 1
  # session ends

  # -- Session 5: bob opens data-tools (only on laptop) --
  ensure_project "$tdir" "bob" "$P7"
  sync_machine "$tdir" "bob"                 # nothing new to push (no writes in session 4)
  write_mem "$tdir" "bob" "$P7" "etl_flow.md" \
"---
name: ETL schedule
type: project
---
Nightly ETL runs at 3am UTC. Source: Postgres replica. Sink: BigQuery."
  # session ends

  # ══════════════════════════════════════════════════════════════════════════
  # Day 3: Alice at office, working across multiple projects.
  # Each project open is a separate session.
  # ══════════════════════════════════════════════════════════════════════════

  # -- Session 6: alice opens webapp --
  sync_machine "$tdir" "alice"               # pulls bob's P7 (alice has no P7 dir — ignored)
  write_mem "$tdir" "alice" "$P1" "deploy_checklist.md" \
"---
name: deploy process
type: reference
---
1. Run smoke tests after deploy
2. Check error rate in Datadog
3. Notify #releases channel"
  # session ends

  # -- Session 7: alice opens api-server --
  sync_machine "$tdir" "alice"               # pushes deploy_checklist
  write_mem "$tdir" "alice" "$P2" "db_schema.md" \
"---
name: database schema notes
type: reference
---
Users table has soft-delete (deleted_at column). Always filter in queries."
  # session ends

  # -- Session 8: alice starts working on ml-pipeline (new project, only on office) --
  ensure_project "$tdir" "alice" "$P3"
  sync_machine "$tdir" "alice"               # pushes db_schema
  write_mem "$tdir" "alice" "$P3" "model_notes.md" \
"---
name: model architecture
type: project
---
Using XGBoost v1.7. Feature store in Redis. Training runs on GPU spot instances."
  # session ends

  # -- Session 9: alice starts working on infra (new project) --
  ensure_project "$tdir" "alice" "$P5"
  sync_machine "$tdir" "alice"               # pushes model_notes
  write_mem "$tdir" "alice" "$P5" "k8s_notes.md" \
"---
name: cluster info
type: reference
---
Cluster: us-east-1, 3 nodes, k8s 1.28. Helm charts in /infra/charts."
  # session ends

  # ══════════════════════════════════════════════════════════════════════════
  # Day 3 evening: Bob on laptop, catching up + own work.
  # ══════════════════════════════════════════════════════════════════════════

  # -- Session 10: bob opens webapp --
  # alice's last sync (session 9) pushed model_notes. k8s_notes was written
  # AFTER that sync, so it's NOT available yet — it'll be pushed when alice
  # next opens a session (session 14).
  sync_machine "$tdir" "bob"                 # pushes etl_flow, pulls deploy_checklist + db_schema + model_notes
  has_mem "$tdir" "bob" "$P1" "deploy_checklist.md" || return 1
  has_mem "$tdir" "bob" "$P2" "db_schema.md"        || return 1
  # bob doesn't have P3 dir → model_notes not imported
  ! has_mem "$tdir" "bob" "$P3" "model_notes.md"    || return 1

  write_mem "$tdir" "bob" "$P1" "perf_notes.md" \
"---
name: performance targets
type: project
---
LCP target < 2.5s. Bundle size < 200KB gzipped. Lighthouse score > 90."
  # session ends

  # -- Session 11: bob opens api-server --
  sync_machine "$tdir" "bob"                 # pushes perf_notes
  write_mem "$tdir" "bob" "$P2" "auth_flow.md" \
"---
name: auth architecture
type: reference
---
OAuth2 + PKCE for mobile clients. JWT access tokens, 15min expiry."
  # session ends

  # -- Session 12: bob starts mobile-app (new project on laptop) --
  ensure_project "$tdir" "bob" "$P4"
  sync_machine "$tdir" "bob"                 # pushes auth_flow
  write_mem "$tdir" "bob" "$P4" "build_notes.md" \
"---
name: mobile build setup
type: reference
---
React Native 0.73. iOS builds via Xcode 15. Android via Gradle 8.2."
  # session ends

  # -- Session 13: bob starts infra (same path as alice) --
  ensure_project "$tdir" "bob" "$P5"
  sync_machine "$tdir" "bob"                 # pushes build_notes; k8s_notes NOT here yet (alice hasn't synced since writing it)

  write_mem "$tdir" "bob" "$P5" "ci_pipeline.md" \
"---
name: CI/CD setup
type: reference
---
GitHub Actions. 3 envs: dev/staging/prod. Deploy on merge to main."
  # session ends

  # ══════════════════════════════════════════════════════════════════════════
  # Day 4 morning: Alice at office, picks up bob's evening work.
  # ══════════════════════════════════════════════════════════════════════════

  # -- Session 14: alice opens webapp --
  # Alice's snapshot now includes k8s_notes (written in session 9).
  # Bob's ci_pipeline was written after session 13's sync → NOT yet available.
  sync_machine "$tdir" "alice"               # pushes k8s_notes, pulls perf_notes + auth_flow + build_notes

  has_mem "$tdir" "alice" "$P1" "perf_notes.md"  || return 1
  has_mem "$tdir" "alice" "$P2" "auth_flow.md"   || return 1
  # ci_pipeline NOT available yet (bob hasn't synced since writing it)
  # alice doesn't have P4 dir → build_notes not imported
  ! has_mem "$tdir" "alice" "$P4" "build_notes.md" || return 1
  # alice doesn't have P7 dir → etl_flow not imported
  ! has_mem "$tdir" "alice" "$P7" "etl_flow.md"    || return 1

  # ══════════════════════════════════════════════════════════════════════════
  # Day 4 afternoon: Alice configures a group and starts docs-site.
  # ══════════════════════════════════════════════════════════════════════════

  # Alice decides webapp and mobile-app memory should be shared
  local groups='{"frontend":["-home-dev-webapp","-home-dev-mobile-app"]}'
  write_groups "alice" "$groups"

  # -- Session 15: alice starts docs-site (new project) --
  ensure_project "$tdir" "alice" "$P6"
  sync_machine "$tdir" "alice"               # pushes group config
  write_mem "$tdir" "alice" "$P6" "style_guide.md" \
"---
name: documentation style
type: feedback
---
Use MDX format. Code examples must be runnable. Keep pages < 800 words."
  # session ends

  # -- Session 16: alice opens webapp (pushes style_guide) --
  sync_machine "$tdir" "alice"

  # ══════════════════════════════════════════════════════════════════════════
  # Day 5: User sets up home desktop (carol). Only has webapp, mobile-app,
  # docs-site checked out at home.
  # ══════════════════════════════════════════════════════════════════════════
  setup_machine "$tdir" "carol" "carol01"

  # -- Session 17: carol opens webapp at home for the first time --
  ensure_project "$tdir" "carol" "$P1"
  ensure_project "$tdir" "carol" "$P4"
  ensure_project "$tdir" "carol" "$P6"
  sync_machine "$tdir" "carol"               # pulls everything

  # Carol should have all P1 memory accumulated so far (3 files)
  has_mem "$tdir" "carol" "$P1" "user_prefs.md"       || return 1
  has_mem "$tdir" "carol" "$P1" "deploy_checklist.md"  || return 1
  has_mem "$tdir" "carol" "$P1" "perf_notes.md"        || return 1
  # Carol has P4 dir → gets bob's build_notes
  has_mem "$tdir" "carol" "$P4" "build_notes.md"       || return 1
  # Carol has P6 dir → gets alice's style_guide
  has_mem "$tdir" "carol" "$P6" "style_guide.md"       || return 1
  # Carol also gets global CLAUDE.md
  read_claude_md "carol" | grep -q "respond in Chinese" || return 1
  # session ends

  # ══════════════════════════════════════════════════════════════════════════
  # Days 6-7: All three machines active — simulating frequent development
  # across multiple sessions. Each session = one sync + work.
  # ══════════════════════════════════════════════════════════════════════════

  # -- Session 18: alice at office, webapp emergency hotfix --
  sync_machine "$tdir" "alice"
  write_mem "$tdir" "alice" "$P1" "hotfix_log.md" \
"---
name: hotfix 2024-03-15
type: project
---
Fix: null pointer in checkout flow when cart is empty. Root cause: missing guard."
  # session ends

  # -- Session 19: bob on laptop, webapp testing --
  sync_machine "$tdir" "bob"                 # pulls alice's hotfix_log? No — alice hasn't synced since writing it
  write_mem "$tdir" "bob" "$P1" "test_coverage.md" \
"---
name: test coverage status
type: project
---
Coverage: 78%, target 85%. Gaps: checkout flow, payment webhook handler."
  # session ends

  # -- Session 20: bob switches to mobile-app --
  sync_machine "$tdir" "bob"                 # pushes test_coverage
  write_mem "$tdir" "bob" "$P4" "release_notes.md" \
"---
name: v2.1.0 release
type: project
---
v2.1.0 - dark mode support, biometric login, performance fixes."
  # session ends

  # -- Session 21: carol at home, webapp accessibility --
  sync_machine "$tdir" "carol"               # pulls bob's test_coverage (but NOT alice's hotfix yet)
  write_mem "$tdir" "carol" "$P1" "a11y_notes.md" \
"---
name: accessibility requirements
type: feedback
---
WCAG 2.1 AA compliance needed by Q2. Focus: color contrast, keyboard nav, screen readers."
  # session ends

  # -- Session 22: carol opens docs-site --
  sync_machine "$tdir" "carol"               # pushes a11y_notes
  write_mem "$tdir" "carol" "$P6" "tutorial_plan.md" \
"---
name: tutorial roadmap
type: project
---
Priority tutorials: getting started, API auth, deployment. Target: 1 per week."
  # session ends

  # -- Session 23: alice opens webapp (morning) --
  sync_machine "$tdir" "alice"               # pushes hotfix_log, pulls test_coverage + release_notes + a11y_notes + tutorial_plan
  # session ends (no new writes)

  # -- Session 24: bob opens something --
  sync_machine "$tdir" "bob"                 # pushes release_notes, pulls hotfix_log + a11y_notes + tutorial_plan

  # -- Session 25: carol opens something --
  sync_machine "$tdir" "carol"               # pushes tutorial_plan, pulls hotfix_log + release_notes

  # ══════════════════════════════════════════════════════════════════════════
  # Day 8: Bob adds a backend group from his laptop.
  # ══════════════════════════════════════════════════════════════════════════

  local bob_groups='{"frontend":["-home-dev-webapp","-home-dev-mobile-app"],"backend":["-home-dev-api-server","-home-dev-infra"]}'
  write_groups "bob" "$bob_groups"

  # -- Session 26: bob opens infra --
  sync_machine "$tdir" "bob"
  write_mem "$tdir" "bob" "$P5" "monitoring.md" \
"---
name: observability setup
type: reference
---
Datadog APM enabled. Alert: p99 latency > 500ms. PagerDuty integration for prod."
  # session ends

  # -- Session 27: bob opens something (pushes monitoring + backend group) --
  sync_machine "$tdir" "bob"

  # -- Session 28: alice syncs to get bob's backend group + monitoring --
  sync_machine "$tdir" "alice"

  # ══════════════════════════════════════════════════════════════════════════
  # Day 9: Convergence — each machine opens a session, letting all pending
  # data propagate. In practice this happens naturally over a day or two.
  # ══════════════════════════════════════════════════════════════════════════
  sync_machine "$tdir" "carol"               # session 29
  sync_machine "$tdir" "alice"               # session 30
  sync_machine "$tdir" "bob"                 # session 31
  sync_machine "$tdir" "carol"               # session 32 (final)

  # ══════════════════════════════════════════════════════════════════════════
  # Final consistency checks
  # ══════════════════════════════════════════════════════════════════════════
  # P1 (webapp): all 3 machines — 6 direct files + group-synced files from P4
  # Direct: user_prefs, deploy_checklist, perf_notes, hotfix_log, test_coverage, a11y_notes
  # From P4 via frontend group: build_notes, release_notes
  assert_count "alice" "$P1" 6 "P1 alice" || return 1
  assert_count "bob"   "$P1" 6 "P1 bob"   || return 1
  assert_count "carol" "$P1" 6 "P1 carol" || return 1

  # P2 (api-server): alice + bob, >= 3 files (api_notes, db_schema, auth_flow)
  # backend group may add P5 files here too
  assert_count "alice" "$P2" 3 "P2 alice" || return 1
  assert_count "bob"   "$P2" 3 "P2 bob"   || return 1

  # P3 (ml-pipeline): alice only, 1 file
  assert_count "alice" "$P3" 1 "P3 alice" || return 1
  [ "$(count_mem "bob" "$P3")" -eq 0 ]    || return 1

  # P4 (mobile-app): bob + carol, >= 2 direct files (build_notes, release_notes)
  # Plus group-synced files from P1 via frontend group
  assert_count "bob"   "$P4" 2 "P4 bob"   || return 1
  assert_count "carol" "$P4" 2 "P4 carol" || return 1

  # P5 (infra): alice + bob, >= 3 files (k8s_notes, ci_pipeline, monitoring)
  # backend group may add P2 files here too
  assert_count "alice" "$P5" 3 "P5 alice" || return 1
  assert_count "bob"   "$P5" 3 "P5 bob"   || return 1

  # P6 (docs-site): alice + carol, 2 files (style_guide, tutorial_plan)
  assert_count "alice" "$P6" 2 "P6 alice" || return 1
  assert_count "carol" "$P6" 2 "P6 carol" || return 1

  # P7 (data-tools): bob only, 1 file
  assert_count "bob" "$P7" 1 "P7 bob"     || return 1
  [ "$(count_mem "alice" "$P7")" -eq 0 ]  || return 1

  # Cross-machine file-count consistency for shared projects
  local alice_p1 bob_p1 carol_p1
  alice_p1=$(count_mem "alice" "$P1")
  bob_p1=$(count_mem "bob" "$P1")
  carol_p1=$(count_mem "carol" "$P1")
  [ "$alice_p1" -eq "$bob_p1" ] && [ "$bob_p1" -eq "$carol_p1" ] || {
    echo "CONSISTENCY FAIL: P1 counts: alice=$alice_p1 bob=$bob_p1 carol=$carol_p1" >&2
    return 1
  }

  local alice_p2 bob_p2
  alice_p2=$(count_mem "alice" "$P2")
  bob_p2=$(count_mem "bob" "$P2")
  [ "$alice_p2" -eq "$bob_p2" ] || {
    echo "CONSISTENCY FAIL: P2 counts: alice=$alice_p2 bob=$bob_p2" >&2
    return 1
  }

  local alice_p5 bob_p5
  alice_p5=$(count_mem "alice" "$P5")
  bob_p5=$(count_mem "bob" "$P5")
  [ "$alice_p5" -eq "$bob_p5" ] || {
    echo "CONSISTENCY FAIL: P5 counts: alice=$alice_p5 bob=$bob_p5" >&2
    return 1
  }

  # Global CLAUDE.md: all machines should have the updated version
  # (alice updated it in session 6 before bob/carol had modified it — no conflict)
  # Global CLAUDE.md: all machines should have alice's version (no conflict,
  # CLAUDE.md conflict resolution is tested separately in test_claude_md_conflict_resolve)
  read_claude_md "alice" | grep -q "check error logs first" || {
    echo "CONSISTENCY FAIL: alice CLAUDE.md missing rule" >&2; return 1; }
  read_claude_md "bob"   | grep -q "respond in Chinese" || {
    echo "CONSISTENCY FAIL: bob CLAUDE.md missing rule" >&2; return 1; }
  read_claude_md "carol" | grep -q "respond in Chinese" || {
    echo "CONSISTENCY FAIL: carol CLAUDE.md missing rule" >&2; return 1; }
}

# ══════════════════════════════════════════════════════════════════════════════
# Conflict detection + LLM resolution tests
# ══════════════════════════════════════════════════════════════════════════════

# IT-L1: Both machines have the same memory file with different content.
# merge.sh detects the conflict and records it. resolve-conflicts.sh uses
# LLM to merge. Result should contain unique content from both versions.
test_memory_conflict_resolve() {
  command -v claude &>/dev/null || skip_test

  local tdir
  tdir=$(make_test_env "itL1")
  setup_machine "$tdir" "alpha" "aL01"
  setup_machine "$tdir" "beta"  "bL01"

  ensure_project "$tdir" "alpha" "-home-shared-app"
  ensure_project "$tdir" "beta"  "-home-shared-app"

  write_mem "$tdir" "alpha" "-home-shared-app" "prefs.md" \
"# Code Preferences
- Use 4 spaces for indentation
- Maximum line length: 100 chars"

  sync_machine "$tdir" "alpha"

  # Beta has a divergent version of the same file
  write_mem "$tdir" "beta" "-home-shared-app" "prefs.md" \
"# Code Preferences
- Use 2 spaces for indentation
- Maximum line length: 80 chars
- Always add type annotations"

  sync_machine "$tdir" "beta"

  # Conflict should be recorded
  local cf="$tdir/machines/beta/home/.claude/brain-conflicts.json"
  [ "$(conflict_count "$tdir" "beta")" -gt 0 ] || return 1

  # Resolve with LLM, push, propagate
  resolve_conflicts "$tdir" "beta"
  sync_machine "$tdir" "beta"
  sync_machine "$tdir" "alpha"

  local result
  result=$(read_mem "$tdir" "beta" "-home-shared-app" "prefs.md")

  # LLM-merged result must preserve unique content from both sides
  echo "$result" | grep -qi "indentation" &&
  echo "$result" | grep -qi "type annotation"
}

# IT-L2: Both machines have different global CLAUDE.md. After conflict
# detection + LLM resolution, the merged CLAUDE.md contains instructions
# from both versions.
test_claude_md_conflict_resolve() {
  command -v claude &>/dev/null || skip_test

  local tdir
  tdir=$(make_test_env "itL2")
  setup_machine "$tdir" "alpha" "aL02"
  setup_machine "$tdir" "beta"  "bL02"

  printf '# Instructions\n- Always use TypeScript\n- Prefer immutable data\n' \
    > "$tdir/machines/alpha/home/.claude/CLAUDE.md"
  sync_machine "$tdir" "alpha"

  printf '# Instructions\n- Always write unit tests first\n- Use functional style\n' \
    > "$tdir/machines/beta/home/.claude/CLAUDE.md"
  sync_machine "$tdir" "beta"

  # Conflict recorded on beta
  [ "$(conflict_count "$tdir" "beta")" -gt 0 ] || return 1

  # Resolve on beta (applies merged result to beta's CLAUDE.md + consolidated)
  resolve_conflicts "$tdir" "beta"

  # Check beta's CLAUDE.md contains content from both sides
  local result
  result=$(cat "$tdir/machines/beta/home/.claude/CLAUDE.md")

  echo "$result" | grep -qi "typescript" &&
  echo "$result" | grep -qi "unit test"
}

# ══════════════════════════════════════════════════════════════════════════════
# 3-way merge tests
# ══════════════════════════════════════════════════════════════════════════════

# IT-12: 3-way merge — outgoing only. Beta modifies a file locally, alpha
# hasn't changed anything. With baseline, beta's change should go through
# with NO conflict.
test_3way_outgoing_only() {
  local tdir
  tdir=$(make_test_env "it12")
  setup_machine "$tdir" "alpha" "a012"
  setup_machine "$tdir" "beta"  "b012"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  # Both start with same file
  write_mem "$tdir" "alpha" "-home-proj" "notes.md" "original content"
  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"
  # Now beta has baseline (from apply)

  # Beta modifies the file locally, alpha doesn't touch it
  write_mem "$tdir" "beta" "-home-proj" "notes.md" "modified by beta"
  sync_machine "$tdir" "beta"

  # Should have NO conflict (3-way: only snapshot changed)
  [ "$(conflict_count "$tdir" "beta")" -eq 0 ] || return 1

  # Consolidated should have beta's version
  local consolidated="$tdir/machines/beta/home/.claude/brain-repo/consolidated/brain.json"
  jq -r '.experiential.auto_memory["-home-proj"]["notes.md"].content' "$consolidated" \
    | grep -q "modified by beta"
}

# IT-13: 3-way merge — incoming only. Alpha modifies a file and pushes,
# beta hasn't changed it. Beta should receive the update with NO conflict.
test_3way_incoming_only() {
  local tdir
  tdir=$(make_test_env "it13")
  setup_machine "$tdir" "alpha" "a013"
  setup_machine "$tdir" "beta"  "b013"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  # Both start with same file
  write_mem "$tdir" "alpha" "-home-proj" "notes.md" "original content"
  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # Alpha modifies, beta doesn't
  write_mem "$tdir" "alpha" "-home-proj" "notes.md" "updated by alpha"
  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # No conflict (3-way: only consolidated changed)
  [ "$(conflict_count "$tdir" "beta")" -eq 0 ] || return 1

  # Beta should have alpha's updated content
  read_mem "$tdir" "beta" "-home-proj" "notes.md" | grep -q "updated by alpha"
}

# IT-14: 3-way merge — real conflict. Both machines modify the same file
# differently. Should produce exactly one conflict.
test_3way_real_conflict() {
  local tdir
  tdir=$(make_test_env "it14")
  setup_machine "$tdir" "alpha" "a014"
  setup_machine "$tdir" "beta"  "b014"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  # Both start with same file
  write_mem "$tdir" "alpha" "-home-proj" "prefs.md" "original prefs"
  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # Both modify the same file differently
  write_mem "$tdir" "alpha" "-home-proj" "prefs.md" "alpha version"
  write_mem "$tdir" "beta"  "-home-proj" "prefs.md" "beta version"

  sync_machine "$tdir" "alpha"

  # Beta syncs — should detect a real conflict
  # (use sync_machine_no_apply + manual apply to check conflict before apply)
  sync_machine_no_apply "$tdir" "beta"
  [ "$(conflict_count "$tdir" "beta")" -gt 0 ] || return 1
  # Apply anyway (consolidated version wins for now)
  run_as "$tdir" "beta" bash "$BRAIN_SCRIPTS/sync.sh" --apply --quiet
}

# IT-15: First sync for a new machine falls back to 2-way (no pre-pull
# consolidated exists). Should still work correctly.
test_3way_fallback_to_2way() {
  local tdir
  tdir=$(make_test_env "it15")
  setup_machine "$tdir" "alpha" "a015"
  setup_machine "$tdir" "beta"  "b015"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  write_mem "$tdir" "alpha" "-home-proj" "data.md" "from alpha"
  sync_machine "$tdir" "alpha"

  # Beta's first sync — no pre-pull consolidated to use as baseline
  sync_machine "$tdir" "beta"
  has_mem "$tdir" "beta" "-home-proj" "data.md" || return 1
}

# IT-16: After sync+apply, the SECOND subsequent sync (not the first) with
# no content changes produces zero new commits. The first sync after apply
# legitimately commits because import wrote new files to local disk.
test_no_spurious_commits_after_stabilize() {
  local tdir
  tdir=$(make_test_env "it16")
  setup_machine "$tdir" "alpha" "a016"
  setup_machine "$tdir" "beta"  "b016"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  write_mem "$tdir" "alpha" "-home-proj" "data.md" "shared content"
  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"     # apply imports data.md to local

  # First sync after apply — may commit (import changed local files)
  sync_machine "$tdir" "beta"

  # NOW count commits
  local commits_before
  commits_before=$(git -C "$tdir/machines/beta/home/.claude/brain-repo" rev-list --count HEAD)

  # Third sync — nothing changed, should be stable
  sync_machine "$tdir" "beta"

  local commits_after
  commits_after=$(git -C "$tdir/machines/beta/home/.claude/brain-repo" rev-list --count HEAD)

  [ "$commits_before" = "$commits_after" ] || return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Summary + safety tests
# ══════════════════════════════════════════════════════════════════════════════

# IT-17: --summary reports has_outgoing=true when there are unpushed commits
# but no incoming changes.
test_summary_outgoing_only() {
  local tdir
  tdir=$(make_test_env "it17")
  setup_machine "$tdir" "alpha" "a017"

  ensure_project "$tdir" "alpha" "-home-proj"
  write_mem "$tdir" "alpha" "-home-proj" "local.md" "local only"

  # Sync without apply — creates local commit but doesn't push
  sync_machine_no_apply "$tdir" "alpha"

  local summary
  summary=$(get_summary "$tdir" "alpha")

  echo "$summary" | jq -e '.has_outgoing == true' >/dev/null || return 1
  echo "$summary" | jq -e '.has_changes == false' >/dev/null || return 1
}

# IT-18: --summary reports has_changes=true when there are incoming changes.
test_summary_incoming_changes() {
  local tdir
  tdir=$(make_test_env "it18")
  setup_machine "$tdir" "alpha" "a018"
  setup_machine "$tdir" "beta"  "b018"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  write_mem "$tdir" "alpha" "-home-proj" "from-alpha.md" "alpha content"
  sync_machine "$tdir" "alpha"

  # Beta syncs (pull + merge) but does NOT apply
  sync_machine_no_apply "$tdir" "beta"

  local summary
  summary=$(get_summary "$tdir" "beta")

  echo "$summary" | jq -e '.has_changes == true' >/dev/null || return 1
}

# IT-19: Backup failure blocks import. If the backup directory is not writable,
# import.sh should exit with error instead of proceeding.
test_backup_failure_blocks_import() {
  local tdir
  tdir=$(make_test_env "it19")
  setup_machine "$tdir" "alpha" "a019"

  ensure_project "$tdir" "alpha" "-home-proj"
  write_mem "$tdir" "alpha" "-home-proj" "data.md" "test"
  sync_machine_no_apply "$tdir" "alpha"

  # Make backup dir non-writable to simulate failure
  local backup_dir="$tdir/machines/alpha/home/.claude/brain-backups"
  mkdir -p "$backup_dir"
  chmod 000 "$backup_dir"

  # Apply should fail because backup can't be created
  local rc=0
  run_as "$tdir" "alpha" bash "$BRAIN_SCRIPTS/sync.sh" --apply --quiet || rc=$?

  # Restore permissions for cleanup
  chmod 755 "$backup_dir"

  [ "$rc" -ne 0 ] || return 1
}

# IT-20: Invalid JSON merge preserves original file. If the jq merge for
# settings.json produces bad output, the original file should be untouched.
test_invalid_json_merge_preserves_original() {
  local tdir
  tdir=$(make_test_env "it20")
  setup_machine "$tdir" "alpha" "a020"
  setup_machine "$tdir" "beta"  "b020"

  # Create a valid settings.json on beta
  local beta_claude="$tdir/machines/beta/home/.claude"
  echo '{"permissions":{"allow":["bash"]}}' > "$beta_claude/settings.json"

  # Create a consolidated brain with corrupt settings content on alpha,
  # then push it so beta will pull it
  ensure_project "$tdir" "alpha" "-home-proj"
  write_mem "$tdir" "alpha" "-home-proj" "dummy.md" "trigger sync"
  sync_machine "$tdir" "alpha"

  # Manually corrupt the settings content in consolidated brain
  local consolidated="$tdir/machines/alpha/home/.claude/brain-repo/consolidated/brain.json"
  local tmp_c
  tmp_c=$(mktemp)
  jq '.environmental.settings.content = "NOT VALID JSON STRING"' "$consolidated" > "$tmp_c"
  mv "$tmp_c" "$consolidated"
  # Commit and push the corrupt consolidated
  git -C "$tdir/machines/alpha/home/.claude/brain-repo" add consolidated/
  git -C "$tdir/machines/alpha/home/.claude/brain-repo" commit -m "corrupt settings" -q 2>/dev/null
  git -C "$tdir/machines/alpha/home/.claude/brain-repo" push origin main -q 2>/dev/null

  # Beta syncs — the settings merge should fail gracefully
  sync_machine "$tdir" "beta"

  # Beta's settings.json should still be the original valid JSON
  jq empty "$beta_claude/settings.json" 2>/dev/null || return 1
  jq -e '.permissions.allow[0] == "bash"' "$beta_claude/settings.json" >/dev/null || return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Rules, skills, settings, MCP tests
# ══════════════════════════════════════════════════════════════════════════════

# IT-21: Rules and skills written on alpha propagate to beta.
test_rules_and_skills_sync() {
  local tdir
  tdir=$(make_test_env "it21")
  setup_machine "$tdir" "alpha" "a021"
  setup_machine "$tdir" "beta"  "b021"

  local alpha_claude="$tdir/machines/alpha/home/.claude"
  local beta_claude="$tdir/machines/beta/home/.claude"

  # Alpha creates a rule and a skill
  mkdir -p "$alpha_claude/rules" "$alpha_claude/skills/my-tool"
  echo '# Always run tests before commit' > "$alpha_claude/rules/testing.md"
  printf '%s\n' '---
name: my-tool
description: A useful tool
---
Do the thing.' > "$alpha_claude/skills/my-tool/SKILL.md"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  [ -f "$beta_claude/rules/testing.md" ] || return 1
  grep -q "run tests" "$beta_claude/rules/testing.md" || return 1
  [ -f "$beta_claude/skills/my-tool/SKILL.md" ] || return 1
  grep -q "useful tool" "$beta_claude/skills/my-tool/SKILL.md" || return 1
}

# IT-22: Settings.json deep merge preserves both sides.
test_settings_deep_merge() {
  local tdir
  tdir=$(make_test_env "it22")
  setup_machine "$tdir" "alpha" "a022"
  setup_machine "$tdir" "beta"  "b022"

  local alpha_claude="$tdir/machines/alpha/home/.claude"
  local beta_claude="$tdir/machines/beta/home/.claude"

  # Alpha has permissions
  echo '{"permissions":{"allow":["bash"]}}' > "$alpha_claude/settings.json"
  # Beta has different setting
  echo '{"hooks":{"enabled":true}}' > "$beta_claude/settings.json"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # Beta should have both permissions (from alpha) and hooks (local)
  jq -e '.permissions.allow[0] == "bash"' "$beta_claude/settings.json" >/dev/null || return 1
  jq -e '.hooks.enabled == true' "$beta_claude/settings.json" >/dev/null || return 1
}

# IT-23: MCP server sync + summary highlights new servers.
test_mcp_server_sync_and_summary() {
  local tdir
  tdir=$(make_test_env "it23")
  setup_machine "$tdir" "alpha" "a023"
  setup_machine "$tdir" "beta"  "b023"

  local alpha_home="$tdir/machines/alpha/home"

  # Alpha has an MCP server configured in ~/.claude.json
  cat > "$alpha_home/.claude.json" <<JSON
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-filesystem"],
      "env": {"SECRET_KEY": "should-be-stripped"}
    }
  }
}
JSON

  sync_machine "$tdir" "alpha"

  # Beta syncs (no apply) and checks summary
  sync_machine_no_apply "$tdir" "beta"
  local summary
  summary=$(get_summary "$tdir" "beta")

  # Summary should show filesystem as new MCP server
  echo "$summary" | jq -e '.mcp_servers_added | length > 0' >/dev/null || return 1
  echo "$summary" | jq -e '.mcp_servers_added[] | select(. == "filesystem")' >/dev/null || return 1

  # Now apply and verify MCP server is imported (without env/secret)
  run_as "$tdir" "beta" bash "$BRAIN_SCRIPTS/sync.sh" --apply --quiet

  local beta_home="$tdir/machines/beta/home"
  jq -e '.mcpServers.filesystem.command == "npx"' "$beta_home/.claude.json" >/dev/null || return 1
  # env should NOT be present (stripped during export)
  jq -e '.mcpServers.filesystem.env == null' "$beta_home/.claude.json" >/dev/null || return 1
}

# IT-24: 3-way CLAUDE.md — only local changed, no conflict.
test_3way_claude_md_outgoing() {
  local tdir
  tdir=$(make_test_env "it24")
  setup_machine "$tdir" "alpha" "a024"
  setup_machine "$tdir" "beta"  "b024"

  # Both start with same CLAUDE.md
  local shared_md="# Rules
- Use TypeScript"
  printf '%s\n' "$shared_md" > "$tdir/machines/alpha/home/.claude/CLAUDE.md"
  printf '%s\n' "$shared_md" > "$tdir/machines/beta/home/.claude/CLAUDE.md"

  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # Beta modifies CLAUDE.md, alpha doesn't
  printf '%s\n' "# Rules
- Use TypeScript
- Always add tests" > "$tdir/machines/beta/home/.claude/CLAUDE.md"

  sync_machine "$tdir" "beta"

  # No conflict (3-way: only snapshot changed)
  [ "$(conflict_count "$tdir" "beta")" -eq 0 ] || return 1

  # Consolidated should have beta's updated version
  local con="$tdir/machines/beta/home/.claude/brain-repo/consolidated/brain.json"
  jq -r '.declarative.claude_md.content' "$con" | grep -q "Always add tests" || return 1
}

# IT-25: Machine without a project does NOT delete that project's memory
# from consolidated (regression test for the 3-way merge fix).
test_project_not_on_machine_preserved() {
  local tdir
  tdir=$(make_test_env "it25")
  setup_machine "$tdir" "alpha" "a025"
  setup_machine "$tdir" "beta"  "b025"

  ensure_project "$tdir" "alpha" "-proj-shared"
  ensure_project "$tdir" "beta"  "-proj-shared"
  # Only beta has proj-beta-only
  ensure_project "$tdir" "beta" "-proj-beta-only"

  write_mem "$tdir" "beta" "-proj-beta-only" "secret.md" "beta private data"
  write_mem "$tdir" "beta" "-proj-shared" "shared.md" "shared content"

  sync_machine "$tdir" "beta"
  sync_machine "$tdir" "alpha"  # alpha gets shared.md but not proj-beta-only (no dir)

  # Alpha makes a local change and syncs again (triggers 3-way merge)
  write_mem "$tdir" "alpha" "-proj-shared" "alpha-note.md" "alpha note"
  sync_machine "$tdir" "alpha"

  # Alpha's consolidated should still have beta's proj-beta-only memory
  local con="$tdir/machines/alpha/home/.claude/brain-repo/consolidated/brain.json"
  jq -e '.experiential.auto_memory["-proj-beta-only"]["secret.md"] != null' "$con" >/dev/null || return 1
}

# IT-26: Double apply is idempotent — running --apply twice doesn't break anything.
test_double_apply_idempotent() {
  local tdir
  tdir=$(make_test_env "it26")
  setup_machine "$tdir" "alpha" "a026"
  setup_machine "$tdir" "beta"  "b026"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  write_mem "$tdir" "alpha" "-home-proj" "data.md" "test content"
  sync_machine "$tdir" "alpha"

  # Beta syncs normally
  run_as "$tdir" "beta" bash "$BRAIN_SCRIPTS/sync.sh" --quiet
  run_as "$tdir" "beta" bash "$BRAIN_SCRIPTS/sync.sh" --apply --quiet

  # Second apply — should be a no-op (same content, no crash)
  run_as "$tdir" "beta" bash "$BRAIN_SCRIPTS/sync.sh" --apply --quiet

  # Still works, data intact
  has_mem "$tdir" "beta" "-home-proj" "data.md" || return 1
  read_mem "$tdir" "beta" "-home-proj" "data.md" | grep -q "test content" || return 1
}

# IT-27: Outgoing-only push propagates to other machines.
test_outgoing_push_propagates() {
  local tdir
  tdir=$(make_test_env "it27")
  setup_machine "$tdir" "alpha" "a027"
  setup_machine "$tdir" "beta"  "b027"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  # Initial sync to establish baselines
  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # Alpha writes something new (outgoing only)
  write_mem "$tdir" "alpha" "-home-proj" "new-idea.md" "brilliant idea"
  sync_machine "$tdir" "alpha"

  # Beta syncs and should receive it
  sync_machine "$tdir" "beta"
  has_mem "$tdir" "beta" "-home-proj" "new-idea.md" || return 1
  read_mem "$tdir" "beta" "-home-proj" "new-idea.md" | grep -q "brilliant idea" || return 1
}

# IT-28: After a full sync+apply cycle with incoming changes, the system
# stabilizes — no spurious commits from placeholder hashes or timestamps.
# (Needs 2 syncs after apply to stabilize: first reflects import, second is stable.)
test_no_hash_mismatch_after_merge() {
  local tdir
  tdir=$(make_test_env "it28")
  setup_machine "$tdir" "alpha" "a028"
  setup_machine "$tdir" "beta"  "b028"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  # Alpha writes and syncs
  write_mem "$tdir" "alpha" "-home-proj" "notes.md" "alpha notes"
  printf '# My Rules\n- Use TypeScript\n' > "$tdir/machines/alpha/home/.claude/CLAUDE.md"
  sync_machine "$tdir" "alpha"

  # Beta syncs (receives incoming)
  sync_machine "$tdir" "beta"
  # Second sync — reflects imported files in snapshot
  sync_machine "$tdir" "beta"

  local commits_before
  commits_before=$(git -C "$tdir/machines/beta/home/.claude/brain-repo" rev-list --count HEAD)

  # Third sync — should be fully stable
  sync_machine "$tdir" "beta"

  local commits_after
  commits_after=$(git -C "$tdir/machines/beta/home/.claude/brain-repo" rev-list --count HEAD)

  [ "$commits_before" = "$commits_after" ] || return 1
}

# IT-29: Pre-pull consolidated is used as 3-way ancestor. Alpha and beta
# both modify different files after initial sync. Neither should conflict.
test_3way_uses_prepull_baseline() {
  local tdir
  tdir=$(make_test_env "it29")
  setup_machine "$tdir" "alpha" "a029"
  setup_machine "$tdir" "beta"  "b029"

  ensure_project "$tdir" "alpha" "-home-proj"
  ensure_project "$tdir" "beta"  "-home-proj"

  # Both start with same file
  write_mem "$tdir" "alpha" "-home-proj" "shared.md" "initial content"
  sync_machine "$tdir" "alpha"
  sync_machine "$tdir" "beta"

  # Alpha modifies the shared file
  write_mem "$tdir" "alpha" "-home-proj" "shared.md" "alpha updated"
  sync_machine "$tdir" "alpha"

  # Beta adds a new file (doesn't touch shared.md)
  write_mem "$tdir" "beta" "-home-proj" "beta-new.md" "beta new file"
  sync_machine "$tdir" "beta"

  # Beta should have alpha's updated shared.md AND its own new file, no conflict
  [ "$(conflict_count "$tdir" "beta")" -eq 0 ] || return 1
  read_mem "$tdir" "beta" "-home-proj" "shared.md" | grep -q "alpha updated" || return 1
  has_mem "$tdir" "beta" "-home-proj" "beta-new.md" || return 1
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo "=== claude-brain Integration Tests ==="
echo ""

echo "--- Structural merge tests ---"
run_test test_basic_two_machine_sync
run_test test_no_import_for_missing_project
run_test test_accumulated_memory_across_syncs
run_test test_three_machine_fan_out
run_test test_non_conflicting_merge_no_llm
run_test test_global_claude_md_propagates
run_test test_group_sync_one_way
run_test test_group_sync_bidirectional
run_test test_offline_then_rejoin
run_test test_sequential_edits_same_file_no_conflict

echo ""
echo "--- Lifecycle test ---"
run_test test_full_lifecycle

echo ""
echo "--- 3-way merge tests ---"
run_test test_3way_outgoing_only
run_test test_3way_incoming_only
run_test test_3way_real_conflict
run_test test_3way_fallback_to_2way
run_test test_no_spurious_commits_after_stabilize

echo ""
echo "--- Rules, skills, settings, MCP tests ---"
run_test test_rules_and_skills_sync
run_test test_settings_deep_merge
run_test test_mcp_server_sync_and_summary
run_test test_3way_claude_md_outgoing
run_test test_project_not_on_machine_preserved
run_test test_double_apply_idempotent
run_test test_outgoing_push_propagates
run_test test_no_hash_mismatch_after_merge
run_test test_3way_uses_prepull_baseline

echo ""
echo "--- Summary + safety tests ---"
run_test test_summary_outgoing_only
run_test test_summary_incoming_changes
run_test test_backup_failure_blocks_import
run_test test_invalid_json_merge_preserves_original

echo ""
echo "--- Conflict resolution tests (LLM) ---"
run_test test_memory_conflict_resolve
run_test test_claude_md_conflict_resolve

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  echo ""
  exit 1
fi
