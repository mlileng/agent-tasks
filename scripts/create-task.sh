#!/usr/bin/env bash
# create-task.sh <repo> <stage> <title> [options]
#
# Enqueues a new pending task for <repo>/<stage>.
#
# Options:
#   --priority N          lower claims first (default 5)
#   --payload '<json>'    freeform input object for the claiming agent
#   --depends-on a,b,c    comma-separated task ids that must be in some done/ before this is claimable
#   --branch NAME         branch in the target repo this task concerns
#   --description TEXT    longer free-text description
#   --created-by WHO      defaults to $USER
#
# Prints the new task's path on stdout.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/lib.sh
require_cmd jq
require_cmd git

REPO="${1:?usage: create-task.sh <repo> <stage> <title> [options]}"
STAGE="${2:?usage: create-task.sh <repo> <stage> <title> [options]}"
TITLE="${3:?usage: create-task.sh <repo> <stage> <title> [options]}"
shift 3

PRIORITY=5
PAYLOAD='{}'
DEPENDS_ON='[]'
BRANCH=""
DESCRIPTION=""
CREATED_BY="${USER:-unknown}"

while (( $# )); do
  case "$1" in
    --priority) PRIORITY="$2"; shift 2 ;;
    --payload) PAYLOAD="$2"; shift 2 ;;
    --depends-on) DEPENDS_ON=$(printf '%s' "$2" | jq -R 'split(",") | map(select(length > 0))'); shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --created-by) CREATED_BY="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

TASK_ID=$(new_task_id)
DEST_DIR="tasks/$REPO/pending"
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/$TASK_ID.json"

jq -n \
  --arg id "$TASK_ID" \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
  --arg stage "$STAGE" \
  --arg title "$TITLE" \
  --arg description "$DESCRIPTION" \
  --argjson priority "$PRIORITY" \
  --argjson payload "$PAYLOAD" \
  --argjson depends_on "$DEPENDS_ON" \
  --arg created_by "$CREATED_BY" \
  --arg now "$(now_iso)" \
  '{
    id: $id, repo: $repo, branch: $branch, stage: $stage, status: "pending",
    title: $title, description: $description, priority: $priority,
    depends_on: $depends_on, payload: $payload, result: {},
    created_at: $now, created_by: $created_by,
    history: [{event: "created", agent: $created_by, at: $now}]
  }' > "$DEST"

do_commit() {
  git add "$DEST"
  git commit -q -m "create: $TASK_ID ($REPO/$STAGE)"
}

push_with_retry do_commit
echo "$DEST"
