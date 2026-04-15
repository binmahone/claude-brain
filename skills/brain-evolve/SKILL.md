---
name: brain-evolve
description: Analyze accumulated brain memory and propose promotions to CLAUDE.md, rules, or new skills. Makes your brain smarter over time.
---


The user wants to evolve their brain by promoting stable patterns from memory.

## Steps

1. Run the evolution analysis:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evolve.sh"
   ```

2. Read the analysis results from `~/.claude/brain-repo/meta/last-evolve.json`.

3. Present the summary to the user. For each recommendation in `promotions`, present it:

   **For claude_md promotions:**
   - Show the proposed addition
   - Show the reason and confidence
   - Ask: Accept / Skip / Edit first

   **For rule promotions:**
   - Show the proposed rule content
   - Ask: Accept / Skip / Edit first

   **For skill suggestions:**
   - Show the proposed skill
   - Ask: Accept / Skip / Edit first

4. For each entry in `stale_entries`, ask:
   - Archive (remove from memory) / Keep
   - If archived, note in the memory file that it was archived

5. **Before applying any accepted changes**, create a backup:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
   backup_before_import
   ```
   Tell the user: "Backup saved to ~/.claude/brain-backups/."

6. Apply only the changes the user accepted:
   - claude_md: append to ~/.claude/CLAUDE.md
   - rule: write to ~/.claude/rules/<appropriate-name>.md
   - skill: create in ~/.claude/skills/<name>/SKILL.md

7. After all changes are applied:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/snapshot.sh"
   ```

8. Show summary: "Brain evolved: X promotions accepted, Y skipped, Z stale entries archived."
