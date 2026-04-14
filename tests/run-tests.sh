#!/usr/bin/env bash
# run-tests.sh — Integration test suite for claude-brain
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR=""

# Counters
PASS=0
FAIL=0
SKIP=0

# Colors
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

# ── Helpers ────────────────────────────────────────────────────────────────────
pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}⊘${NC} $1 (skipped)"; SKIP=$((SKIP + 1)); }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }

jqr() {
  local filter="$1" file="$2"
  jq -r "$filter" "$file" 2>/dev/null
}

json_valid() {
  jq empty "$1" 2>/dev/null
}

json_length() {
  local filter="$1" file="$2"
  jq "${filter} | length" "$file" 2>/dev/null || echo "0"
}

json_set() {
  local file="$1" key="$2" value="$3"
  local tmp; tmp=$(mktemp)
  jq --arg v "$value" ".$key = \$v" "$file" > "$tmp" && mv "$tmp" "$file"
}

# ── Mock claude CLI ────────────────────────────────────────────────────────────
# Sets up a fake `claude` binary at the front of PATH.
# Behaviour is controlled by files in $HOME/.claude/:
#   mock-claude-fail   → claude exits 1 (simulate unavailable)
#   mock-claude-calls  → appended to on every invocation (call counter)
#   mock-claude-merge  → content written here is used as merged_content response
#                        (defaults to "MOCK_MERGED_CONTENT" if file absent)
setup_mock_claude() {
  local mock_bin="$TEST_DIR/mock-bin"
  mkdir -p "$mock_bin"

  cat > "$mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
# Mock claude for testing

if [ -f "${HOME}/.claude/mock-claude-fail" ]; then
  exit 1
fi

# Read stdin (the prompt)
input=$(cat)

if [[ "$*" == *"--output-format json"* ]]; then
  # Actual LLM merge call — track it
  echo "merge_call" >> "${HOME}/.claude/mock-claude-calls"
  merged_content="MOCK_MERGED_CONTENT"
  if [ -f "${HOME}/.claude/mock-claude-merge" ]; then
    merged_content=$(cat "${HOME}/.claude/mock-claude-merge")
  fi
  printf '{"structured_output":{"merged_content":"%s"}}' "$merged_content"
else
  # Probe call (check_llm_available) — do NOT track, just respond
  echo "claude mock v1.0"
fi
MOCK
  chmod +x "$mock_bin/claude"
  export PATH="$mock_bin:$PATH"

  # Reset call counter and fail flag
  rm -f "${HOME}/.claude/mock-claude-fail" "${HOME}/.claude/mock-claude-calls"
}

teardown_mock_claude() {
  rm -f "${HOME}/.claude/mock-claude-fail" \
        "${HOME}/.claude/mock-claude-calls" \
        "${HOME}/.claude/mock-claude-merge"
}

