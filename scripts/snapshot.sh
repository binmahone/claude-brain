#!/usr/bin/env bash
# snapshot.sh — Export brain snapshot and commit locally (push happens in sync.sh)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
FORCE=false
SKIP_SECRET_SCAN=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    --force) FORCE=true; shift ;;
    --skip-secret-scan) SKIP_SECRET_SCAN=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

check_dependencies
load_config

machine_id=$(get_config "machine_id")
snapshot_dir="${BRAIN_REPO}/machines/${machine_id}"

# Export fresh snapshot
mkdir -p "$snapshot_dir"
export_args=(--output "${snapshot_dir}/brain-snapshot.json")
$QUIET && export_args+=(--quiet)
$SKIP_SECRET_SCAN && export_args+=(--skip-secret-scan)
"${SCRIPT_DIR}/export.sh" "${export_args[@]}"

# Check if content actually changed (compare snapshot_hash, which excludes timestamps)
if ! $FORCE && ! $DRY_RUN; then
  new_hash=$(jq -r '.snapshot_hash // ""' "${snapshot_dir}/brain-snapshot.json" 2>/dev/null)
  old_hash=""
  # Get the hash from the last committed version (if any)
  old_hash=$(brain_git show HEAD:"machines/${machine_id}/brain-snapshot.json" 2>/dev/null | jq -r '.snapshot_hash // ""' 2>/dev/null || true)
  if [ -n "$new_hash" ] && [ "$new_hash" = "$old_hash" ]; then
    # Content hash unchanged — only volatile fields (exported_at) differ. Skip commit.
    brain_git checkout -- "machines/${machine_id}/brain-snapshot.json" 2>/dev/null || true
    log_info "No content changes to commit."
    exit 0
  fi
fi

# Dry-run mode: show what would be synced
if $DRY_RUN; then
  log_info "Would sync:"
  brain_git diff --stat -- "machines/${machine_id}/" 2>/dev/null || true
  exit 0
fi

# Update per-machine meta file
"${SCRIPT_DIR}/register-machine.sh" "$(get_config remote)"

# Commit locally — sync.sh will push everything together after pull --rebase
brain_git add "machines/${machine_id}/" 2>/dev/null || true
brain_git add "meta/machines/${machine_id}.json" 2>/dev/null || true
brain_git add "meta/logs/${machine_id}.json" 2>/dev/null || true
brain_git add "shared/" 2>/dev/null || true
brain_git commit -m "Sync: $(get_machine_name) (${machine_id}) at $(now_iso)" 2>/dev/null || {
  log_info "Nothing to commit."
}

log_info "Brain snapshot committed locally."
