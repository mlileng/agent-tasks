#!/usr/bin/env bash
# run-agent-loop.sh <subagent-name> <stage> <target-repo> [poll-seconds]
#
# A long-lived poller meant to run under cron or systemd (one instance per
# stage/repo pair you want automated, e.g. `implementer implement example-repo`
# and `tester test example-repo` as two separate services). It does NOT loop
# inside a single Claude session — each cycle is a fresh, cheap `claude -p`
# invocation that claims and completes at most one task, so a crash or a bad
# run never leaves a half-finished multi-task session behind.
#
# Layout this assumes: target repos are cloned as siblings of this
# agent-tasks/ checkout (a normal multi-repo dev layout), so the subagent can
# `cd ../<target-repo>` and `git worktree add` from there on its own.
#
# IMPORTANT: this runs Claude Code unattended. --permission-mode below is set
# to acceptEdits, which lets it write/edit/run-tests without asking — that is
# the point (nobody's watching), but it means you are trusting the subagent's
# instructions and tool allowlist to be the actual safety boundary. Review
# .claude/agents/*.md and tighten `tools:` there before pointing this at
# anything that matters. Do not casually widen this to bypassPermissions.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SUBAGENT="${1:?usage: run-agent-loop.sh <subagent-name> <stage> <target-repo> [poll-seconds]}"
STAGE="${2:?usage: run-agent-loop.sh <subagent-name> <stage> <target-repo> [poll-seconds]}"
TARGET_REPO="${3:?usage: run-agent-loop.sh <subagent-name> <stage> <target-repo> [poll-seconds]}"
POLL_SECONDS="${4:-60}"

LOG="run-agent-loop.$SUBAGENT.$TARGET_REPO.log"

echo "$(date -u +%FT%TZ) starting: subagent=$SUBAGENT stage=$STAGE repo=$TARGET_REPO poll=${POLL_SECONDS}s" >> "$LOG"

while true; do
  git pull --rebase --quiet || true

  if find "tasks/$TARGET_REPO/pending" -type f -name '*.json' 2>/dev/null | grep -q .; then
    echo "$(date -u +%FT%TZ) work found, launching claude -p as $SUBAGENT" >> "$LOG"
    claude -p "Claim one eligible task for stage '$STAGE' in repo '$TARGET_REPO' from the agent-tasks queue in the current directory, do the work per your instructions, and complete it. If nothing eligible is found, stop immediately without error." \
      --agent "$SUBAGENT" \
      --permission-mode acceptEdits \
      --output-format json \
      >> "$LOG" 2>&1 || echo "$(date -u +%FT%TZ) claude run exited non-zero, continuing loop" >> "$LOG"
  fi

  sleep "$POLL_SECONDS"
done
