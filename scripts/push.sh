#!/usr/bin/env bash
# push.sh — RENAMED to snapshot.sh. This stub exists for backwards compatibility only.
echo "Warning: push.sh is deprecated. Use snapshot.sh instead." >&2
exec "$(dirname "${BASH_SOURCE[0]}")/snapshot.sh" "$@"
