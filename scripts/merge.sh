#!/usr/bin/env bash
# merge.sh — Brain merge: union for non-conflicting items, LLM for conflicts.
#
# Rules:
#   Only one side has a file  → include it (no LLM needed)
#   Both sides, same content  → keep as-is (no LLM needed)
#   Both sides, different     → LLM merge (only that file's content sent)
#
# Per-project context isolation: each project's conflicts are a separate LLM call.
# Group sync runs last: files missing from a group member are copied in; conflicts → LLM.
#
# Usage: merge.sh BASE OTHER OUTPUT
#   BASE   — consolidated brain (other machines' merged state)
#   OTHER  — current machine's fresh snapshot
#   OUTPUT — destination path for merged result
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BASE="$1"
OTHER="$2"
OUTPUT="$3"

if [ ! -f "$BASE" ] || [ ! -f "$OTHER" ]; then
  log_error "merge.sh: input files not found."
  exit 1
fi

check_llm_available || exit 1

# ── Quick exit if identical ────────────────────────────────────────────────────
if [ "$(file_hash "$BASE")" = "$(file_hash "$OTHER")" ]; then
  log_info "No differences — skipping merge."
  cp "$BASE" "$OUTPUT"
  exit 0
fi

# ── LLM merge helper ──────────────────────────────────────────────────────────
# Usage: llm_merge_text LABEL BASE_CONTENT OTHER_CONTENT
# Prints merged content to stdout. Exits non-zero if LLM call fails.
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

  result=$(cat "$prompt_file" | claude -p - \
    --output-format json \
    --json-schema '{"type":"object","properties":{"merged_content":{"type":"string"}},"required":["merged_content"]}' \
    --model sonnet --max-turns 1 2>/dev/null) || { rm -f "$prompt_file"; return 1; }
  rm -f "$prompt_file"

  merged=$(echo "$result" | jq -r '.structured_output.merged_content // empty')
  [ -n "$merged" ] && printf '%s' "$merged" || return 1
}

