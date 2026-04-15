#!/usr/bin/env bash
# resolve-conflicts.sh — Resolve pending brain merge conflicts using LLM.
#
# Reads brain-conflicts.json, calls claude to merge each conflict,
# applies resolutions to local files and consolidated brain, marks resolved.
#
# Usage: resolve-conflicts.sh [--quiet]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

QUIET=false
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; BRAIN_QUIET=true; shift ;;
    *) shift ;;
  esac
done

CONFLICTS_FILE="${CONFLICTS_FILE:-${HOME}/.claude/brain-conflicts.json}"

if [ ! -f "$CONFLICTS_FILE" ]; then
  log_info "No conflicts file found. Nothing to resolve."
  exit 0
fi

unresolved_count=$(jq '[.conflicts[] | select(.resolved != true)] | length' "$CONFLICTS_FILE")
if [ "$unresolved_count" -eq 0 ]; then
  log_info "No unresolved conflicts."
  exit 0
fi

log_info "Resolving ${unresolved_count} conflict(s)..."

# ── LLM merge helper ──────────────────────────────────────────────────────────
llm_merge_text() {
  local label="$1" bc="$2" oc="$3"
  local prompt_file result merged

  prompt_file=$(brain_mktemp)
  cat > "$prompt_file" << PROMPT
Merge the two versions of \`${label}\` below into one.
- Remove duplicate content.
- Keep all unique information from both versions.
- Resolve conflicts using your judgment — prefer more specific or recent wording.
- Return only the merged content. No commentary, no explanation.

## Consolidated version:
${bc}

## Current machine version:
${oc}
PROMPT

  # HOME=/tmp prevents brain-sync SessionStart hooks from firing
  # (hook checks $HOME/.claude/brain-config.json which won't exist under /tmp).
  # Claude CLI finds its auth token via system paths, not just HOME.
  result=$(cat "$prompt_file" | HOME=/tmp claude -p - \
    --output-format json \
    --json-schema '{"type":"object","properties":{"merged_content":{"type":"string"}},"required":["merged_content"]}' \
    --model sonnet --max-turns 3 2>/dev/null) || { rm -f "$prompt_file"; return 1; }
  rm -f "$prompt_file"

  merged=$(echo "$result" | jq -r '.structured_output.merged_content // empty')
  [ -n "$merged" ] && printf '%s' "$merged" || return 1
}

# ── Apply resolution to consolidated brain ────────────────────────────────────
apply_resolution() {
  local section="$1" filename="$2" content="$3"
  local consolidated="${BRAIN_REPO}/consolidated/brain.json"
  [ ! -f "$consolidated" ] && return 0

  local tmp
  tmp=$(brain_mktemp)

  case "$section" in
    claude_md)
      jq --arg c "$content" \
        '.declarative.claude_md.content = $c | .declarative.claude_md.hash = "resolved"' \
        "$consolidated" > "$tmp" && mv "$tmp" "$consolidated"
      # Also update local CLAUDE.md
      printf '%s\n' "$content" > "${CLAUDE_DIR}/CLAUDE.md"
      ;;
    rules|skills|agents|output-styles)
      local jq_path
      case "$section" in
        rules) jq_path="declarative.rules" ;;
        skills) jq_path="procedural.skills" ;;
        agents) jq_path="procedural.agents" ;;
        output-styles) jq_path="procedural.output_styles" ;;
      esac
      jq --arg p "$jq_path" --arg f "$filename" --arg c "$content" \
        'getpath($p | split("."))[$f].content = $c | getpath($p | split("."))[$f].hash = "resolved"' \
        "$consolidated" > "$tmp" && mv "$tmp" "$consolidated"
      ;;
    memory/*)
      local proj="${section#memory/}"
      jq --arg p "$proj" --arg f "$filename" --arg c "$content" \
        '.experiential.auto_memory[$p][$f].content = $c | .experiential.auto_memory[$p][$f].hash = "resolved"' \
        "$consolidated" > "$tmp" && mv "$tmp" "$consolidated"
      # Also update local memory file if project dir exists
      local mem_dir="${CLAUDE_DIR}/projects/${proj}/memory"
      if [ -d "$mem_dir" ]; then
        printf '%s\n' "$content" > "${mem_dir}/${filename}"
      fi
      ;;
    group/*)
      local gname="${section#group/}"
      local group_members
      group_members=$(jq -r --arg g "$gname" '.declarative.project_groups[$g] // [] | .[]' "$consolidated" 2>/dev/null)
      for member in $group_members; do
        jq --arg m "$member" --arg f "$filename" --arg c "$content" \
          'if .experiential.auto_memory[$m] then .experiential.auto_memory[$m][$f].content = $c | .experiential.auto_memory[$m][$f].hash = "resolved" else . end' \
          "$consolidated" > "$tmp" && mv "$tmp" "$consolidated"
        local mem_dir="${CLAUDE_DIR}/projects/${member}/memory"
        if [ -d "$mem_dir" ]; then
          printf '%s\n' "$content" > "${mem_dir}/${filename}"
        fi
      done
      ;;
    *)
      log_warn "Unknown conflict section: $section — skipping apply."
      ;;
  esac
}

# ── Resolve each conflict ─────────────────────────────────────────────────────
resolved_count=0
indices=$(jq -r '[.conflicts | to_entries[] | select(.value.resolved != true) | .key] | .[]' "$CONFLICTS_FILE")

for idx in $indices; do
  section=$(jq -r ".conflicts[$idx].section" "$CONFLICTS_FILE")
  filename=$(jq -r ".conflicts[$idx].filename" "$CONFLICTS_FILE")
  bc=$(jq -r ".conflicts[$idx].consolidated_content" "$CONFLICTS_FILE")
  oc=$(jq -r ".conflicts[$idx].local_content" "$CONFLICTS_FILE")

  log_info "Resolving: ${section}/${filename}..."

  if mc=$(llm_merge_text "${section}/${filename}" "$bc" "$oc"); then
    # Mark resolved
    tmp=$(brain_mktemp)
    jq --argjson i "$idx" --arg mc "$mc" --arg ts "$(now_iso)" \
      '.conflicts[$i].resolved = true | .conflicts[$i].resolution = $mc | .conflicts[$i].resolved_at = $ts' \
      "$CONFLICTS_FILE" > "$tmp" && mv "$tmp" "$CONFLICTS_FILE"

    # Apply to consolidated brain and local files
    apply_resolution "$section" "$filename" "$mc"

    resolved_count=$((resolved_count + 1))
  else
    log_warn "LLM failed for ${section}/${filename} — skipping."
  fi
done

log_info "${resolved_count}/${unresolved_count} conflict(s) resolved."
