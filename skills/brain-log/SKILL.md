---
name: brain-log
description: Show brain sync and evolution history.
---


Show the user their brain's sync history.

## Steps

1. Read all per-machine log files:
   ```bash
   for f in ~/.claude/brain-repo/meta/logs/*.json; do
     [ -f "$f" ] && cat "$f"
   done
   ```
   Also check the legacy location for backward compatibility:
   ```bash
   cat ~/.claude/brain-repo/meta/merge-log.json 2>/dev/null
   ```

2. If no log files exist or all are empty, tell the user: "No sync history yet."

3. Otherwise, merge all entries from all machines, sort by timestamp (newest first).
   Default to 20 entries, but if $ARGUMENTS is a number, use that instead.

   Format each entry as:
   ```
   [timestamp] machine_name (action): summary
   ```

   Example:
   ```
   [2026-03-03T12:05:00Z] work-laptop (pull+merge): Merged consolidated brain
   [2026-03-03T11:00:00Z] home-desktop (pull+merge): Merged consolidated brain
   [2026-03-02T09:30:00Z] work-laptop (evolve): Promoted 2 patterns to CLAUDE.md
   ```
