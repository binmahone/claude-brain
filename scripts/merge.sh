#!/usr/bin/env bash
# merge.sh — Brain merge with 3-way support (falls back to 2-way).
#
# 3-way merge (when ANCESTOR is available):
#   Only ancestor→consolidated changed  → incoming: take consolidated
#   Only ancestor→snapshot changed       → outgoing: take snapshot
#   Both changed, same result            → no conflict
#   Both changed, different result       → real conflict (keep consolidated, record)
#   File new on one side only            → include it
#
# 2-way merge (fallback, no ancestor):
#   Only one side has a file  → include it (no conflict)
#   Both sides, same content  → keep as-is
#   Both sides, different     → keep consolidated, record conflict
#
# Conflicts are written to $CONFLICTS_FILE (brain-conflicts.json) for later
# resolution by the /brain-conflicts skill.
#
# Usage: merge.sh BASE OTHER OUTPUT [ANCESTOR]
#   BASE     — consolidated brain (other machines' merged state)
#   OTHER    — current machine's fresh snapshot
#   OUTPUT   — destination path for merged result
#   ANCESTOR — (optional) baseline from last successful sync; enables 3-way merge
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BASE="$1"
OTHER="$2"
OUTPUT="$3"
ANCESTOR="${4:-}"

if [ ! -f "$BASE" ] || [ ! -f "$OTHER" ]; then
  log_error "merge.sh: input files not found."
  exit 1
fi

THREE_WAY=false
if [ -n "$ANCESTOR" ] && [ -f "$ANCESTOR" ]; then
  THREE_WAY=true
  log_info "3-way merge enabled (baseline available)."
else
  log_info "2-way merge (no baseline — first sync or migration)."
fi

# ── Conflict tracking ─────────────────────────────────────────────────────────
CONFLICTS_FILE="${CONFLICTS_FILE:-${HOME}/.claude/brain-conflicts.json}"

record_conflict() {
  local section="$1" filename="$2" base_content="$3" other_content="$4"
  local machine_id machine_name timestamp
  machine_id=$(jq -r '.machine.id // "unknown"' "$OTHER")
  machine_name=$(jq -r '.machine.name // "unknown"' "$OTHER")
  timestamp=$(now_iso)

  if [ ! -f "$CONFLICTS_FILE" ]; then
    echo '{"conflicts":[]}' > "$CONFLICTS_FILE"
  fi

  local entry
  entry=$(jq -n \
    --arg s "$section" --arg f "$filename" \
    --arg bc "$base_content" --arg oc "$other_content" \
    --arg mid "$machine_id" --arg mn "$machine_name" \
    --arg ts "$timestamp" \
    '{
      section: $s,
      filename: $f,
      consolidated_content: $bc,
      local_content: $oc,
      machine_id: $mid,
      machine_name: $mn,
      detected_at: $ts,
      resolved: false
    }')

  local tmp_cf
  tmp_cf=$(mktemp "${CONFLICTS_FILE}.XXXXXX")
  jq --argjson e "$entry" '.conflicts = [$e] + .conflicts' \
    "$CONFLICTS_FILE" > "$tmp_cf" && mv "$tmp_cf" "$CONFLICTS_FILE"

  log_info "Conflict detected: ${section}/${filename} — deferred for resolution."
}

report_conflicts() {
  if [ -f "$CONFLICTS_FILE" ]; then
    local count
    count=$(jq '[.conflicts[] | select(.resolved != true)] | length' "$CONFLICTS_FILE")
    if [ "$count" -gt 0 ]; then
      log_info "${count} conflict(s) pending. Run /brain-conflicts to resolve."
    fi
  fi
}

# ── Quick exit if identical ────────────────────────────────────────────────────
if [ "$(file_hash "$BASE")" = "$(file_hash "$OTHER")" ]; then
  log_info "No differences — skipping merge."
  cp "$BASE" "$OUTPUT"
  exit 0
fi

