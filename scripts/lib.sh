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

# True only for an actual non-fast-forward rejection (someone else's push
# landed first) — as opposed to auth failures, network errors, a wrong
# remote URL, etc. `git push` exits 1 for a real rejection and "[rejected]"
# / "non-fast-forward" appear in its stderr; other failures are fatal git
# errors (typically exit 128) with no such marker. Pass the captured stderr.
is_push_race_rejection() {
  [[ "$1" == *"[rejected]"* || "$1" == *"non-fast-forward"* ]]
}

# Push with retry-on-race: pulls, retries the whole caller-supplied commit
# on a rejected push. Caller passes a function name that (re)does the
# filesystem change + `git add` + `git commit`, since a rejected push means
# our working tree may now be stale and the change may need redoing.
#
# Only retries (and discards the local commit via reset) for a genuine race
# — see is_push_race_rejection above. Any other push failure (bad auth, no
# network, wrong remote) stops immediately, prints git's real error, and
# leaves the local commit in place uncommitted-to-remote rather than
# silently retrying into the same wall or discarding real work over a
# problem that pulling and retrying can never fix.
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

    # Note: must not be a bare `push_err=$(git push ...)` statement — under
    # `set -e` that form aborts the whole script on failure before the `if`
    # below ever runs, which would make the "not a race" branch below dead
    # code exactly when it's needed. The `&& ... || ...` form keeps this
    # statement's own exit status 0 either way.
    local push_err push_rc
    push_err=$(git push 2>&1) && push_rc=0 || push_rc=$?
    if (( push_rc == 0 )); then
      return 0
    fi

    if is_push_race_rejection "$push_err"; then
      echo "push rejected (race with another agent), retrying ($attempt/$max_attempts)..." >&2
      git reset --hard --quiet 'HEAD@{1}' 2>/dev/null || git reset --hard --quiet HEAD~1
      continue
    fi

    echo "error: git push failed for a reason other than a claim race — not retrying. Your commit is still local; fix the problem below, then 'git push' by hand:" >&2
    echo "$push_err" >&2
    return 1
  done

  echo "error: failed to push after $max_attempts attempts (heavy contention?)" >&2
  return 1
}
