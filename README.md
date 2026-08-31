# agent-tasks

A phase-1, git-flat-file task queue for running multiple Claude Code agents
as a pipeline (spec → implement → test → review) without you relaying work
between them by hand.

How it works, in one paragraph: tasks are JSON files under
`tasks/<repo>/{pending,claimed,done}/`. Claiming a task is a `git mv` into
`claimed/<agent-id>/` followed by a commit and push; if two agents race for
the same task, only one push lands as a fast-forward, and the loser pulls,
sees the file is already gone, and moves on. That push-rejection is the
entire concurrency control — no database, no lock server. Completing a task
moves it into `done/` and can automatically enqueue the next pipeline stage.

This is a starting scaffold, not a hardened library — read the scripts
(they're short) before trusting them with real work, and see "When to
graduate off this" below for the ceiling on this approach.

## Layout

```
agent-tasks/
  tasks/
    <repo-name>/
      pending/<task-id>.json
      claimed/<agent-id>/<task-id>.json
      done/<task-id>.json
  schema/task.schema.json      # what a task JSON looks like
  scripts/
    lib.sh                     # shared helpers (sourced, not run directly)
    create-task.sh              # enqueue a task
    claim-task.sh                # atomically claim one eligible task
    complete-task.sh             # finish a task, optionally enqueue the next stage
    list-tasks.sh                 # status view across the queue
    run-agent-loop.sh            # unattended poller for cron/systemd
    notify-webhook.sh            # optional Slack/webhook ping on completion
  .claude/
    agents/implementer.md, tester.md, reviewer.md   # example pipeline roles
    settings.json                                     # Stop hook -> notify-webhook.sh
```

One `example-repo/` skeleton is included under `tasks/` so the directory
structure exists in git (git doesn't track empty dirs) — copy that pattern
for each real repo you want to run a pipeline against.

## Setup

1. **Push this repo somewhere all your machines can reach.** It doesn't need
   to be GitHub — a bare repo on your Hetzner box works fine, e.g.:
   ```
   ssh hetzner 'git init --bare /srv/git/agent-tasks.git'
   git remote add origin hetzner:/srv/git/agent-tasks.git
   git push -u origin main
   ```
2. **Lay out target repos as siblings of this checkout**, e.g.
   `~/work/agent-tasks`, `~/work/api-service`, `~/work/lifeos-mcp` — the
   example subagents assume they can `cd ../<target-repo>` and
   `git worktree add` from there. This matches a normal multi-repo layout.
3. **Make sure `jq` and `git` are installed** wherever agents will run
   (`which jq git`).
4. **Add a `tasks/<repo-name>/{pending,claimed,done}` skeleton** for each
   real repo (copy `tasks/example-repo/`, or just run `create-task.sh` once —
   it creates `pending/` for you).
5. **Copy `.claude/agents/*.md` into each target repo's own `.claude/agents/`**
   (or point Claude Code at this repo's `.claude/` via `--add-dir` — your
   call). Adjust the `tools:` allowlist per role before running unattended;
   the shipped examples are deliberately narrow (no arbitrary network access,
   reviewer can't push/merge).
6. **Do the first cycle by hand** before automating anything:
   ```
   scripts/create-task.sh api-service implement "Add health endpoint" \
     --payload '{"spec":"Add GET /health returning 200 OK"}' \
     --branch feature/health-endpoint
   scripts/claim-task.sh implementer-1 --stage implement --repo api-service
   # ... do the work yourself, or run: claude --agent implementer -p "..."
   scripts/complete-task.sh <claimed-path> implementer-1 \
     --result '{"commit":"<sha>"}' --next-stage test
   scripts/list-tasks.sh
   ```
   Confirm the `test` task showed up with `depends_on` pointing at the task
   you just finished, and that `list-tasks.sh` shows the right states, before
   you let anything run unattended.
7. **Automate one stage at a time.** For each (subagent, stage, repo) you
   want running unattended:
   ```
   nohup scripts/run-agent-loop.sh implementer implement api-service 60 &
   ```
   or, better, a systemd unit per instance (`systemctl --user enable
   --now agent-loop@implementer-implement-api-service`) so it survives
   reboots and you get logs via `journalctl`. `run-agent-loop.sh` polls,
   and only spends a `claude -p` call when there's actually a pending task
   for it — it doesn't burn tokens polling.
8. **(Optional) Set `AGENT_TASKS_WEBHOOK_URL`** in the environment the loop
   runs under to get a ping (Slack-compatible webhook) whenever a headless
   run finishes.

## The state machine

`pending` → `claimed/<agent>` → `done` (or `failed`, same directory, check
the `status` field). `complete-task.sh --next-stage X` creates a new
`pending` task in stage X with `depends_on: [this-task-id]`, so it's only
claimable once this one shows up under `done/`. A tester or reviewer that
finds a problem can send work backwards with the same flag
(`--next-stage implement`), which is how the pipeline handles failure
without a human relaying "go fix this."

`scripts/list-tasks.sh [repo] [status]` is your dashboard — run it anytime
to see the whole queue's state. There's no daemon required to view it, it's
just files.

## Safety notes

- `run-agent-loop.sh` runs Claude Code with `--permission-mode acceptEdits`,
  meaning it edits files and runs commands without asking anyone. That's the
  point of "unattended," but it also means the `.claude/agents/*.md`
  `tools:` allowlists are your actual safety boundary, not a human watching.
  Keep them narrow per role (the reviewer role, for instance, has no reason
  to hold write access to the target repo).
- Nothing here merges to a protected branch or pushes to `main` on its own —
  the reviewer role stops at "ready for human," deliberately. Don't remove
  that guardrail without thinking about it.
- Put `tasks/` on its own branch (or in its own repo, which this already is)
  rather than mixed into a product repo's `main` — otherwise every claim/
  complete commit shows up in that repo's history and can trigger its CI.

## When to graduate off this

This scales to roughly a handful of agents claiming every so often. You'll
know you've outgrown it when:

- You're seeing `push rejected, retrying` often enough that agents are
  burning real time on retries (claim contention).
- You want to query the queue ("everything blocked on the reviewer,
  priority > 2") instead of grepping JSON files.
- The tasks repo's git history is growing fast enough to be annoying.

At that point, the natural next step (discussed separately) is a small
Postgres-backed MCP server exposing `claim_task` / `report_result` /
`list_ready_tasks` — the `task.schema.json` fields here were chosen to map
cleanly onto DB columns, so that migration is a rewrite of the four scripts
in `scripts/`, not a redesign of the task shape or the `.claude/agents/*.md`
roles that use them.