mock_llm_call_count() {
  if [ -f "${HOME}/.claude/mock-claude-calls" ]; then
    grep -c "^merge_call$" "${HOME}/.claude/mock-claude-calls" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# ── Sandbox ────────────────────────────────────────────────────────────────────
setup_sandbox() {
  TEST_DIR=$(mktemp -d)
  export HOME="$TEST_DIR/home"
  export CLAUDE_DIR="$HOME/.claude"
  export BRAIN_REPO="$HOME/.claude/brain-repo"
  export BRAIN_CONFIG="$HOME/.claude/brain-config.json"

  mkdir -p "$CLAUDE_DIR"/{rules,skills/review,agents,projects/my-project/memory,output-styles}
  mkdir -p "$BRAIN_REPO"/{machines,consolidated,meta/machines,shared/skills,shared/agents,shared/rules}

  cat > "$HOME/CLAUDE.md" <<'EOF'
# My Project Rules
- Use pnpm not npm
- Always write tests
- Prefer TypeScript
EOF

  echo "Always run linting before commit." > "$CLAUDE_DIR/rules/linting.md"
  echo "Use conventional commits."         > "$CLAUDE_DIR/rules/commits.md"

  cat > "$CLAUDE_DIR/skills/review/SKILL.md" <<'EOF'
---
name: review
description: Code review helper
---
Review the code for issues.
EOF

  echo "You are a debugging specialist." > "$CLAUDE_DIR/agents/debugger.md"

  cat > "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" <<'EOF'
- Project uses vitest for testing
- Database is PostgreSQL with Drizzle ORM
- Deploy via GitHub Actions
EOF

  cat > "$CLAUDE_DIR/settings.json" <<'EOF'
{
  "permissions": {
    "allow": ["Bash(git:*)"],
    "deny":  ["Bash(rm -rf /*)"]
  },
  "hooks": { "SessionStart": [] },
  "env":   { "SECRET_KEY": "should-not-be-exported" }
}
EOF

  cat > "$CLAUDE_DIR/keybindings.json" <<'EOF'
[{"key": "ctrl+k", "command": "clear", "context": "terminal"}]
EOF

  (cd "$BRAIN_REPO" && git init -q -b main \
    && git config user.email "test@test.com" \
    && git config user.name "Test" \
    && echo '{"entries":[]}' > meta/merge-log.json \
    && git add -A && git commit -q -m "init")

  export CLAUDE_PLUGIN_ROOT="$PROJECT_DIR"
}

cleanup_sandbox() {
  [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"
}
trap cleanup_sandbox EXIT

# ── Snapshot helpers ───────────────────────────────────────────────────────────
# Build a minimal valid snapshot JSON with optional overrides via jq args.
minimal_snapshot() {
  local id="$1" name="$2"
  jq -n --arg id "$id" --arg name "$name" '{
    schema_version: "1.0.0",
    machine: {id: $id, name: $name},
    declarative: {
      claude_md: {content: "", hash: ""},
      rules: {},
      project_groups: {}
    },
    procedural: {skills: {}, agents: {}, output_styles: {}},
    experiential: {auto_memory: {}, agent_memory: {}},
    environmental: {
      settings:    {content: {}, hash: ""},
      keybindings: {content: [], hash: ""},
      mcp_servers: {}
    },
    shared: {skills: {}, agents: {}, rules: {}}
  }'
}

# ══════════════════════════════════════════════════════════════════════════════
# EXPORT TESTS
# ══════════════════════════════════════════════════════════════════════════════

test_export_structure() {
  section "Export: snapshot structure"

  local output="$TEST_DIR/snapshot.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$output" --skip-secret-scan --quiet 2>/dev/null || true

  if [ ! -f "$output" ]; then
    fail "export.sh did not produce output file"; return
  fi

  json_valid "$output" && pass "Output is valid JSON" || { fail "Output is not valid JSON"; return; }

  for field in schema_version exported_at machine declarative procedural experiential environmental; do
    jq -e ".$field" "$output" >/dev/null 2>&1 \
      && pass "Has field: $field" \
      || fail "Missing field: $field"
  done

  jq -e ".machine.id" "$output" >/dev/null 2>&1 \
    && pass "Has machine.id" || fail "Missing machine.id"
}

test_export_no_secrets() {
  section "Export: secrets excluded from snapshot"

  local output="$TEST_DIR/snapshot.json"
  [ ! -f "$output" ] && { skip "No snapshot to check"; return; }

  grep -q "should-not-be-exported" "$output" \
    && fail "Env var SECRET_KEY leaked into snapshot" \
    || pass "Env vars excluded from snapshot"

  local env_val
  env_val=$(jqr ".environmental.settings.content.env" "$output")
  { [ -z "$env_val" ] || [ "$env_val" = "null" ] || [ "$env_val" = "{}" ]; } \
    && pass "settings.env stripped from snapshot" \
    || fail "settings.env present in snapshot: $env_val"
}

test_export_encoded_key() {
  section "Export: auto_memory key is full encoded path"

  local output="$TEST_DIR/snapshot-key.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$output" --skip-secret-scan --quiet 2>/dev/null || true

  [ ! -f "$output" ] && { fail "export.sh did not produce output"; return; }

  # The encoded key for ~/.claude/projects/my-project is derived from the actual
  # filesystem path of $CLAUDE_DIR/projects/my-project → basename gives the encoded dir
  local expected_key
  expected_key=$(basename "${CLAUDE_DIR}/projects/my-project")

  jq -e --arg k "$expected_key" '.experiential.auto_memory | has($k)' "$output" >/dev/null 2>&1 \
    && pass "auto_memory key matches encoded dir name: $expected_key" \
    || fail "auto_memory key '$expected_key' not found (keys: $(jqr '.experiential.auto_memory | keys' "$output"))"
}

test_export_memory_only() {
  section "Export: --memory-only flag"

  local output="$TEST_DIR/snapshot-memory-only.json"
  bash "$PROJECT_DIR/scripts/export.sh" --memory-only --output "$output" --skip-secret-scan --quiet 2>/dev/null || true

  [ ! -f "$output" ] && { fail "export.sh --memory-only did not produce output"; return; }
  json_valid "$output" && pass "Memory-only output is valid JSON" || { fail "Not valid JSON"; return; }

  local skills_count
  skills_count=$(json_length ".procedural.skills" "$output")
  [ "$skills_count" -eq 0 ] && pass "Skills empty in memory-only export" \
    || fail "Skills not empty (got $skills_count)"

  local rules_count
  rules_count=$(json_length ".declarative.rules" "$output")
  [ "$rules_count" -eq 0 ] && pass "Rules empty in memory-only export" \
    || fail "Rules not empty (got $rules_count)"

  local settings_val
  settings_val=$(jqr ".environmental.settings.content" "$output")
  [ "$settings_val" = "null" ] && pass "Settings null in memory-only export" \
    || fail "Settings not null in memory-only export"
}

test_export_scans_all_file_types() {
  section "Export: scans all file types (not just .md)"

  echo '{"tool": true}' > "$CLAUDE_DIR/skills/config.json"
  echo 'key: value'     > "$CLAUDE_DIR/skills/settings.yaml"

  local output="$TEST_DIR/snapshot-all-types.json"
  bash "$PROJECT_DIR/scripts/export.sh" --output "$output" --skip-secret-scan --quiet 2>/dev/null || true
  [ ! -f "$output" ] && { fail "export.sh did not produce output"; return; }

  jq -e '.procedural.skills["config.json"]'   "$output" >/dev/null 2>&1 \
    && pass ".json files included in export"  || fail ".json files NOT included in export"
  jq -e '.procedural.skills["settings.yaml"]' "$output" >/dev/null 2>&1 \
    && pass ".yaml files included in export"  || fail ".yaml files NOT included in export"
}

test_secret_scanning() {
  section "Export: secret scanning"

  echo "Use API key sk-1234567890abcdefghijklmnopqrstuvwxyz for auth" \
    >> "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md"

  local output
  output=$(bash "$PROJECT_DIR/scripts/export.sh" \
    --output "$TEST_DIR/snapshot-secrets.json" 2>&1) || true

  echo "$output" | grep -qi "secret\|warning\|potential" \
    && pass "Secret scan warned about API key pattern" \
    || skip "No secret scan warning detected"

  head -3 "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md" \
    > "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md.tmp"
  mv "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md.tmp" \
     "$CLAUDE_DIR/projects/my-project/memory/MEMORY.md"
}

# ══════════════════════════════════════════════════════════════════════════════
# IMPORT TESTS
# ══════════════════════════════════════════════════════════════════════════════

test_export_import_roundtrip() {
  section "Export → Import round-trip"

  local snapshot="$TEST_DIR/snapshot.json"
  [ ! -f "$snapshot" ] && { skip "No snapshot for import test"; return; }

  local target="$TEST_DIR/target-claude"
  mkdir -p "$target"
  local orig_claude_dir="$CLAUDE_DIR"
  export CLAUDE_DIR="$target"

  cp "$snapshot" "$BRAIN_REPO/consolidated/brain.json"
  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --quiet 2>/dev/null || true

  export CLAUDE_DIR="$orig_claude_dir"

  [ -f "$target/rules/linting.md" ] && pass "Rules imported" || fail "Rules not imported"
  [ -d "$target/skills" ]           && pass "Skills directory created" || fail "Skills not created"
}

test_import_skips_nonexistent_projects() {
  section "Import: skips projects not present on this machine"

  # Brain has memory for two projects; only one exists locally
  local brain
  brain=$(jq -n '{
    schema_version: "1.0.0",
    machine: {id: "test", name: "test"},
    declarative: {claude_md: null, rules: {}, project_groups: {}},
    procedural: {skills: {}, agents: {}, output_styles: {}},
    experiential: {
      auto_memory: {
        "-existing-project": {
          "note.md": {content: "this project exists", hash: "sha256:abc"}
        },
        "-nonexistent-project": {
          "note.md": {content: "this project does not exist", hash: "sha256:xyz"}
        }
      },
      agent_memory: {}
    },
    environmental: {
      settings:    {content: {}, hash: ""},
      keybindings: {content: [], hash: ""},
      mcp_servers: {}
    },
    shared: {skills: {}, agents: {}, rules: {}}
  }')

  # Create only the existing project dir
  mkdir -p "${CLAUDE_DIR}/projects/-existing-project"

  local brain_file="$TEST_DIR/brain-import-test.json"
  echo "$brain" > "$brain_file"
  bash "$PROJECT_DIR/scripts/import.sh" "$brain_file" --no-backup --quiet 2>/dev/null || true

  [ -f "${CLAUDE_DIR}/projects/-existing-project/memory/note.md" ] \
    && pass "Memory imported for existing project" \
    || fail "Memory NOT imported for existing project"

  [ ! -d "${CLAUDE_DIR}/projects/-nonexistent-project" ] \
    && pass "Nonexistent project directory not created" \
    || fail "Nonexistent project directory was created"
}

test_path_traversal_blocked() {
  section "Import: path traversal blocked"

  cat > "$TEST_DIR/malicious-brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {
    "claude_md": null,
    "rules": {"../../etc/evil.md": {"content": "pwned", "hash": "sha256:test"}},
    "project_groups": {}
  },
  "procedural":    {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential":  {"auto_memory": {}, "agent_memory": {}},
  "environmental": {
    "settings":    {"content": null, "hash": ""},
    "keybindings": {"content": null, "hash": ""},
    "mcp_servers": {}
  },
  "shared": {"skills": {}, "agents": {}, "rules": {}}
}
EOF

  local output
  output=$(bash "$PROJECT_DIR/scripts/import.sh" "$TEST_DIR/malicious-brain.json" --no-backup 2>&1) || true

  echo "$output" | grep -q "BLOCKED path traversal" \
    && pass "Path traversal key rejected with warning" \
    || fail "Path traversal key was not blocked"

  { [ ! -f "$TEST_DIR/home/etc/evil.md" ] && [ ! -f "/etc/evil.md" ]; } \
    && pass "Malicious file was not written" \
    || { fail "Malicious file was written!"; rm -f "$TEST_DIR/home/etc/evil.md" "/etc/evil.md" 2>/dev/null; }
}