# ── Merge a set of files (3-way or 2-way) ────────────────────────────────────
# Args: BASE_JSON OTHER_JSON LABEL [ANCESTOR_JSON]
# Each JSON is: { "filename": { "content": "...", "hash": "..." } }
merge_fileset() {
  local base_json="$1" other_json="$2" label="$3" ancestor_json="${4:-\{\}}"

  if $THREE_WAY && [ "$ancestor_json" != "{}" ]; then
    # ── 3-way merge ──────────────────────────────────────────────────────
    # For each file across all three versions, decide based on who changed it.
    local merged
    merged=$(jq -n \
      --argjson a "$ancestor_json" --argjson b "$base_json" --argjson o "$other_json" '
      (($a | keys) + ($b | keys) + ($o | keys) | unique) | map(. as $k |
        ($a[$k].hash // null) as $ah |
        ($b[$k].hash // null) as $bh |
        ($o[$k].hash // null) as $oh |

        if ($bh == $oh) then
          # Same on both sides — no conflict, take either (prefer consolidated)
          if ($b | has($k)) then {($k): $b[$k]}
          elif ($o | has($k)) then {($k): $o[$k]}
          else empty end
        elif ($ah == $bh) then
          # Only snapshot changed — outgoing, take snapshot
          if ($o | has($k)) then {($k): $o[$k]}
          else empty end
        elif ($ah == $oh) then
          # Only consolidated changed — incoming, take consolidated
          if ($b | has($k)) then {($k): $b[$k]}
          else empty end
        elif ($ah == null) then
          # File did not exist in ancestor — both added independently
          # Keep consolidated, record conflict below
          if ($b | has($k)) then {($k): $b[$k]}
          elif ($o | has($k)) then {($k): $o[$k]}
          else empty end
        else
          # Both changed differently — real conflict, keep consolidated
          if ($b | has($k)) then {($k): $b[$k]}
          elif ($o | has($k)) then {($k): $o[$k]}
          else empty end
        end
      ) | add // {}
    ')

    # Detect real conflicts: both sides changed from ancestor, differently
    local conflict_keys
    conflict_keys=$(jq -rn \
      --argjson a "$ancestor_json" --argjson b "$base_json" --argjson o "$other_json" '
      [($a | keys) + ($b | keys) + ($o | keys) | unique | .[] | select(. as $k |
        (($a[$k].hash // null) as $ah |
         ($b[$k].hash // null) as $bh |
         ($o[$k].hash // null) as $oh |
         # Both changed from ancestor, and differently from each other
         ($ah != $bh) and ($ah != $oh) and ($bh != $oh) and ($bh != null) and ($oh != null))
      )] | .[]
    ')

    while IFS= read -r key; do
      [ -z "$key" ] && continue
      local bc oc
      bc=$(jq -rn --argjson b "$base_json" --arg k "$key" '$b[$k].content // ""')
      oc=$(jq -rn --argjson o "$other_json" --arg k "$key" '$o[$k].content // ""')
      record_conflict "$label" "$key" "$bc" "$oc"
    done <<< "$conflict_keys"

    echo "$merged"
  else
    # ── 2-way merge (fallback) ───────────────────────────────────────────
    local merged
    merged=$(jq -n --argjson b "$base_json" --argjson o "$other_json" '
      ($b | keys) + ($o | keys) | unique | map(. as $k |
        if ($b | has($k)) then {($k): $b[$k]}
        else {($k): $o[$k]}
        end
      ) | add // {}
    ')

    local conflict_keys
    conflict_keys=$(jq -rn --argjson b "$base_json" --argjson o "$other_json" '
      [ ($b | keys)[] | select(. as $k |
          ($o | has($k)) and ($b[$k].content != $o[$k].content)
        )
      ] | .[]
    ')

    while IFS= read -r key; do
      [ -z "$key" ] && continue
      local bc oc
      bc=$(jq -rn --argjson b "$base_json" --arg k "$key" '$b[$k].content // ""')
      oc=$(jq -rn --argjson o "$other_json" --arg k "$key" '$o[$k].content // ""')
      record_conflict "$label" "$key" "$bc" "$oc"
    done <<< "$conflict_keys"

    echo "$merged"
  fi
}

# ── Helper: get section from a brain JSON file ────────────────────────────────
get_section() {
  local file="$1" jq_path="$2"
  if [ -f "$file" ]; then
    jq --arg p "$jq_path" 'getpath($p | split(".")) // {}' "$file"
  else
    echo '{}'
  fi
}

# ── Start with BASE as foundation ─────────────────────────────────────────────
cp "$BASE" "$OUTPUT"

# ── 1. CLAUDE.md ──────────────────────────────────────────────────────────────
bc=$(jq -r '.declarative.claude_md.content // ""' "$BASE")
oc=$(jq -r '.declarative.claude_md.content // ""' "$OTHER")
ac=""
if $THREE_WAY; then
  ac=$(jq -r '.declarative.claude_md.content // ""' "$ANCESTOR")
fi

if [ -n "$oc" ] && [ "$bc" != "$oc" ]; then
  if $THREE_WAY; then
    if [ "$ac" = "$bc" ]; then
      # Only local changed — take local (outgoing)
      mc="$oc"
    elif [ "$ac" = "$oc" ]; then
      # Only consolidated changed — take consolidated (incoming)
      mc="$bc"
    else
      # Both changed — real conflict
      record_conflict "claude_md" "CLAUDE.md" "$bc" "$oc"
      mc="$bc"
    fi
  else
    if [ -z "$bc" ]; then
      mc="$oc"
    else
      record_conflict "claude_md" "CLAUDE.md" "$bc" "$oc"
      mc="$bc"
    fi
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

  bs=$(get_section "$BASE" "$jq_path")
  os=$(get_section "$OTHER" "$jq_path")
  as="{}"
  if $THREE_WAY; then
    as=$(get_section "$ANCESTOR" "$jq_path")
  fi
  ms=$(merge_fileset "$bs" "$os" "$label" "$as")

  tmp=$(brain_mktemp)
  jq --arg p "$jq_path" --argjson v "$ms" 'setpath($p | split("."); $v)' \
    "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
done

# ── 6. Auto memory (per project — context isolation) ──────────────────────────
base_mem=$(jq '.experiential.auto_memory // {}' "$BASE")
other_mem=$(jq '.experiential.auto_memory // {}' "$OTHER")
ancestor_mem="{}"
if $THREE_WAY; then
  ancestor_mem=$(jq '.experiential.auto_memory // {}' "$ANCESTOR")
fi

all_proj=$(jq -rn --argjson b "$base_mem" --argjson o "$other_mem" --argjson a "$ancestor_mem" \
  '($b | keys) + ($o | keys) + ($a | keys) | unique | .[]')

merged_mem="{}"
while IFS= read -r proj; do
  [ -z "$proj" ] && continue
  bp=$(jq -n --argjson m "$base_mem"     --arg k "$proj" '$m[$k] // {}')
  op=$(jq -n --argjson m "$other_mem"    --arg k "$proj" '$m[$k] // {}')
  ap=$(jq -n --argjson m "$ancestor_mem" --arg k "$proj" '$m[$k] // {}')
  mp=$(merge_fileset "$bp" "$op" "memory/${proj}" "$ap")
  merged_mem=$(jq -n --argjson acc "$merged_mem" --arg k "$proj" --argjson v "$mp" \
    '$acc + {($k): $v}')
done <<< "$all_proj"

tmp=$(brain_mktemp)
jq --argjson v "$merged_mem" '.experiential.auto_memory = $v' \
  "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"

# ── 7. Agent memory (per agent — context isolation) ───────────────────────────
base_amem=$(jq '.experiential.agent_memory // {}' "$BASE")
other_amem=$(jq '.experiential.agent_memory // {}' "$OTHER")
ancestor_amem="{}"
if $THREE_WAY; then
  ancestor_amem=$(jq '.experiential.agent_memory // {}' "$ANCESTOR")
fi

all_agents=$(jq -rn --argjson b "$base_amem" --argjson o "$other_amem" --argjson a "$ancestor_amem" \
  '($b | keys) + ($o | keys) + ($a | keys) | unique | .[]')

merged_amem="{}"
while IFS= read -r agent; do
  [ -z "$agent" ] && continue
  ba=$(jq -n --argjson m "$base_amem"     --arg k "$agent" '$m[$k] // {}')
  oa=$(jq -n --argjson m "$other_amem"    --arg k "$agent" '$m[$k] // {}')
  aa=$(jq -n --argjson m "$ancestor_amem" --arg k "$agent" '$m[$k] // {}')
  ma=$(merge_fileset "$ba" "$oa" "agent-memory/${agent}" "$aa")
  merged_amem=$(jq -n --argjson acc "$merged_amem" --arg k "$agent" --argjson v "$ma" \
    '$acc + {($k): $v}')
done <<< "$all_agents"

tmp=$(brain_mktemp)
jq --argjson v "$merged_amem" '.experiential.agent_memory = $v' \
  "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"

# ── 8. Project groups (config union — no conflict possible) ──────────────────
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

# ── 9. Settings / keybindings / MCP (structured config — deep merge) ─────────
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

    mapfile -t members < <(echo "$final_groups" | jq -r --arg g "$gname" '.[$g][]' 2>/dev/null)
    existing=()
    for m in "${members[@]:-}"; do
      [ -z "$m" ] && continue
      echo "$cur_mem" | jq -e --arg m "$m" 'has($m)' > /dev/null 2>&1 && existing+=("$m")
    done
    [ "${#existing[@]}" -lt 2 ] && continue

    all_fnames=$(
      for m in "${existing[@]}"; do
        echo "$cur_mem" | jq -r --arg m "$m" '.[$m] | keys[]' 2>/dev/null
      done | sort -u
    )

    while IFS= read -r fname; do
      [ -z "$fname" ] && continue

      has_m=(); contents=()
      for m in "${existing[@]}"; do
        if echo "$cur_mem" | jq -e --arg m "$m" --arg f "$fname" \
            '.[$m] | has($f)' > /dev/null 2>&1; then
          c=$(jq -rn --argjson mem "$cur_mem" \
            --arg m "$m" --arg f "$fname" '$mem[$m][$f].content // ""')
          has_m+=("$m"); contents+=("$c")
        fi
      done

      [ "${#has_m[@]}" -eq 0 ] && continue

      ref="${contents[0]}"
      all_same=true
      for c in "${contents[@]}"; do [ "$c" != "$ref" ] && all_same=false && break; done

      if $all_same; then
        for m in "${existing[@]}"; do
          echo "$cur_mem" | jq -e --arg m "$m" --arg f "$fname" \
            '.[$m] | has($f)' > /dev/null 2>&1 && continue
          cur_mem=$(echo "$cur_mem" | jq \
            --arg m "$m" --arg f "$fname" --arg c "$ref" \
            '.[$m][$f] = {content: $c, hash: "group-synced"}')
        done
      else
        record_conflict "group/${gname}" "$fname" "${contents[0]}" "${contents[1]}"
        mc="${contents[0]}"
        for m in "${existing[@]}"; do
          cur_mem=$(echo "$cur_mem" | jq \
            --arg m "$m" --arg f "$fname" --arg c "$mc" \
            '.[$m][$f] = {content: $c, hash: "conflict-pending"}')
        done
      fi
    done <<< "$all_fnames"
  done <<< "$(echo "$final_groups" | jq -r 'keys[]')"

  tmp=$(brain_mktemp)
  jq --argjson v "$cur_mem" '.experiential.auto_memory = $v' \
    "$OUTPUT" > "$tmp" && mv "$tmp" "$OUTPUT"
fi

# ── Report conflicts ──────────────────────────────────────────────────────────
report_conflicts

log_info "Merge complete."
