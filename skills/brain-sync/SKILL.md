---
name: brain-sync
description: Manually sync brain with remote. Exports local state, pushes to remote, pulls updates from other machines, merges, and applies.
---


The user wants to manually trigger a full brain sync cycle.

## Steps

1. Check that brain is initialized:
   ```bash
   if [ ! -f ~/.claude/brain-config.json ]; then
     echo "Brain not initialized. Run /brain-init first."
     exit 1
   fi
   ```

2. Run the sync (snapshot + pull + merge + push — does NOT import yet):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh"
   ```

3. Get the change summary:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" --summary
   ```

4. Read the summary JSON. If `has_changes` is false, tell the user:
   "Brain synced. No incoming changes — your local state is up to date."
   **Done — do not proceed further.**

5. If `has_changes` is true, present a summary to the user:
   - List what would change: new/changed rules, skills, agents, CLAUDE.md, etc.
   - **If `mcp_servers_added` is non-empty, highlight it**: "New MCP servers from other machines: <list>. These will be added to ~/.claude.json and give Claude access to new tools."
   - Show conflict count if any
   - **Ask the user for approval**: "Apply these changes to local config and push to remote?"

6. If the user approves, apply changes (backup + import + push):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" --apply
   ```
   Tell the user: "Changes applied and pushed. A backup was saved to ~/.claude/brain-backups/."

7. If the user declines:
   Tell the user: "Skipped. Your local config is unchanged, nothing pushed. Run /brain-sync again when ready."

8. If there are conflicts, suggest: "Run /brain-conflicts to review and resolve."
