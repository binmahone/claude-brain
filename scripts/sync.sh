#!/usr/bin/env bash
# sync.sh — Pull latest from remote, merge locally, then push consolidated result
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
AUTO_MERGE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --auto-merge) AUTO_MERGE=true; shift ;;
    *) shift ;;
  esac
done

check_dependencies
load_config

machine_id=$(get_config "machine_id")

# Pull --rebase: sync with remote before pushing
# This ensures our locally committed snapshot won't conflict with other machines' pushes.
# We pull AFTER snapshot.sh has committed our snapshot locally, so our commit is rebased
# on top of the remote's latest — other machines' snapshots won't overwrite ours.
brain_git pull --rebase origin main 2>/dev/null || {
  brain_git rebase --abort 2>/dev/null || true
  log_warn "Could not sync with remote. Working offline."
  exit 0
}

# Check if consolidated brain has changed
local_consolidated_hash=""
if [ -f "${BRAIN_REPO}/consolidated/brain.json" ]; then
  local_consolidated_hash=$(file_hash "${BRAIN_REPO}/consolidated/brain.json")
fi

# 2-way merge: consolidated (all other machines' merged state) + this machine's snapshot.
# The consolidated already represents the full history of all previously synced machines.
# We only need to fold in this machine's new changes.
current_snapshot="${BRAIN_REPO}/machines/${machine_id}/brain-snapshot.json"
current_snapshot_work=""   # path to the (possibly decrypted) snapshot we'll actually read

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
    # No consolidated yet — current snapshot becomes the seed
    log_info "No consolidated brain found. Using current snapshot as base."
    cp "$current_snapshot_work" "${BRAIN_REPO}/consolidated/brain.json"
  else
    log_info "Merging with consolidated brain..."

    # Structured merge (includes group bidirectional sync)
    step_tmp=$(brain_mktemp)
    "${SCRIPT_DIR}/merge-structured.sh" \
      "${BRAIN_REPO}/consolidated/brain.json" \
      "$current_snapshot_work" \
      "$step_tmp"

    # Semantic merge: LLM sees consolidated (other machines) vs current snapshot
    # Use a copy so OUTPUT path != SNAPSHOTS[0] path
    consolidated_copy=$(brain_mktemp)
    cp "${BRAIN_REPO}/consolidated/brain.json" "$consolidated_copy"

    if "${SCRIPT_DIR}/merge-semantic.sh" \
        "${BRAIN_REPO}/consolidated/brain.json" \
        "$consolidated_copy" \
        "$current_snapshot_work"; then
      rm -f "$step_tmp" "$consolidated_copy"
    else
      log_warn "Semantic merge failed. Using structured merge only."
      mv "$step_tmp" "${BRAIN_REPO}/consolidated/brain.json"
      rm -f "$consolidated_copy"
    fi
  fi

  # Clean up temp decrypted file if one was created
  [ "$current_snapshot_work" != "$current_snapshot" ] && rm -f "$current_snapshot_work"
fi

# Apply consolidated brain locally (with validation and backup)
"${SCRIPT_DIR}/import.sh" "${BRAIN_REPO}/consolidated/brain.json"

# Commit consolidated and push everything once (snapshot commit from snapshot.sh + consolidated)
brain_git add consolidated/ meta/
brain_git diff --cached --quiet 2>/dev/null || \
  brain_git commit -m "Consolidated: $(get_machine_name) merged at $(now_iso)" 2>/dev/null || true

if brain_push_with_retry 3 2; then
  local_tmp=$(brain_mktemp)
  jq --arg ts "$(now_iso)" '.last_pull = $ts | .dirty = false' "$BRAIN_CONFIG" > "$local_tmp"
  mv "$local_tmp" "$BRAIN_CONFIG"
  log_info "Brain pushed."
else
  local_tmp=$(brain_mktemp)
  jq --arg ts "$(now_iso)" '.last_pull = $ts | .dirty = true' "$BRAIN_CONFIG" > "$local_tmp"
  mv "$local_tmp" "$BRAIN_CONFIG"
  log_warn "Push failed. Will retry next session."
fi

# Check if auto-evolve is due
if [ -f "$DEFAULTS_FILE" ]; then
  evolve_interval_days="" last_evolved="" days_since_evolve=""
  evolve_interval_days=$(jq -r '.evolve_interval_days // 7' "$DEFAULTS_FILE")
  last_evolved=$(jq -r '.last_evolved // null' "$BRAIN_CONFIG")
  
  if [ "$last_evolved" = "null" ] || [ -z "$last_evolved" ]; then
    # Never evolved, set to now to start the timer
    local_tmp=$(brain_mktemp)
    jq --arg ts "$(now_iso)" '.last_evolved = $ts' "$BRAIN_CONFIG" > "$local_tmp"
    mv "$local_tmp" "$BRAIN_CONFIG"
  else
    # Calculate days since last evolution
    if command -v date &>/dev/null; then
      last_evolved_ts="" current_ts=""
      last_evolved_ts=$(date -d "$last_evolved" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_evolved" +%s 2>/dev/null || echo "0")
      current_ts=$(date +%s)
      days_since_evolve=$(( (current_ts - last_evolved_ts) / 86400 ))
      
      if [ "$days_since_evolve" -ge "$evolve_interval_days" ]; then
        log_info "Auto-evolve due (${days_since_evolve} days since last evolution)..."
        "${SCRIPT_DIR}/evolve.sh" --auto 2>/dev/null || {
          log_warn "Auto-evolve failed. Run /brain-evolve manually."
        }
      fi
    fi
  fi
fi

# Log the merge
new_consolidated_hash=$(file_hash "${BRAIN_REPO}/consolidated/brain.json")
if [ "$local_consolidated_hash" != "$new_consolidated_hash" ]; then
  append_merge_log "pull+merge" "Merged consolidated brain"
  log_info "Brain synced: consolidated brain updated."
else
  log_info "Brain synced: no changes."
fi
