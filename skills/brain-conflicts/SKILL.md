---
name: brain-conflicts
description: Review and resolve unresolved brain merge conflicts that were skipped during sync/join/evolve.
---


The user wants to resolve pending brain merge conflicts that were deferred earlier.

Note: Conflicts are normally resolved inline during /brain-sync, /brain-join, or
/brain-evolve. This command is a fallback for conflicts that were skipped at that time.

## Steps

1. Read the conflicts file:
   ```bash
   cat ~/.claude/brain-conflicts.json 2>/dev/null || echo '{"conflicts":[]}'
   ```

2. Filter to unresolved conflicts (where `resolved` is not `true`).

3. If no unresolved conflicts, tell the user: "No pending conflicts. Brain is fully synced."

4. For each unresolved conflict, present:
   - The section and filename
   - What the consolidated version says (from other machines)
   - What the local version says (this machine)

   Ask the user to choose:
   - **Keep consolidated**: Use the version from other machines
   - **Keep local**: Use this machine's version
   - **Custom**: Let the user type or edit their own merged content

5. After each resolution:
   - Mark the conflict as `resolved: true` with the chosen resolution in brain-conflicts.json
   - Apply the resolution to the consolidated brain file and corresponding local file

6. After all conflicts are resolved:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/snapshot.sh"
   ```

7. Show summary: "X conflicts resolved. Brain is now fully synced."
