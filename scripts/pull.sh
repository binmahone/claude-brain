#!/usr/bin/env bash
# pull.sh — RENAMED to sync.sh. This stub exists for backwards compatibility only.
echo "Warning: pull.sh is deprecated. Use sync.sh instead." >&2
exec "$(dirname "${BASH_SOURCE[0]}")/sync.sh" "$@"