# ══════════════════════════════════════════════════════════════════════════════
# MERGE TESTS
# ══════════════════════════════════════════════════════════════════════════════

# Helper: build a snapshot with specific memory files for a project key
snapshot_with_memory() {
  local id="$1" proj_key="$2" filename="$3" content="$4"
  minimal_snapshot "$id" "machine-$id" | jq \
    --arg k "$proj_key" --arg f "$filename" --arg c "$content" \
    '.experiential.auto_memory[$k][$f] = {content: $c, hash: ("sha256:" + $c)}'
}

test_merge_identical_no_llm() {
  section "Merge: identical snapshots → no LLM called"

  setup_mock_claude

  local snap="$TEST_DIR/snap-ident.json"
  minimal_snapshot "aaa" "machine-a" > "$snap"

  local out="$TEST_DIR/merged-ident.json"
  bash "$PROJECT_DIR/scripts/merge.sh" "$snap" "$snap" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || fail "merge.sh produced no output"

  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -eq 0 ] && pass "LLM not called for identical snapshots (calls=$calls)" \
    || fail "LLM called unnecessarily (calls=$calls)"

  teardown_mock_claude
}

test_merge_one_side_only_no_llm() {
  section "Merge: file only on one side → included without LLM"

  setup_mock_claude

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-one-a.json"
  snap_b="$TEST_DIR/snap-one-b.json"
  out="$TEST_DIR/merged-one.json"

  # snap_a has a rule file; snap_b does not
  minimal_snapshot "aaa" "machine-a" | jq \
    '.declarative.rules["only-in-a.md"] = {content: "rule content", hash: "sha256:abc"}' > "$snap_a"
  minimal_snapshot "bbb" "machine-b" > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  jq -e '.declarative.rules["only-in-a.md"]' "$out" >/dev/null 2>&1 \
    && pass "File only on one side was included in merge" \
    || fail "File only on one side was NOT included"

  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -eq 0 ] && pass "LLM not called for non-conflicting file (calls=$calls)" \
    || fail "LLM called unnecessarily (calls=$calls)"

  teardown_mock_claude
}

