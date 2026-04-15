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

3. Check if there are any pending merge conflicts and present them first:
   ```bash
   cat ~/.claude/brain-conflicts.json 2>/dev/null || echo '{"conflicts":[]}'
   ```
   If unresolved conflicts exist, present each one and let the user resolve
   (Keep consolidated / Keep local / Custom / Skip) before proceeding with
   evolution recommendations. This avoids evolving from a conflicted state.

4. Present the summary to the user. For each recommendation in `promotions`, present it:

   **For claude_md promotions:**
   - Show the proposed addition
   - Show the current CLAUDE.md content that it relates to (if any overlap)
   - Show the reason and confidence
   - Ask: Accept / Skip / Edit first

   **For rule promotions:**
   - Show the proposed rule content
   - If a rule with similar name/content already exists, show the existing one for comparison
   - Ask: Accept / Skip / Edit first

   **For skill suggestions:**
   - Show the proposed skill
   - Ask: Accept / Skip / Edit first

5. For each entry in `stale_entries`, ask:
   - Archive (remove from memory) / Keep
   - If archived, note in the memory file that it was archived

6. **Before applying any accepted changes**, create a backup:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
   backup_before_import
   ```
   Tell the user: "Backup saved to ~/.claude/brain-backups/."

7. Apply only the changes the user accepted:
   - claude_md: append to ~/.claude/CLAUDE.md
   - rule: write to ~/.claude/rules/<appropriate-name>.md
   - skill: create in ~/.claude/skills/<name>/SKILL.md

8. Show summary: "Brain evolved: X promotions accepted, Y skipped, Z stale entries archived, N conflicts resolved."
   Remind the user: "Run /brain-sync to push these changes to other machines."
