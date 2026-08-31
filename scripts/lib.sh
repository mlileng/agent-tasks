#!/usr/bin/env bash
# Shared helpers for the task-queue scripts. Sourced, not run directly.

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: '$1' is required but not installed." >&2; exit 1; }
}

now_iso() { date -u +%FT%TZ; }

has_remote() {
  git remote get-url origin >/dev/null 2>&1
}

new_task_id() {
  # YYYYMMDD-HHMMSS-<4 hex chars>, sorts chronologically as plain text.
  local suffix
  suffix=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
  echo "$(date -u +%Y%m%d-%H%M%S)-${suffix}"
}

# Push with retry-on-race: pulls, retries the whole caller-supplied commit
# on a rejected push. Caller passes a function name that (re)does the
# filesystem change + `git add` + `git commit`, since a rejected push means
# our working tree may now be stale and the change may need redoing.
push_with_retry() {
  local commit_fn="$1"
  local max_attempts="${2:-5}"
  local attempt=0

  if ! has_remote; then
    # No origin configured: single-machine / local-only mode. There's
    # nothing to race against, so just commit once and stop — attempting a
    # push here would fail for an unrelated reason (no push destination) and
    # get misread as a race by the retry loop below, which is the bug this
    # guard exists to avoid.
    "$commit_fn"
    return $?
  fi

  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    git pull --rebase --quiet || true

    "$commit_fn" || return 1

    if git push --quiet 2>/dev/null; then
      return 0
    fi

    echo "push rejected (race with another agent), retrying ($attempt/$max_attempts)..." >&2
    git reset --hard --quiet 'HEAD@{1}' 2>/dev/null || git reset --hard --quiet HEAD~1
  done

  echo "error: failed to push after $max_attempts attempts (heavy contention?)" >&2
  return 1
}