# ── Merge a set of files ───────────────────────────────────────────────────────
# Usage: merge_fileset BASE_JSON OTHER_JSON LABEL
# BASE_JSON / OTHER_JSON are objects: { "filename": { "content": "...", "hash": "..." } }
# Prints merged JSON object to stdout.
merge_fileset() {
  local base_json="$1" other_json="$2" label="$3"

  # Build union: all files from both sides. Base wins on conflict for now.
  local merged
  merged=$(jq -n --argjson b "$base_json" --argjson o "$other_json" '
    ($b | keys) + ($o | keys) | unique | map(. as $k |
      if ($b | has($k)) then {($k): $b[$k]}
      else {($k): $o[$k]}
      end
    ) | add // {}
  ')

  # Detect conflicts: files that exist on both sides with different content
  local conflict_keys
  conflict_keys=$(jq -rn --argjson b "$base_json" --argjson o "$other_json" '
    [ ($b | keys)[] | select(. as $k |
        ($o | has($k)) and ($b[$k].content != $o[$k].content)
      )
    ] | .[]
  ')

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    local bc oc mc
    bc=$(jq -rn --argjson b "$base_json" --arg k "$key" '$b[$k].content // ""')
    oc=$(jq -rn --argjson o "$other_json" --arg k "$key" '$o[$k].content // ""')

    log_info "LLM: merging ${label}/${key}..."
    if mc=$(llm_merge_text "${label}/${key}" "$bc" "$oc"); then
      merged=$(jq --arg k "$key" --arg c "$mc" \
        '.[$k] = {content: $c, hash: "merged"}' <<< "$merged")
    else
      log_warn "LLM merge failed for ${label}/${key} — keeping consolidated version."
    fi
  done <<< "$conflict_keys"

  echo "$merged"
}

# ── Start with BASE as foundation ─────────────────────────────────────────────
cp "$BASE" "$OUTPUT"

# ── 1. CLAUDE.md ──────────────────────────────────────────────────────────────
bc=$(jq -r '.declarative.claude_md.content // ""' "$BASE")
oc=$(jq -r '.declarative.claude_md.content // ""' "$OTHER")
if [ -n "$oc" ] && [ "$bc" != "$oc" ]; then
  if [ -z "$bc" ]; then
    mc="$oc"
  else
    log_info "LLM: merging CLAUDE.md..."
    mc=$(llm_merge_text "CLAUDE.md" "$bc" "$oc") || mc="$bc"
  fi
  tmp=$(brain_mktemp)
  jq --arg c "$mc" \
    '.declarative.claude_md.content = $c | .declarative.claude_md.hash = "merged"' \
    "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
fi

# ── 2–5. Text file collections ────────────────────────────────────────────────
for section_path in \
    "declarative.rules:rules" \
    "procedural.skills:skills" \
    "procedural.agents:agents" \
    "procedural.output_styles:output-styles"; do
  jq_path="${section_path%%:*}"
  label="${section_path##*:}"

  bs=$(jq --arg p "$jq_path" 'getpath($p | split(".")) // {}' "$BASE")
  os=$(jq --arg p "$jq_path" 'getpath($p | split(".")) // {}' "$OTHER")
  ms=$(merge_fileset "$bs" "$os" "$label")

  tmp=$(brain_mktemp)
  jq --arg p "$jq_path" --argjson v "$ms" 'setpath($p | split("."); $v)' \
    "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
done

# ── 6. Auto memory (per project — context isolation) ──────────────────────────
base_mem=$(jq '.experiential.auto_memory // {}' "$BASE")
other_mem=$(jq '.experiential.auto_memory // {}' "$OTHER")
all_proj=$(jq -rn --argjson b "$base_mem" --argjson o "$other_mem" \
  '($b | keys) + ($o | keys) | unique | .[]')

merged_mem="{}"
while IFS= read -r proj; do
  [ -z "$proj" ] && continue
  bp=$(jq -n --argjson m "$base_mem"  --arg k "$proj" '$m[$k] // {}')
  op=$(jq -n --argjson m "$other_mem" --arg k "$proj" '$m[$k] // {}')
  mp=$(merge_fileset "$bp" "$op" "memory/${proj}")
  merged_mem=$(jq -n --argjson acc "$merged_mem" --arg k "$proj" --argjson v "$mp" \
    '$acc + {($k): $v}')
done <<< "$all_proj"

tmp=$(brain_mktemp)
jq --argjson v "$merged_mem" '.experiential.auto_memory = $v' \
  "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"

# ── 7. Agent memory (per agent — context isolation) ───────────────────────────
base_amem=$(jq '.experiential.agent_memory // {}' "$BASE")
other_amem=$(jq '.experiential.agent_memory // {}' "$OTHER")
all_agents=$(jq -rn --argjson b "$base_amem" --argjson o "$other_amem" \
  '($b | keys) + ($o | keys) | unique | .[]')

merged_amem="{}"
while IFS= read -r agent; do
  [ -z "$agent" ] && continue
  ba=$(jq -n --argjson m "$base_amem"  --arg k "$agent" '$m[$k] // {}')
  oa=$(jq -n --argjson m "$other_amem" --arg k "$agent" '$m[$k] // {}')
  ma=$(merge_fileset "$ba" "$oa" "agent-memory/${agent}")
  merged_amem=$(jq -n --argjson acc "$merged_amem" --arg k "$agent" --argjson v "$ma" \
    '$acc + {($k): $v}')
done <<< "$all_agents"

tmp=$(brain_mktemp)
jq --argjson v "$merged_amem" '.experiential.agent_memory = $v' \
  "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"

# ── 8. Project groups (config union — no LLM needed) ─────────────────────────
base_g=$(jq '.declarative.project_groups // {}' "$BASE")
other_g=$(jq '.declarative.project_groups // {}' "$OTHER")
merged_g=$(jq -n --argjson a "$base_g" --argjson b "$other_g" '
  ($a | keys) + ($b | keys) | unique | map(
    . as $g | {($g): ([($a[$g] // [])[], ($b[$g] // [])[]] | unique)}
  ) | add // {}
')
tmp=$(brain_mktemp)
jq --argjson v "$merged_g" '.declarative.project_groups = $v' \
  "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"

# ── 9. Settings / keybindings / MCP (structured config — deep merge, no LLM) ─
tmp=$(brain_mktemp)
jq -s '
  def deep_merge:
    if   (.[0] | type) == "object" and (.[1] | type) == "object" then
      .[0] as $a | .[1] as $b |
      ($a | keys) + ($b | keys) | unique | map(
        . as $k |
        if ($a | has($k)) and ($b | has($k)) then {($k): ([$a[$k], $b[$k]] | deep_merge)}
        elif ($a | has($k)) then {($k): $a[$k]}
        else {($k): $b[$k]}
        end
      ) | add // {}
    elif (.[0] | type) == "array" and (.[1] | type) == "array" then
      (.[0] + .[1]) | unique
    else .[1] // .[0] end;

  .[0] as $cur | .[1] as $other |
  $cur
  | .environmental.settings.content   = ([$cur.environmental.settings.content   // {}, $other.environmental.settings.content   // {}] | deep_merge)
  | .environmental.keybindings.content = ([$cur.environmental.keybindings.content // [], $other.environmental.keybindings.content // []] | deep_merge)
  | .environmental.mcp_servers         = (($cur.environmental.mcp_servers // {}) * ($other.environmental.mcp_servers // {}))
' "$OUTPUT" "$OTHER" > "$tmp" && mv "$tmp" "$OUTPUT"

# ── 10. Group bidirectional sync ──────────────────────────────────────────────
# Run after all same-key merges. For each group:
#   - File only one member has → copy to all others (no LLM)
#   - File multiple members have with same content → copy to missing members (no LLM)
#   - File multiple members have with different content → LLM merge, apply to all

# Union groups from merged output + local config
final_groups=$(jq '.declarative.project_groups // {}' "$OUTPUT")
if [ -f "${HOME}/.claude/brain-groups.json" ]; then
  local_g=$(jq '.' "${HOME}/.claude/brain-groups.json" 2>/dev/null || echo "{}")
  final_groups=$(jq -n --argjson a "$final_groups" --argjson b "$local_g" '
    ($a | keys) + ($b | keys) | unique | map(
      . as $g | {($g): ([($a[$g] // [])[], ($b[$g] // [])[]] | unique)}
    ) | add // {}
  ')
fi

if [ "$(echo "$final_groups" | jq 'length')" -gt 0 ]; then
  cur_mem=$(jq '.experiential.auto_memory // {}' "$OUTPUT")

  while IFS= read -r gname; do
    [ -z "$gname" ] && continue

    # Members present in merged memory
    mapfile -t members < <(echo "$final_groups" | jq -r --arg g "$gname" '.[$g][]' 2>/dev/null)
    existing=()
    for m in "${members[@]:-}"; do
      [ -z "$m" ] && continue
      echo "$cur_mem" | jq -e --arg m "$m" 'has($m)' > /dev/null 2>&1 && existing+=("$m")
    done
    [ "${#existing[@]}" -lt 2 ] && continue

    # All filenames across all existing members
    all_fnames=$(
      for m in "${existing[@]}"; do
        echo "$cur_mem" | jq -r --arg m "$m" '.[$m] | keys[]' 2>/dev/null
      done | sort -u
    )

    while IFS= read -r fname; do
      [ -z "$fname" ] && continue

      # Collect (member, content) pairs for this filename
      has_m=(); contents=()
      for m in "${existing[@]}"; do
        if echo "$cur_mem" | jq -e --arg m "$m" --arg f "$fname" \
            '.[$m] | has($f)' > /dev/null 2>&1; then
          c=$(jq -rn --argjson mem "$cur_mem" \
            --arg m "$m" --arg f "$fname" '$mem[$m][$f].content // ""')
          has_m+=("$m"); contents+=("$c")
        fi
      done

      if [ "${#has_m[@]}" -eq 0 ]; then
        continue
      fi

      # Check if all present versions are identical
      ref="${contents[0]}"
      all_same=true
      for c in "${contents[@]}"; do [ "$c" != "$ref" ] && all_same=false && break; done

      if $all_same; then
        # All same (or only one has it): copy ref to members that don't have it
        for m in "${existing[@]}"; do
          echo "$cur_mem" | jq -e --arg m "$m" --arg f "$fname" \
            '.[$m] | has($f)' > /dev/null 2>&1 && continue
          cur_mem=$(echo "$cur_mem" | jq \
            --arg m "$m" --arg f "$fname" --arg c "$ref" \
            '.[$m][$f] = {content: $c, hash: "group-synced"}')
        done
      else
        # Conflict within group: sequential LLM merge, then apply to all members
        log_info "LLM: merging group ${gname}/${fname}..."
        mc="${contents[0]}"
        for ((i=1; i<${#contents[@]}; i++)); do
          mc=$(llm_merge_text "group ${gname}/${fname}" "$mc" "${contents[$i]}") \
            || { mc="${contents[0]}"; log_warn "LLM group merge failed for ${gname}/${fname} — using first version."; break; }
        done
        # Apply merged content to all group members (including those that didn't have the file)
        for m in "${existing[@]}"; do
          cur_mem=$(echo "$cur_mem" | jq \
            --arg m "$m" --arg f "$fname" --arg c "$mc" \
            '.[$m][$f] = {content: $c, hash: "merged"}')
        done
      fi
    done <<< "$all_fnames"
  done <<< "$(echo "$final_groups" | jq -r 'keys[]')"

  tmp=$(brain_mktemp)
  jq --argjson v "$cur_mem" '.experiential.auto_memory = $v' \
    "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
fi

log_info "Merge complete."
