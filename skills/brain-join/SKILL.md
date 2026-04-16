---
name: brain-join
description: Join an existing brain sync network from another machine. Pulls the consolidated brain and merges with any local state.
---


The user wants to join an existing brain network from this machine.

The Git remote URL is provided as: $ARGUMENTS

## Steps

1. Check dependencies (git, jq or python3).

2. Validate the remote URL for security:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
   validate_remote_url "$ARGUMENTS"
   ```
   If the URL appears to point to a PUBLIC repo, warn the user and ask for confirmation.

3. Show current local brain inventory:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/status.sh"
   ```

4. **Check if this machine is already in the network:**
   ```bash
   if [ -f ~/.claude/brain-config.json ] && [ -d ~/.claude/brain-repo ]; then
     EXISTING_REMOTE=$(jq -r '.remote_url // empty' ~/.claude/brain-config.json 2>/dev/null)
     if [ -n "$EXISTING_REMOTE" ]; then
       echo "ALREADY_JOINED: $EXISTING_REMOTE"
     fi
   fi
   ```
   If the machine is already joined:
   - Tell the user: "This machine is already part of the brain network (remote: `<existing_remote>`)."
   - If the remote URL matches `$ARGUMENTS`, suggest: "Run `/brain-sync` to sync with the network."
   - If the remote URL is **different** from `$ARGUMENTS`, warn the user and ask if they want to switch networks (this will overwrite the existing config).
   - **Stop here** unless the user explicitly confirms they want to re-join.

5. **Show security notice:**
   - "Joining a brain network means:"
   - "  - Your local brain data will be PUSHED to the remote repository"
   - "  - Remote brain data (skills, agents, rules) can be IMPORTED to your machine (with your approval)"
   - ""
   - "Only join brain networks you trust — imported skills and agents execute with Claude's permissions."

6. Clone the brain repo:
   ```bash
   git clone "$ARGUMENTS" ~/.claude/brain-repo
   ```
   If the directory exists, do `git -C ~/.claude/brain-repo pull origin main` instead.

7. Check if the network uses encryption:
   ```bash
   # Check for recipients file indicating encryption
   if [ -f ~/.claude/brain-repo/meta/recipients.txt ]; then
     echo "This brain network uses age encryption."
     
     if ! command -v age-keygen &>/dev/null; then
       echo "ERROR: age not found. Install it from https://github.com/FiloSottile/age"
       echo "On macOS: brew install age"
       echo "On Ubuntu/Debian: apt install age"
       exit 1
     fi
     
     echo ""
     echo "You need to set up age encryption to join this network."
     echo "Options:"
     echo "  1. Generate a new age keypair for this machine"
     echo "  2. Use an existing age private key"
     echo ""
     read -p "Generate new keypair? (y/n): " -r generate_key
     
     if [ "$generate_key" = "y" ] || [ "$generate_key" = "Y" ]; then
       # Generate new keypair
       source "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
       IDENTITY_FILE="${HOME}/.claude/brain-age-key.txt"
       age-keygen -o "$IDENTITY_FILE"
       chmod 600 "$IDENTITY_FILE"
       
       # Extract public key
       PUBLIC_KEY=$(grep "# public key:" "$IDENTITY_FILE" | cut -d' ' -f4)
       echo ""
       echo "Generated age keypair. Your public key is:"
       echo "$PUBLIC_KEY"
       echo ""
       echo "IMPORTANT: Share this public key with the brain network owner"
       echo "so they can add it to the recipients file."
       echo ""
       echo "The network owner should run:"
       echo "  echo '$PUBLIC_KEY' >> ~/.claude/brain-repo/meta/recipients.txt"
       echo "  git add meta/recipients.txt && git commit -m 'Add machine: $(hostname)' && git push"
       echo ""
       read -p "Press Enter when the network owner has added your public key..."
       
       # Pull to get updated recipients
       git -C ~/.claude/brain-repo pull origin main
       
       REGISTER_FLAGS="--encrypt"
     else
       echo "Please place your existing age private key at: ~/.claude/brain-age-key.txt"
       echo "Make sure it's readable only by you: chmod 600 ~/.claude/brain-age-key.txt"
       read -p "Press Enter when ready..."
       
       if [ ! -f ~/.claude/brain-age-key.txt ]; then
         echo "ERROR: Age private key not found at ~/.claude/brain-age-key.txt"
         exit 1
       fi
       
       REGISTER_FLAGS="--encrypt"
     fi
   else
     echo "This brain network does not use encryption."
     REGISTER_FLAGS=""
   fi
   ```