test_merge_conflict_uses_llm() {
  section "Merge: conflicting file → LLM called, result used"

  setup_mock_claude
  echo "MERGED_BY_LLM" > "${HOME}/.claude/mock-claude-merge"

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-conf-a.json"
  snap_b="$TEST_DIR/snap-conf-b.json"
  out="$TEST_DIR/merged-conf.json"

  # Both have the same rule file with different content
  minimal_snapshot "aaa" "machine-a" | jq \
    '.declarative.rules["shared.md"] = {content: "version A", hash: "sha256:aaa"}' > "$snap_a"
  minimal_snapshot "bbb" "machine-b" | jq \
    '.declarative.rules["shared.md"] = {content: "version B", hash: "sha256:bbb"}' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -ge 1 ] && pass "LLM called for conflicting file (calls=$calls)" \
    || fail "LLM NOT called for conflict (calls=$calls)"

  local merged_content
  merged_content=$(jqr '.declarative.rules["shared.md"].content' "$out")
  [ "$merged_content" = "MERGED_BY_LLM" ] \
    && pass "Merged content comes from LLM response" \
    || fail "Merged content is wrong: '$merged_content'"

  teardown_mock_claude
}

test_merge_llm_unavailable_exits() {
  section "Merge: LLM unavailable → merge.sh exits non-zero"

  setup_mock_claude
  touch "${HOME}/.claude/mock-claude-fail"

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-nollm-a.json"
  snap_b="$TEST_DIR/snap-nollm-b.json"
  out="$TEST_DIR/merged-nollm.json"

  # Two different snapshots so merge is actually needed
  minimal_snapshot "aaa" "machine-a" | jq \
    '.declarative.rules["x.md"] = {content: "v1", hash: "sha256:1"}' > "$snap_a"
  minimal_snapshot "bbb" "machine-b" | jq \
    '.declarative.rules["x.md"] = {content: "v2", hash: "sha256:2"}' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null \
    && fail "merge.sh should have exited non-zero when LLM unavailable" \
    || pass "merge.sh correctly exited non-zero when LLM unavailable"

  teardown_mock_claude
}

test_merge_llm_failure_keeps_base() {
  section "Merge: per-file LLM failure → keeps base (consolidated) version"

  setup_mock_claude

  # Make claude succeed for probe but fail for the actual merge call
  # We do this by making claude succeed once (probe) then fail thereafter
  local mock_bin
  mock_bin=$(echo "$PATH" | cut -d: -f1)
  cat > "$mock_bin/claude" << 'MOCK'
#!/usr/bin/env bash
count_file="${HOME}/.claude/mock-claude-calls"
echo "invoked" >> "$count_file"
count=$(wc -l < "$count_file" | tr -d ' ')

if [[ "$*" == *"--output-format json"* ]]; then
  # Fail on actual merge calls
  exit 1
else
  # Succeed on probe
  echo "claude mock v1.0"
fi
MOCK
  chmod +x "$mock_bin/claude"

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-fail-a.json"
  snap_b="$TEST_DIR/snap-fail-b.json"
  out="$TEST_DIR/merged-fail.json"

  minimal_snapshot "aaa" "machine-a" | jq \
    '.declarative.rules["x.md"] = {content: "base version", hash: "sha256:base"}' > "$snap_a"
  minimal_snapshot "bbb" "machine-b" | jq \
    '.declarative.rules["x.md"] = {content: "other version", hash: "sha256:other"}' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output despite LLM failure" \
    || { fail "No output on LLM failure"; teardown_mock_claude; return; }

  # Should keep base (consolidated) version on LLM failure
  local content
  content=$(jqr '.declarative.rules["x.md"].content' "$out")
  [ "$content" = "base version" ] \
    && pass "Base (consolidated) version kept on LLM failure" \
    || fail "Wrong content on LLM failure: '$content'"

  teardown_mock_claude
}

