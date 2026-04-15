#!/usr/bin/env bash
# sync.sh — Pull latest from remote, merge locally, commit.
#
# Modes:
#   (default)   snapshot → pull → merge → commit locally (no import, no push)
#   --summary   Compare local snapshot vs consolidated and output a JSON change summary
#   --apply     Backup + import to local ~/.claude/ + push to remote
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
MODE="sync"  # sync | summary | apply

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --summary) MODE="summary"; shift ;;
    --apply) MODE="apply"; shift ;;
    --auto-merge) shift ;;  # ignored, kept for backward compat
    *) shift ;;
  esac
done

# ── --apply mode: backup + import + push, then exit ───────────────────────────
if [ "$MODE" = "apply" ]; then
  load_config
  consolidated="${BRAIN_REPO}/consolidated/brain.json"
  if [ ! -f "$consolidated" ]; then
    log_error "No consolidated brain found. Run /brain-sync first."
    exit 1
  fi

  # Import (includes backup)
  "${SCRIPT_DIR}/import.sh" "$consolidated"
  log_info "Brain changes applied to local."

  # Save baseline for 3-way merge on next sync
  machine_id=$(get_config "machine_id")
  baseline="${BRAIN_REPO}/machines/${machine_id}/baseline.json"
  cp "$consolidated" "$baseline"
  brain_git add "machines/${machine_id}/baseline.json" 2>/dev/null || true
  brain_git diff --cached --quiet 2>/dev/null || \
    brain_git commit -m "Baseline: $(get_machine_name) at $(now_iso)" 2>/dev/null || true
  log_info "Baseline saved for 3-way merge."

  # Push to remote
  if brain_push_with_retry 3 2; then
    local_tmp=$(brain_mktemp)
    jq --arg ts "$(now_iso)" '.last_pull = $ts | .dirty = false' "$BRAIN_CONFIG" > "$local_tmp"
    mv "$local_tmp" "$BRAIN_CONFIG"
    log_info "Brain pushed to remote."
  else
    local_tmp=$(brain_mktemp)
    jq --arg ts "$(now_iso)" '.last_pull = $ts | .dirty = true' "$BRAIN_CONFIG" > "$local_tmp"
    mv "$local_tmp" "$BRAIN_CONFIG"
    log_warn "Push failed. Will retry on next /brain-sync --apply."
  fi
  exit 0
fi