8. Register this machine:
   ```bash
   if [ -n "$REGISTER_FLAGS" ]; then
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/register-machine.sh" "$ARGUMENTS" $REGISTER_FLAGS
   else
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/register-machine.sh" "$ARGUMENTS"
   fi
   ```

9. Export local snapshot, commit immediately, then pull --rebase to sync with remote.
   Committing before pull ensures our snapshot is not overwritten by git's merge:
   ```bash
   MACHINE_ID=$(cat ~/.claude/brain-config.json | jq -r '.machine_id')
   mkdir -p ~/.claude/brain-repo/machines/${MACHINE_ID}
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/export.sh" --output ~/.claude/brain-repo/machines/${MACHINE_ID}/brain-snapshot.json

   cd ~/.claude/brain-repo
   git add machines/ meta/
   git commit -m "Join: $(hostname) snapshot"

   git pull --rebase origin main || {
     git rebase --abort 2>/dev/null || true
     echo "WARNING: Could not sync with remote. Continuing with local state."
   }
   ```

10. Merge this machine's snapshot into the consolidated brain (2-way):
   ```bash
   CURRENT_SNAPSHOT="${HOME}/.claude/brain-repo/machines/${MACHINE_ID}/brain-snapshot.json"
   CONSOLIDATED="${HOME}/.claude/brain-repo/consolidated/brain.json"

   mkdir -p ~/.claude/brain-repo/consolidated

   if [ ! -f "$CONSOLIDATED" ]; then
     # No consolidated yet — this machine's snapshot becomes the seed
     cp "$CURRENT_SNAPSHOT" "$CONSOLIDATED"
   else
     # 2-way merge: per-project context isolation, group sync included
     MERGE_TMP=$(mktemp)
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/merge.sh" \
       "$CONSOLIDATED" "$CURRENT_SNAPSHOT" "$MERGE_TMP"
     mv "$MERGE_TMP" "$CONSOLIDATED"
   fi
   ```

11. **Show the user what will be imported before applying.**
    Get the change summary:
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/sync.sh" --summary
    ```
    Present the summary: new/changed rules, skills, agents, memory, settings.
    **If `mcp_servers_added` is non-empty, highlight it.**

12. If there are conflicts, read and present each one inline:
    ```bash
    cat ~/.claude/brain-conflicts.json 2>/dev/null || echo '{"conflicts":[]}'
    ```
    For each unresolved conflict, show both sides and ask the user to choose:
    - **Keep consolidated** / **Keep local** / **Custom** / **Skip**
    Mark resolved conflicts in brain-conflicts.json and update the consolidated brain.

13. **Ask the user for approval**: "Apply these changes to your local Claude Code config and push?"

14. If the user approves, import and push:
    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/import.sh" "$CONSOLIDATED"

    cd ~/.claude/brain-repo
    git add consolidated/
    git commit -m "Join: $(hostname) consolidated brain"
    git push origin main
    ```
    Tell the user: "A backup of your pre-join state was saved to ~/.claude/brain-backups/."

15. If the user declines, skip import. Still commit and push the snapshot only:
    ```bash
    cd ~/.claude/brain-repo
    git push origin main
    ```
    Tell the user:
    "Skipped import. Your machine is registered and snapshot pushed, but no remote changes were applied locally. Run /brain-sync to review and apply later."

16. Confirm success:
    - Show how many machines are now in the network
    - Show what was imported/merged (or note that import was skipped)
    - Note: "Sync is manual — run /brain-sync to pull and apply changes from other machines."