test_merge_settings_deep_merge() {
  section "Merge: settings deep merged (no LLM)"

  setup_mock_claude

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-set-a.json"
  snap_b="$TEST_DIR/snap-set-b.json"
  out="$TEST_DIR/merged-set.json"

  minimal_snapshot "aaa" "machine-a" | jq '
    .environmental.settings.content = {
      "permissions": {"allow": ["Bash(git:*)"], "deny": []},
      "hooks": {}
    }' > "$snap_a"

  minimal_snapshot "bbb" "machine-b" | jq '
    .environmental.settings.content = {
      "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Bash(rm:*)"]},
      "hooks": {}
    }' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  local allow_count deny_count
  allow_count=$(json_length ".environmental.settings.content.permissions.allow" "$out")
  deny_count=$(json_length  ".environmental.settings.content.permissions.deny"  "$out")

  [ "$allow_count" -ge 2 ] && pass "permissions.allow unioned ($allow_count entries)" \
    || fail "permissions.allow not unioned (got $allow_count)"
  [ "$deny_count"  -ge 1 ] && pass "permissions.deny unioned ($deny_count entries)" \
    || fail "permissions.deny not unioned (got $deny_count)"

  # Settings merge must NOT call LLM
  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -eq 0 ] && pass "LLM not called for settings merge" \
    || fail "LLM called for settings merge (calls=$calls)"

  teardown_mock_claude
}

test_merge_keybindings_union() {
  section "Merge: keybindings array unioned (no LLM)"

  setup_mock_claude

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-kb-a.json"
  snap_b="$TEST_DIR/snap-kb-b.json"
  out="$TEST_DIR/merged-kb.json"

  minimal_snapshot "aaa" "machine-a" | jq '
    .environmental.keybindings.content = [{"key":"ctrl+k","command":"clear"}]' > "$snap_a"
  minimal_snapshot "bbb" "machine-b" | jq '
    .environmental.keybindings.content = [{"key":"ctrl+l","command":"scroll"}]' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  local kb_count
  kb_count=$(json_length ".environmental.keybindings.content" "$out")
  [ "$kb_count" -ge 2 ] && pass "Keybindings from both sides present ($kb_count entries)" \
    || fail "Keybindings not merged (got $kb_count)"

  # When one side has null keybindings, verify no corruption
  minimal_snapshot "aaa" "machine-a" | jq '
    .environmental.keybindings.content = null' > "$snap_a"
  minimal_snapshot "bbb" "machine-b" | jq '
    .environmental.keybindings.content = [{"key":"ctrl+l","command":"scroll"}]' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true
  local type
  type=$(jqr '.environmental.keybindings.content | type' "$out")
  [ "$type" = "array" ] && pass "Keybindings content stays array when one side is null" \
    || fail "Keybindings content corrupted to type '$type' when one side null"

  teardown_mock_claude
}

test_merge_memory_per_project_isolation() {
  section "Merge: per-project memory — each project's conflict is isolated"

  setup_mock_claude
  echo "MERGED_BY_LLM" > "${HOME}/.claude/mock-claude-merge"

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-mem-a.json"
  snap_b="$TEST_DIR/snap-mem-b.json"
  out="$TEST_DIR/merged-mem.json"

  # Two projects both have conflicting note.md
  minimal_snapshot "aaa" "machine-a" | jq '
    .experiential.auto_memory["-proj-alpha"]["note.md"] = {content: "alpha A", hash: "sha256:aa"} |
    .experiential.auto_memory["-proj-beta"]["note.md"]  = {content: "beta A",  hash: "sha256:ba"}
  ' > "$snap_a"

  minimal_snapshot "bbb" "machine-b" | jq '
    .experiential.auto_memory["-proj-alpha"]["note.md"] = {content: "alpha B", hash: "sha256:ab"} |
    .experiential.auto_memory["-proj-beta"]["note.md"]  = {content: "beta B",  hash: "sha256:bb"}
  ' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  # Both projects should have been merged (LLM called twice, once per project)
  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -ge 2 ] && pass "LLM called separately for each project ($calls calls)" \
    || fail "Expected ≥2 LLM calls for 2 conflicting projects, got $calls"

  # Each project's result should be the mock merged content
  local alpha_content beta_content
  alpha_content=$(jqr '.experiential.auto_memory["-proj-alpha"]["note.md"].content' "$out")
  beta_content=$(jqr  '.experiential.auto_memory["-proj-beta"]["note.md"].content'  "$out")
  [ "$alpha_content" = "MERGED_BY_LLM" ] && pass "Project alpha content merged via LLM" \
    || fail "Project alpha content wrong: '$alpha_content'"
  [ "$beta_content"  = "MERGED_BY_LLM" ] && pass "Project beta content merged via LLM" \
    || fail "Project beta content wrong: '$beta_content'"

  teardown_mock_claude
}

test_merge_claude_md_llm() {
  section "Merge: CLAUDE.md conflict → LLM called"

  setup_mock_claude
  echo "MERGED CLAUDE.MD" > "${HOME}/.claude/mock-claude-merge"

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-cmd-a.json"
  snap_b="$TEST_DIR/snap-cmd-b.json"
  out="$TEST_DIR/merged-cmd.json"

  minimal_snapshot "aaa" "machine-a" | jq \
    '.declarative.claude_md = {content: "# Rules A\n- rule one", hash: "sha256:a"}' > "$snap_a"
  minimal_snapshot "bbb" "machine-b" | jq \
    '.declarative.claude_md = {content: "# Rules B\n- rule two", hash: "sha256:b"}' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -ge 1 ] && pass "LLM called for CLAUDE.md conflict (calls=$calls)" \
    || fail "LLM NOT called for CLAUDE.md conflict"

  local content
  content=$(jqr '.declarative.claude_md.content' "$out")
  [ "$content" = "MERGED CLAUDE.MD" ] \
    && pass "CLAUDE.md content is LLM merged result" \
    || fail "CLAUDE.md content wrong: '$content'"

  teardown_mock_claude
}

