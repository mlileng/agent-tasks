#!/usr/bin/env bash
# claim-task.sh <agent-id> [--stage STAGE] [--repo REPO]
#
# Claims the oldest eligible pending task (lowest priority number first, then
# oldest id) by `git mv`-ing it into claimed/<agent-id>/. The mv + commit +
# push is the atomicity mechanism: if another agent claims the same task
# first, our push is rejected as a non-fast-forward, we pull and pick again.
#
# A task is only eligible if every id in its depends_on[] exists as a file
# under some tasks/*/done/ directory.
#
# Prints the claimed task's new path on stdout on success; exits 1 with
# nothing on stdout if no eligible task is found.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_cmd jq
require_cmd git

AGENT_ID="${1:?usage: claim-task.sh <agent-id> [--stage STAGE] [--repo REPO]}"
shift

STAGE=""
REPO_FILTER=""
while (( $# )); do
  case "$1" in
    --stage) STAGE="$2"; shift 2 ;;
    --repo) REPO_FILTER="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

MAX_ATTEMPTS=5
ATTEMPT=0

is_eligible() {
  # $1 = path to a pending task json. Checks stage/repo filters and depends_on.
  local f="$1"
  if [[ -n "$STAGE" ]] && ! jq -e --arg s "$STAGE" '.stage == $s' "$f" >/dev/null; then
    return 1
  fi
  local deps
  deps=$(jq -r '.depends_on[]? ' "$f")
  local d
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    if ! find tasks -path "*/done/${d}.json" -print -quit 2>/dev/null | grep -q .; then
      return 1
    fi
  done <<< "$deps"
  return 0
}

while (( ATTEMPT < MAX_ATTEMPTS )); do
  ATTEMPT=$((ATTEMPT + 1))
  has_remote && { git pull --rebase --quiet || true; }

  SEARCH_ROOT="tasks"
  [[ -n "$REPO_FILTER" ]] && SEARCH_ROOT="tasks/$REPO_FILTER"

  BEST=""
  BEST_PRIORITY=999999
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    is_eligible "$f" || continue
    pri=$(jq -r '.priority // 5' "$f")
    if [[ -z "$BEST" ]] || (( pri < BEST_PRIORITY )); then
      BEST="$f"
      BEST_PRIORITY="$pri"
    fi
  done < <(find "$SEARCH_ROOT" -type f -path '*/pending/*.json' 2>/dev/null | sort)

  if [[ -z "$BEST" ]]; then
    echo "no eligible pending task found (stage='${STAGE:-any}', repo='${REPO_FILTER:-any}')" >&2
    exit 1
  fi

  TASK_ID=$(basename "$BEST" .json)
  REPO_DIR=$(dirname "$(dirname "$BEST")")   # tasks/<repo>
  DEST_DIR="$REPO_DIR/claimed/$AGENT_ID"
  mkdir -p "$DEST_DIR"
  DEST="$DEST_DIR/$TASK_ID.json"

  git mv "$BEST" "$DEST"
  jq --arg agent "$AGENT_ID" --arg ts "$(now_iso)" \
     '.status = "claimed" | .history += [{event: "claimed", agent: $agent, at: $ts}]' \
     "$DEST" > "$DEST.tmp" && mv "$DEST.tmp" "$DEST"
  git add -A -- "$REPO_DIR"
  git commit -q -m "claim: $TASK_ID by $AGENT_ID"

  if ! has_remote; then
    # Local-only mode: nothing to race against, one attempt is enough.
    echo "$DEST"
    exit 0
  fi

  # See lib.sh's push_with_retry for why this can't be a bare
  # `PUSH_ERR=$(git push ...)` statement under `set -e`.
  PUSH_ERR=$(git push 2>&1) && PUSH_RC=0 || PUSH_RC=$?
  if [[ $PUSH_RC -eq 0 ]]; then
    echo "$DEST"
    exit 0
  fi

  if is_push_race_rejection "$PUSH_ERR"; then
    echo "push rejected (race with another agent), retrying ($ATTEMPT/$MAX_ATTEMPTS)..." >&2
    git reset --hard --quiet HEAD~1
    continue
  fi

  echo "error: git push failed for a reason other than a claim race — not retrying. Your claim is committed locally but not shared; fix the problem below, then 'git push' by hand to actually claim it:" >&2
  echo "$PUSH_ERR" >&2
  exit 1
done

echo "error: failed to claim a task after $MAX_ATTEMPTS attempts (heavy contention?)" >&2
exit 1
