#!/usr/bin/env bash
# complete-task.sh <claimed-task-path> <agent-id> [options]
#
# Marks a claimed task done (or failed), moves it into done/, and optionally
# enqueues the next pipeline stage for the same repo/branch.
#
# Options:
#   --status done|failed        default: done
#   --result '<json>'           freeform result object, merged into the task
#   --next-stage STAGE          if set, create-task.sh is called for the next stage
#   --next-payload '<json>'     payload for the next-stage task (default: this task's result)
#   --next-priority N           priority for the next-stage task (default: same as this task)
#
# Prints the done task's path on stdout, and the next task's path on a
# second line if --next-stage was given.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_cmd jq
require_cmd git

TASK_PATH="${1:?usage: complete-task.sh <claimed-task-path> <agent-id> [options]}"
AGENT_ID="${2:?usage: complete-task.sh <claimed-task-path> <agent-id> [options]}"
shift 2

STATUS="done"
RESULT='{}'
NEXT_STAGE=""
NEXT_PAYLOAD=""
NEXT_PRIORITY=""

while (( $# )); do
  case "$1" in
    --status) STATUS="$2"; shift 2 ;;
    --result) RESULT="$2"; shift 2 ;;
    --next-stage) NEXT_STAGE="$2"; shift 2 ;;
    --next-payload) NEXT_PAYLOAD="$2"; shift 2 ;;
    --next-priority) NEXT_PRIORITY="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$TASK_PATH" ]] || { echo "error: no such task file: $TASK_PATH" >&2; exit 1; }
case "$TASK_PATH" in
  */claimed/"$AGENT_ID"/*) ;;
  *) echo "error: $TASK_PATH is not claimed by $AGENT_ID" >&2; exit 1 ;;
esac

TASK_ID=$(basename "$TASK_PATH" .json)
REPO_DIR=$(dirname "$(dirname "$(dirname "$TASK_PATH")")")   # tasks/<repo>
DEST_DIR="$REPO_DIR/done"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$TASK_ID.json"

do_commit() {
  git mv "$TASK_PATH" "$DEST"
  jq --arg status "$STATUS" --argjson result "$RESULT" --arg agent "$AGENT_ID" --arg ts "$(now_iso)" \
     '.status = $status | .result = $result | .history += [{event: $status, agent: $agent, at: $ts}]' \
     "$DEST" > "$DEST.tmp" && mv "$DEST.tmp" "$DEST"
  git add -A -- "$REPO_DIR"
  git commit -q -m "$STATUS: $TASK_ID by $AGENT_ID"
}

push_with_retry do_commit
echo "$DEST"

if [[ -n "$NEXT_STAGE" && "$STATUS" == "done" ]]; then
  REPO=$(jq -r '.repo' "$DEST")
  BRANCH=$(jq -r '.branch // ""' "$DEST")
  TITLE=$(jq -r '.title' "$DEST")
  PAYLOAD="${NEXT_PAYLOAD:-$(jq -c '.result' "$DEST")}"
  PRIORITY="${NEXT_PRIORITY:-$(jq -r '.priority' "$DEST")}"

  ARGS=(scripts/create-task.sh "$REPO" "$NEXT_STAGE" "$TITLE"
        --priority "$PRIORITY" --payload "$PAYLOAD"
        --depends-on "$TASK_ID" --created-by "$AGENT_ID")
  [[ -n "$BRANCH" ]] && ARGS+=(--branch "$BRANCH")
  "${ARGS[@]}"
fi