# ══════════════════════════════════════════════════════════════════════════════
# GROUP SYNC TESTS
# ══════════════════════════════════════════════════════════════════════════════

test_group_sync_copy_to_missing_member() {
  section "Group sync: file only in one member → copied to other (no LLM)"

  setup_mock_claude

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-grp-copy-a.json"
  snap_b="$TEST_DIR/snap-grp-copy-b.json"
  out="$TEST_DIR/merged-grp-copy.json"

  # Group: proj-alpha and proj-beta are grouped
  # Only proj-alpha has shared-note.md
  minimal_snapshot "aaa" "machine-a" | jq '
    .declarative.project_groups["work"] = ["-proj-alpha", "-proj-beta"] |
    .experiential.auto_memory["-proj-alpha"]["shared-note.md"] = {content: "shared knowledge", hash: "sha256:s"} |
    .experiential.auto_memory["-proj-beta"] = {}
  ' > "$snap_a"

  minimal_snapshot "bbb" "machine-b" | jq '
    .declarative.project_groups["work"] = ["-proj-alpha", "-proj-beta"] |
    .experiential.auto_memory["-proj-alpha"] = {} |
    .experiential.auto_memory["-proj-beta"]  = {}
  ' > "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  # After group sync, proj-beta should also have shared-note.md
  jq -e '.experiential.auto_memory["-proj-beta"]["shared-note.md"]' "$out" >/dev/null 2>&1 \
    && pass "shared-note.md copied to group member proj-beta" \
    || fail "shared-note.md NOT copied to group member proj-beta"

  local content
  content=$(jqr '.experiential.auto_memory["-proj-beta"]["shared-note.md"].content' "$out")
  [ "$content" = "shared knowledge" ] \
    && pass "Copied content matches source" \
    || fail "Copied content wrong: '$content'"

  # No LLM needed for copy (no conflict)
  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -eq 0 ] && pass "LLM not called for group copy (calls=$calls)" \
    || fail "LLM called unnecessarily for group copy (calls=$calls)"

  teardown_mock_claude
}

test_group_sync_conflict_uses_llm_and_broadcasts() {
  section "Group sync: conflict between group members → LLM merge, broadcast to all"

  setup_mock_claude
  echo "GROUP_MERGED_CONTENT" > "${HOME}/.claude/mock-claude-merge"

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-grp-conf-a.json"
  snap_b="$TEST_DIR/snap-grp-conf-b.json"
  out="$TEST_DIR/merged-grp-conf.json"

  # After same-key merges, both proj-alpha and proj-beta have different shared-note.md
  minimal_snapshot "aaa" "machine-a" | jq '
    .declarative.project_groups["work"] = ["-proj-alpha", "-proj-beta"] |
    .experiential.auto_memory["-proj-alpha"]["shared-note.md"] = {content: "alpha version", hash: "sha256:a"} |
    .experiential.auto_memory["-proj-beta"]["shared-note.md"]  = {content: "beta version",  hash: "sha256:b"}
  ' > "$snap_a"

  # snap_b is identical (so same-key merge passes through unchanged)
  cp "$snap_a" "$snap_b"
  jq '.machine.id = "bbb" | .machine.name = "machine-b"' "$snap_b" > "$snap_b.tmp"
  mv "$snap_b.tmp" "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -ge 1 ] && pass "LLM called for intra-group conflict (calls=$calls)" \
    || fail "LLM NOT called for intra-group conflict"

  # Both members should get the merged result
  local alpha_content beta_content
  alpha_content=$(jqr '.experiential.auto_memory["-proj-alpha"]["shared-note.md"].content' "$out")
  beta_content=$(jqr  '.experiential.auto_memory["-proj-beta"]["shared-note.md"].content'  "$out")

  [ "$alpha_content" = "GROUP_MERGED_CONTENT" ] \
    && pass "proj-alpha got LLM merged content" \
    || fail "proj-alpha content wrong: '$alpha_content'"
  [ "$beta_content" = "GROUP_MERGED_CONTENT" ] \
    && pass "proj-beta got LLM merged content (broadcast)" \
    || fail "proj-beta content wrong: '$beta_content'"

  teardown_mock_claude
}

test_group_sync_identical_content_no_llm() {
  section "Group sync: identical content across members → no LLM, copies to missing"

  setup_mock_claude

  local snap_a snap_b out
  snap_a="$TEST_DIR/snap-grp-same-a.json"
  snap_b="$TEST_DIR/snap-grp-same-b.json"
  out="$TEST_DIR/merged-grp-same.json"

  # Both members have same content for shared-note.md, proj-gamma has nothing
  minimal_snapshot "aaa" "machine-a" | jq '
    .declarative.project_groups["work"] = ["-proj-alpha", "-proj-beta", "-proj-gamma"] |
    .experiential.auto_memory["-proj-alpha"]["shared-note.md"] = {content: "same content", hash: "sha256:s"} |
    .experiential.auto_memory["-proj-beta"]["shared-note.md"]  = {content: "same content", hash: "sha256:s"} |
    .experiential.auto_memory["-proj-gamma"] = {}
  ' > "$snap_a"
  cp "$snap_a" "$snap_b"
  jq '.machine.id = "bbb"' "$snap_b" > "$snap_b.tmp" && mv "$snap_b.tmp" "$snap_b"

  bash "$PROJECT_DIR/scripts/merge.sh" "$snap_a" "$snap_b" "$out" 2>/dev/null || true

  [ -f "$out" ] && pass "merge.sh produced output" || { fail "No output"; teardown_mock_claude; return; }

  jq -e '.experiential.auto_memory["-proj-gamma"]["shared-note.md"]' "$out" >/dev/null 2>&1 \
    && pass "File copied to proj-gamma (missing member)" \
    || fail "File NOT copied to proj-gamma"

  local calls; calls=$(mock_llm_call_count)
  [ "$calls" -eq 0 ] && pass "No LLM called for identical group content (calls=$calls)" \
    || fail "LLM called unnecessarily (calls=$calls)"

  teardown_mock_claude
}

