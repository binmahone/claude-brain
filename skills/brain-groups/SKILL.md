---
name: brain-groups
description: Manage project memory groups — cluster differently-named projects under one shared memory key.
---

The user wants to manage brain project groups.

Groups let you merge memory from projects with different names (e.g. "spark" and
"spark2") under one canonical key so they share the same memory across machines.
Config lives at `~/.claude/brain-groups.json`.

Arguments: $ARGUMENTS

## Subcommands

Parse $ARGUMENTS to determine the subcommand:

- (empty)                              → list all groups
- `list`                               → list all groups
- `add <group-name> <proj1> [proj2…]`  → create group or add members
- `remove <group-name> <proj>`         → remove one member from a group
- `delete <group-name>`                → delete an entire group

---

### list (no args or "list")

1. Read the groups file:
   ```bash
   cat ~/.claude/brain-groups.json 2>/dev/null || echo "{}"
   ```

2. If empty `{}`, say: "No project groups configured."
   Otherwise show each group and its members, e.g.:
   ```
   spark-all   →  spark, spark2, spark-core
   my-app      →  myapp, myapp-v2
   ```
   Also show the local project basenames that are NOT in any group:
   ```bash
   # Get all project basenames that have a memory directory
   find ~/.claude/projects -maxdepth 2 -name memory -type d 2>/dev/null | \
     while read -r d; do basename "$(dirname "$d")"; done
   ```
   Decode each directory name to its basename using the same logic as export.sh
   (last segment of the decoded path). List ungrouped ones as "ungrouped projects".

---

### add <group-name> <proj1> [proj2…]

1. Read current groups:
   ```bash
   groups=$(cat ~/.claude/brain-groups.json 2>/dev/null || echo "{}")
   ```

2. Add the projects to the group (union — do not duplicate):
   ```bash
   new_members='["proj1","proj2"]'   # build from arguments
   groups=$(echo "$groups" | jq --arg g "<group-name>" --argjson m "$new_members" '
     .[$g] = ((.[$g] // []) + $m | unique)
   ')
   echo "$groups" > ~/.claude/brain-groups.json
   ```

3. Confirm: "Group '<group-name>' now contains: proj1, proj2, …"
   Remind the user: "Run /brain-sync to apply grouping to the shared brain."

---

### remove <group-name> <proj>

1. Read current groups.

2. Remove the member:
   ```bash
   groups=$(echo "$groups" | jq --arg g "<group-name>" --arg p "<proj>" '
     if has($g) then .[$g] = [.[$g][] | select(. != $p)] else . end
   ')
   ```

3. If the group is now empty, delete it:
   ```bash
   groups=$(echo "$groups" | jq --arg g "<group-name>" '
     if (.[$g] | length) == 0 then del(.[$g]) else . end
   ')
   ```

4. Save and confirm.

---

### delete <group-name>

1. Read current groups.

2. Delete the key:
   ```bash
   groups=$(echo "$groups" | jq --arg g "<group-name>" 'del(.[$g])')
   echo "$groups" > ~/.claude/brain-groups.json
   ```

3. Confirm: "Group '<group-name>' deleted."
   Remind the user: "Run /brain-sync to apply the change."
