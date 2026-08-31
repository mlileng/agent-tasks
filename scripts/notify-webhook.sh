#!/usr/bin/env bash
# notify-webhook.sh — posts a one-line JSON message to $AGENT_TASKS_WEBHOOK_URL
# (Slack incoming-webhook compatible). No-op if that env var isn't set.
# Called from .claude/settings.json's Stop hook; failures are swallowed on
# purpose so a dead webhook never breaks an agent run.

set -uo pipefail

[[ -z "${AGENT_TASKS_WEBHOOK_URL:-}" ]] && exit 0

MSG="agent-tasks run finished in $(basename "$PWD") at $(date -u +%FT%TZ)"
printf '{"text": %s}' "$(jq -Rn --arg m "$MSG" '$m')" \
  | curl -s -X POST -H 'Content-Type: application/json' -d @- "$AGENT_TASKS_WEBHOOK_URL" >/dev/null 2>&1

exit 0