# ── --summary mode: diff local snapshot vs consolidated, output JSON ──────────
if [ "$MODE" = "summary" ]; then
  load_config
  consolidated="${BRAIN_REPO}/consolidated/brain.json"
  old_snapshot="${BRAIN_REPO}/machines/$(get_config machine_id)/brain-snapshot.json"

  if [ ! -f "$consolidated" ]; then
    echo '{"has_changes":false,"conflicts":0}'
    exit 0
  fi

  # If no local snapshot to compare against, everything in consolidated is "incoming"
  if [ ! -f "$old_snapshot" ]; then
    old_snapshot_json='{}'
  else
    old_snapshot_json=$(cat "$old_snapshot")
  fi

  # Count conflicts from conflicts file
  conflict_count=0
  if [ -f "${HOME}/.claude/brain-conflicts.json" ]; then
    conflict_count=$(jq '[.conflicts[] | select(.resolved != true)] | length' "${HOME}/.claude/brain-conflicts.json" 2>/dev/null || echo "0")
  fi

  # Check for unpushed commits (outgoing changes)
  has_outgoing=false
  if brain_git log origin/main..HEAD --oneline 2>/dev/null | grep -q .; then
    has_outgoing=true
  fi

  # Generate summary by comparing snapshot (what we have locally) vs consolidated (merged result)
  jq -n --argjson local "$old_snapshot_json" \
        --argjson merged "$(cat "$consolidated")" \
        --argjson conflict_count "$conflict_count" \
        --argjson has_outgoing "$has_outgoing" '
    def diff_keys($a; $b):
      (($b // {}) | keys) - (($a // {}) | keys);
    def changed_keys($a; $b):
      [($a // {}) | to_entries[] |
        select(($b // {})[.key].hash != null and ($b // {})[.key].hash != .value.hash) |
        .key];

    ($local.declarative.rules // {}) as $lr |
    ($merged.declarative.rules // {}) as $mr |
    ($local.procedural.skills // {}) as $ls |
    ($merged.procedural.skills // {}) as $ms |
    ($local.procedural.agents // {}) as $la |
    ($merged.procedural.agents // {}) as $ma |
    ($local.declarative.claude_md.hash // "") as $lch |
    ($merged.declarative.claude_md.hash // "") as $mch |
    ($local.environmental.mcp_servers // {}) as $lmcp |
    ($merged.environmental.mcp_servers // {}) as $mmcp |

    (($mmcp | keys) - ($lmcp | keys)) as $mcp_added |

    # Memory changes: files in consolidated not in local snapshot (or different hash)
    ([$merged.experiential.auto_memory // {} | to_entries[] |
      .key as $proj | .value // {} | to_entries[] |
      select(($local.experiential.auto_memory[$proj][.key].hash // null) != .value.hash)
    ] | length > 0) as $memory_changed |

    {
      has_changes: (($lch != $mch) or
        (diff_keys($lr; $mr) | length > 0) or (changed_keys($lr; $mr) | length > 0) or
        (diff_keys($ls; $ms) | length > 0) or (changed_keys($ls; $ms) | length > 0) or
        (diff_keys($la; $ma) | length > 0) or (changed_keys($la; $ma) | length > 0) or
        ($mcp_added | length > 0) or $memory_changed),
      claude_md_changed: ($lch != $mch),
      rules_added: diff_keys($lr; $mr),
      rules_changed: changed_keys($lr; $mr),
      skills_added: diff_keys($ls; $ms),
      skills_changed: changed_keys($ls; $ms),
      agents_added: diff_keys($la; $ma),
      agents_changed: changed_keys($la; $ma),
      mcp_servers_added: $mcp_added,
      has_outgoing: $has_outgoing,
      conflicts: $conflict_count
    }
  ' 2>/dev/null || echo '{"has_changes":false,"has_outgoing":false,"conflicts":0}'

  if [ "$conflict_count" -gt 0 ]; then
    log_info "${conflict_count} conflict(s) pending. Run /brain-conflicts to resolve."
  fi
  exit 0
fi

# ── Default sync mode: snapshot → pull → merge → commit locally (no push) ─────
check_dependencies
load_config

machine_id=$(get_config "machine_id")

# Step 1: snapshot current state
log_info "Taking snapshot of current brain state..."
"${SCRIPT_DIR}/snapshot.sh" --quiet || log_warn "Snapshot failed — continuing with last committed state."

# Step 2: pull --rebase
brain_git pull --rebase origin main 2>/dev/null || {
  brain_git rebase --abort 2>/dev/null || true
  log_warn "Could not sync with remote. Working offline."
  exit 0
}

# Record pre-merge hash
local_consolidated_hash=""
if [ -f "${BRAIN_REPO}/consolidated/brain.json" ]; then
  local_consolidated_hash=$(file_hash "${BRAIN_REPO}/consolidated/brain.json")
fi

# Step 3: merge (3-way if baseline exists, otherwise 2-way)
current_snapshot="${BRAIN_REPO}/machines/${machine_id}/brain-snapshot.json"
baseline="${BRAIN_REPO}/machines/${machine_id}/baseline.json"
current_snapshot_work=""

if [ ! -f "$current_snapshot" ]; then
  log_info "No current snapshot found. Skipping merge."
else
  # Decrypt if needed
  if head -1 "$current_snapshot" | grep -q "^-----BEGIN AGE ENCRYPTED FILE-----"; then
    if encryption_enabled && command -v age &>/dev/null; then
      decrypted_tmp=$(brain_mktemp)
      if decrypt_file "$current_snapshot" "$decrypted_tmp"; then
        current_snapshot_work="$decrypted_tmp"
      else
        log_warn "Failed to decrypt current snapshot. Skipping merge."
      fi
    else
      log_warn "Encrypted snapshot found but encryption not configured. Skipping merge."
    fi
  else
    current_snapshot_work="$current_snapshot"
  fi
fi

mkdir -p "${BRAIN_REPO}/consolidated"

if [ -n "$current_snapshot_work" ]; then
  if [ ! -f "${BRAIN_REPO}/consolidated/brain.json" ]; then
    log_info "No consolidated brain found. Using current snapshot as base."
    cp "$current_snapshot_work" "${BRAIN_REPO}/consolidated/brain.json"
  else
    log_info "Merging with consolidated brain..."
    merge_out=$(brain_mktemp)
    merge_args=("${BRAIN_REPO}/consolidated/brain.json" "$current_snapshot_work" "$merge_out")
    # Pass baseline as 4th arg for 3-way merge if available
    if [ -f "$baseline" ]; then
      merge_args+=("$baseline")
    fi
    "${SCRIPT_DIR}/merge.sh" "${merge_args[@]}"
    mv "$merge_out" "${BRAIN_REPO}/consolidated/brain.json"
  fi

  [ "$current_snapshot_work" != "$current_snapshot" ] && rm -f "$current_snapshot_work"
fi

# Step 4: log + commit locally (no push — push happens in --apply)
new_consolidated_hash=$(file_hash "${BRAIN_REPO}/consolidated/brain.json")
if [ "$local_consolidated_hash" != "$new_consolidated_hash" ]; then
  append_merge_log "pull+merge" "Merged consolidated brain"
fi

brain_git add consolidated/ "meta/machines/${machine_id}.json" "meta/logs/${machine_id}.json" 2>/dev/null || true
brain_git diff --cached --quiet 2>/dev/null || \
  brain_git commit -m "Consolidated: $(get_machine_name) merged at $(now_iso)" 2>/dev/null || true

if [ "$local_consolidated_hash" != "$new_consolidated_hash" ]; then
  log_info "Brain synced: consolidated brain updated. Run --summary to review, --apply to import and push."
else
  log_info "Brain synced: no changes."
fi