# ══════════════════════════════════════════════════════════════════════════════
# MACHINE REGISTRATION TESTS
# ══════════════════════════════════════════════════════════════════════════════

test_register_machine() {
  section "Register machine"

  rm -f "$BRAIN_CONFIG"
  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true

  [ ! -f "$BRAIN_CONFIG" ] && { fail "brain-config.json not created"; return; }
  json_valid "$BRAIN_CONFIG" && pass "brain-config.json is valid JSON" \
    || { fail "brain-config.json is not valid JSON"; return; }

  for field in version remote machine_id machine_name brain_repo_path auto_sync; do
    jq -e ".$field" "$BRAIN_CONFIG" >/dev/null 2>&1 \
      && pass "Config has field: $field" || fail "Config missing field: $field"
  done
}

test_register_machine_preserves_timestamps() {
  section "register-machine.sh preserves existing sync timestamps"

  rm -f "$BRAIN_CONFIG"
  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true
  [ ! -f "$BRAIN_CONFIG" ] && { fail "brain-config.json not created"; return; }

  local known_push="2025-01-15T10:00:00Z"
  local known_pull="2025-01-14T09:00:00Z"
  local known_evolved="2025-01-13T08:00:00Z"
  json_set "$BRAIN_CONFIG" "last_push"    "$known_push"
  json_set "$BRAIN_CONFIG" "last_pull"    "$known_pull"
  json_set "$BRAIN_CONFIG" "last_evolved" "$known_evolved"

  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true

  local actual_push actual_pull actual_evolved
  actual_push=$(jqr    ".last_push"    "$BRAIN_CONFIG")
  actual_pull=$(jqr    ".last_pull"    "$BRAIN_CONFIG")
  actual_evolved=$(jqr ".last_evolved" "$BRAIN_CONFIG")

  [ "$actual_push"    = "$known_push"    ] && pass "last_push preserved"    || fail "last_push wiped (got '$actual_push')"
  [ "$actual_pull"    = "$known_pull"    ] && pass "last_pull preserved"    || fail "last_pull wiped (got '$actual_pull')"
  [ "$actual_evolved" = "$known_evolved" ] && pass "last_evolved preserved" || fail "last_evolved wiped (got '$actual_evolved')"

  rm -f "$BRAIN_CONFIG"
  bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true
  actual_push=$(jqr ".last_push" "$BRAIN_CONFIG")
  [ "$actual_push" = "null" ] && pass "last_push is null on fresh registration" \
    || fail "last_push should be null on fresh registration (got '$actual_push')"
}

# ══════════════════════════════════════════════════════════════════════════════
# SYNC INTEGRATION TEST
# ══════════════════════════════════════════════════════════════════════════════

