#!/usr/bin/env bash
# list-tasks.sh [repo] [status]
#
# Prints a table of tasks: id, repo, stage, status, priority, title.
# status filters to pending|claimed|done|failed; omit for everything.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required." >&2; exit 1; }; }
require_cmd jq

REPO_FILTER="${1:-}"
STATUS_FILTER="${2:-}"

SEARCH_ROOT="tasks"
[[ -n "$REPO_FILTER" ]] && SEARCH_ROOT="tasks/$REPO_FILTER"

printf '%-20s %-18s %-10s %-9s %-4s %s\n' "ID" "REPO" "STAGE" "STATUS" "PRI" "TITLE"
find "$SEARCH_ROOT" -type f -name '*.json' 2>/dev/null | sort | while read -r f; do
  st=$(jq -r '.status' "$f")
  [[ -n "$STATUS_FILTER" && "$st" != "$STATUS_FILTER" ]] && continue
  jq -r '[.id, .repo, .stage, .status, (.priority|tostring), .title] | @tsv' "$f" \
    | awk -F'\t' '{printf "%-20s %-18s %-10s %-9s %-4s %s\n", $1, $2, $3, $4, $5, $6}'
done
