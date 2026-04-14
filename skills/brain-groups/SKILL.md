---
name: brain-groups
description: Manage project memory groups — share memory bidirectionally between related projects at merge time.
---

The user wants to manage brain project groups.

Groups let two or more projects with different paths share memory. At merge time,
all members of a group receive the union of each other's memory files.
Each project still has its own independent key in the snapshot — the group sync
is an extra step that runs after all same-key merges are complete.

Config lives at `~/.claude/brain-groups.json`.
Members are stored as **encoded path keys** (the directory name under `~/.claude/projects/`,
e.g. `-home-alice-spark`). The skill shows decoded paths for readability.

Arguments: $ARGUMENTS

## Subcommands

- (empty) or `list`                    → list all groups with decoded paths
- `add <group-name> <path1> [path2…]`  → create group or add members (paths or basenames)
- `remove <group-name> <path>`         → remove one member
- `delete <group-name>`                → delete entire group

---

### list

1. Read groups: `cat ~/.claude/brain-groups.json 2>/dev/null || echo "{}"`

2. For each group, decode member keys for display:
   ```bash
   # Each encoded key like -home-alice-spark decodes by replacing - with /
   # then taking the full path. Use project_name_from_encoded logic or just
   # show both: "spark  (-home-alice-spark)"
   ```

3. Also show local projects NOT in any group:
   ```bash
   find ~/.claude/projects -maxdepth 2 -name memory -type d 2>/dev/null | \
     while read -r d; do basename "$(dirname "$d")"; done
   ```
   Cross-reference against all group members and list ungrouped ones.

---

### add <group-name> <path1> [path2…]

Each argument can be:
- A full absolute path: `/home/alice/spark` → encoded as `-home-alice-spark`
- A basename: `spark` → look up in `~/.claude/projects/` for a directory whose decoded
  name ends with `/spark`. If multiple matches, list them and ask the user to clarify.

1. Resolve each argument to an encoded key:
   ```bash
   # For each arg, find the matching encoded dir under ~/.claude/projects/
   find ~/.claude/projects -maxdepth 1 -mindepth 1 -type d | while read -r d; do
     encoded=$(basename "$d")
     # decoded path is encoded with - replacing /
     # check if it ends with the given basename or matches the full path
   done
   ```

2. Read current groups and add members (union — no duplicates):
   ```bash
   groups=$(cat ~/.claude/brain-groups.json 2>/dev/null || echo "{}")
   new_members='["-home-alice-spark", "-home-alice-spark2"]'  # resolved encoded keys
   groups=$(echo "$groups" | jq --arg g "<group-name>" --argjson m "$new_members" '
     .[$g] = ((.[$g] // []) + $m | unique)
   ')
   echo "$groups" > ~/.claude/brain-groups.json
   ```

3. Confirm with decoded names: "Group 'spark-all' now contains: /home/alice/spark, /home/alice/spark2"
   Remind: "Run /brain-sync to apply the grouping to the consolidated brain."

---

### remove <group-name> <path>

1. Resolve argument to encoded key (same as add).

2. Remove from group:
   ```bash
   groups=$(echo "$groups" | jq --arg g "<group-name>" --arg m "<encoded-key>" '
     if has($g) then .[$g] = [.[$g][] | select(. != $m)] else . end
   ')
   # Delete group if now empty
   groups=$(echo "$groups" | jq --arg g "<group-name>" '
     if (.[$g] | length) == 0 then del(.[$g]) else . end
   ')
   echo "$groups" > ~/.claude/brain-groups.json
   ```

3. Confirm and remind to run /brain-sync.

---

### delete <group-name>

```bash
groups=$(cat ~/.claude/brain-groups.json 2>/dev/null || echo "{}")
groups=$(echo "$groups" | jq --arg g "<group-name>" 'del(.[$g])')
echo "$groups" > ~/.claude/brain-groups.json
```

Confirm: "Group '<group-name>' deleted." Remind to run /brain-sync.