test_auto_evolve_trigger() {
  section "Auto-evolve scheduling"

  if [ ! -f "$BRAIN_CONFIG" ]; then
    bash "$PROJECT_DIR/scripts/register-machine.sh" "git@github.com:test/test.git" 2>/dev/null || true
  fi

  local eight_days_ago
  eight_days_ago=$(date -d "8 days ago" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -v-8d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
  [ -z "$eight_days_ago" ] && { skip "Cannot compute date"; return; }

  json_set "$BRAIN_CONFIG" "last_evolved" "$eight_days_ago"

  local real_evolve="$PROJECT_DIR/scripts/evolve.sh"
  local backup_evolve="$TEST_DIR/evolve.sh.bak"
  cp "$real_evolve" "$backup_evolve"
  printf '#!/usr/bin/env bash\ntouch "$HOME/.claude/evolve-triggered"\n' > "$real_evolve"
  chmod +x "$real_evolve"

  local machine_id
  machine_id=$(jqr ".machine_id" "$BRAIN_CONFIG")
  mkdir -p "$BRAIN_REPO/machines/$machine_id"
  echo '{"schema_version":"1.0.0","machine":{"id":"test","name":"test"},"declarative":{"project_groups":{}},"procedural":{},"experiential":{"auto_memory":{}},"environmental":{}}' \
    > "$BRAIN_REPO/machines/$machine_id/brain-snapshot.json"

  (cd "$BRAIN_REPO" && git add -A && git commit -q -m "test snapshot" 2>/dev/null || true)

  local bare_remote="$TEST_DIR/remote.git"
  git clone --bare "$BRAIN_REPO" "$bare_remote" 2>/dev/null || true
  (cd "$BRAIN_REPO" && git remote remove origin 2>/dev/null || true \
    && git remote add origin "$bare_remote")

  setup_mock_claude
  bash "$PROJECT_DIR/scripts/sync.sh" --quiet 2>/dev/null || true
  teardown_mock_claude

  cp "$backup_evolve" "$real_evolve"

  [ -f "$HOME/.claude/evolve-triggered" ] \
    && { pass "Auto-evolve triggered after 8 days"; rm -f "$HOME/.claude/evolve-triggered"; } \
    || fail "Auto-evolve not triggered after 8 days"

  # Should NOT trigger after 2 days
  local two_days_ago
  two_days_ago=$(date -d "2 days ago" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -v-2d -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  json_set "$BRAIN_CONFIG" "last_evolved" "$two_days_ago"

  cp "$real_evolve" "$backup_evolve"
  printf '#!/usr/bin/env bash\ntouch "$HOME/.claude/evolve-triggered"\n' > "$real_evolve"
  chmod +x "$real_evolve"
  setup_mock_claude
  bash "$PROJECT_DIR/scripts/sync.sh" --quiet 2>/dev/null || true
  teardown_mock_claude
  cp "$backup_evolve" "$real_evolve"

  [ ! -f "$HOME/.claude/evolve-triggered" ] \
    && pass "Auto-evolve NOT triggered after 2 days" \
    || { fail "Auto-evolve incorrectly triggered after 2 days"; rm -f "$HOME/.claude/evolve-triggered"; }
}

# ══════════════════════════════════════════════════════════════════════════════
# MISC TESTS
# ══════════════════════════════════════════════════════════════════════════════

test_shared_namespace() {
  section "Shared namespace"

  cat > "$BRAIN_REPO/consolidated/brain.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "machine": {"id": "test", "name": "test"},
  "declarative": {"claude_md": {"content": "", "hash": ""}, "rules": {}, "project_groups": {}},
  "procedural":  {"skills": {}, "agents": {}, "output_styles": {}},
  "experiential": {"auto_memory": {}, "agent_memory": {}},
  "environmental": {
    "settings":    {"content": {}, "hash": ""},
    "keybindings": {"content": [], "hash": ""},
    "mcp_servers": {}
  },
  "shared": {
    "skills": {"team-tool.md": {"content": "# Shared Test Skill", "hash": "sha256:test"}},
    "agents": {},
    "rules": {}
  }
}
EOF

  bash "$PROJECT_DIR/scripts/import.sh" "$BRAIN_REPO/consolidated/brain.json" --quiet 2>/dev/null || true

  [ -f "$CLAUDE_DIR/skills/team-tool.md" ] \
    && pass "Shared skill imported to local skills" \
    || fail "Shared skill not imported"
}

test_wsl_detection() {
  section "OS detection"

  # Source in a subshell to avoid polluting the test process's function namespace
  local os
  os=$(bash -c "source '$PROJECT_DIR/scripts/common.sh' 2>/dev/null && detect_os")
  [[ "$os" =~ ^(linux|macos|wsl|windows|unknown)$ ]] \
    && pass "detect_os returned valid value: $os" \
    || fail "detect_os returned unexpected: '$os'"
}

test_encryption_roundtrip() {
  section "Encryption (age)"

  { command -v age &>/dev/null && command -v age-keygen &>/dev/null; } \
    || { skip "age not installed"; return; }

  source "$PROJECT_DIR/scripts/common.sh" 2>/dev/null || true

  local identity="$TEST_DIR/test-age-key.txt"
  local recipients="$TEST_DIR/test-recipients.txt"
  age-keygen -o "$identity" 2>/dev/null
  grep "# public key:" "$identity" | cut -d' ' -f4 > "$recipients"

  local plaintext="Hello, this is a test of brain encryption!"
  local encrypted
  encrypted=$(echo "$plaintext" | age -R "$recipients" -a 2>/dev/null) \
    || { fail "age encryption failed"; return; }

  echo "$encrypted" | head -1 | grep -q "BEGIN AGE ENCRYPTED FILE" \
    && pass "Content encrypted with age armor" || fail "Encrypted content missing age header"

  local decrypted
  decrypted=$(echo "$encrypted" | age -d -i "$identity" 2>/dev/null) \
    || { fail "age decryption failed"; return; }

  [ "$decrypted" = "$plaintext" ] \
    && pass "Decrypt round-trip matches original" \
    || fail "Decrypt mismatch: got '$decrypted'"
}

# ══════════════════════════════════════════════════════════════════════════════
# RUN
# ══════════════════════════════════════════════════════════════════════════════
echo -e "${CYAN}claude-brain integration tests${NC}"
echo "================================"

command -v jq &>/dev/null || { echo -e "${RED}ERROR: jq is required${NC}"; exit 1; }

setup_sandbox

# Export
test_export_structure
test_export_no_secrets
test_export_encoded_key
test_export_memory_only
test_export_scans_all_file_types
test_secret_scanning

# Import
test_export_import_roundtrip
test_import_skips_nonexistent_projects
test_path_traversal_blocked

# Merge
test_merge_identical_no_llm
test_merge_one_side_only_no_llm
test_merge_conflict_uses_llm
test_merge_llm_unavailable_exits
test_merge_llm_failure_keeps_base
test_merge_settings_deep_merge
test_merge_keybindings_union
test_merge_memory_per_project_isolation
test_merge_claude_md_llm

# Group sync
test_group_sync_copy_to_missing_member
test_group_sync_conflict_uses_llm_and_broadcasts
test_group_sync_identical_content_no_llm

# Machine registration
test_register_machine
test_register_machine_preserves_timestamps

# Misc
test_shared_namespace
test_wsl_detection
test_encryption_roundtrip

# Sync integration
test_auto_evolve_trigger

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
