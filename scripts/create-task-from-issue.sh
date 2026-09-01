#!/usr/bin/env bash
# create-task-from-issue.sh <github-issue-url> [stage] [create-task.sh options...]
#
# Fetches a GitHub issue via `gh` and creates a task whose payload carries a
# frozen snapshot of it (title, body, url, labels) — so the agent that
# eventually claims the task doesn't need network/gh access at claim time,
# and the task file is a durable record of exactly what was asked, even if
# the issue is edited later.
#
# <stage> defaults to "implement" if omitted. Anything after it is passed
# straight through to create-task.sh, so you can override the defaults this
# script picks (branch name, priority, etc.) or add ones it doesn't set
# (--depends-on, --created-by).
#
# Examples:
#   scripts/create-task-from-issue.sh https://github.com/octocat/example-repo/issues/7
#   scripts/create-task-from-issue.sh https://github.com/octocat/example-repo/issues/7 review
#   scripts/create-task-from-issue.sh https://github.com/octocat/example-repo/issues/7 \
#     implement --priority 1 --branch fix/issue-7
#
# Assumes gh is installed and authenticated (gh auth status), and that your
# local tasks/<repo>/ directory name matches the GitHub repo name — if it
# doesn't, run create-task.sh directly instead, or rename the local dir.
#
# Uses `gh api` (REST) rather than `gh issue view --json` (GraphQL) — some
# networks/proxies allow REST but block GitHub's GraphQL endpoint, so this is
# the more portable of the two for a corporate environment.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_cmd gh
require_cmd jq
require_cmd git

ISSUE_URL="${1:?usage: create-task-from-issue.sh <github-issue-url> [stage] [create-task.sh options...]}"
shift

STAGE="implement"
if [[ $# -gt 0 && "$1" != -* ]]; then
  STAGE="$1"
  shift
fi
EXTRA_ARGS=("$@")

if [[ "$ISSUE_URL" =~ ^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)/?$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  GH_REPO="${BASH_REMATCH[2]}"
  ISSUE_NUM="${BASH_REMATCH[3]}"
else
  echo "error: expected a URL like https://github.com/<owner>/<repo>/issues/<number>, got: $ISSUE_URL" >&2
  exit 1
fi

ISSUE_JSON=$(gh api "repos/$OWNER/$GH_REPO/issues/$ISSUE_NUM")

TITLE=$(jq -r '.title' <<< "$ISSUE_JSON")
PAYLOAD=$(jq -c '{spec: .body, issue_number: .number, issue_url: .html_url, issue_title: .title, labels: [.labels[].name]}' <<< "$ISSUE_JSON")

echo "fetched issue #$ISSUE_NUM from $OWNER/$GH_REPO: $TITLE" >&2

scripts/create-task.sh "$GH_REPO" "$STAGE" "$TITLE" \
  --payload "$PAYLOAD" \
  --description "$ISSUE_URL" \
  --branch "issue-$ISSUE_NUM" \
  "${EXTRA_ARGS[@]}"
