# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [SYNC_CONCEPTS.md](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)
> for the one-screen overview and anti-patterns (don't treat JSONL as the
> source of truth; don't `bd import` during normal operation; don't
> reach for third-party Dolt hosting before trying the default).

## Working across repositories

Bowser's owner workspace contains two sibling code repositories:

- `../bowser` — public browser, native UI, mod runtime, and desktop releases.
- `../bowser-services` — private website, API, database, and service deployment.

Read the destination repository's `AGENTS.md` before editing there. Work in the
repository that owns the behavior; a task may span both. Continue across these
repositories within the user's authorized task rather than treating the directory
change as a new task or asking for permission solely because it crosses repos.
Public browser contributors do not need access to the private services repository.

Both owner checkouts use one private tracker at `../bowser-tracking/.beads`,
resolved through locally ignored `.beads/redirect` files. Run `bd where` and
`bd prime`, then inspect and claim the relevant issue before starting. Do not
initialize a second database if the shared tracker is missing; report the missing
setup. Use `bd remember` for durable context and retain existing issue IDs.

Use one Beads issue for a coordinated change, labeled `browser`, `services`, or
`shared`. Read the relevant code on both sides of an API contract. Run checks in
each affected repository, record validation in the issue, and report all changed
repositories before closing it. When commits are authorized, keep them separate
per repository and reference the same issue. Use `jj` for version control; existing
commit, push, and deployment authorization rules still apply.

Keep private service code, credentials, database contents, and tracking exports
out of the public browser repository. Dolt synchronization belongs only to the
private tracking repository, never the public browser remote.

Agent sessions spanning both projects need filesystem access to the `bowser`,
`bowser-services`, and `bowser-tracking` directories. These instructions do not
grant sandbox permissions; use the available approval mechanism if access is
blocked. Do not broaden access to unrelated projects.

Use the primary code checkouts rather than creating per-task worktrees. Before
building or installing the browser, check which checkout the running development
or staging runtime actually uses; do not assume it follows a repository rename.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->

## Scope of mod fixes

When discussing or fixing mods, improve **mod creation and management for all
mods**: ModSmith's workflow, runtime contracts, verification, state, and UI.
Treat a reported mod as a reproduction case for a general problem. Do not
hard-code its website, behavior, prompts, or next actions into the product,
or repair that user's generated mod as the task's solution.

Target a specific mod only when the user explicitly requests it **and** that
mod is shipped as part of Bowser core. Apply this rule when reviewing past
fixes as well as when making new ones.

## ModSmith API documentation

When changing APIs exposed to mods, audit the ModSmith guide and MCP schemas
against the implementation, including existing primitives, valid arities,
examples, and asset/rendering limits. Update them in the same change. Use
behavioral tests for API contracts; do not assert prose wording to enforce
this documentation workflow.
