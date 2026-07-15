# Workspace Contract — Agent Dev Container

This file governs every session in this container. It lives at
`/workspace/CLAUDE.md` so it applies to `main/` and every worktree beneath it.

## Layout

```
/workspace/
  main/                # primary clone, default branch — the user's stable view
  worktrees/<branch>/  # one directory per active worktree (yours to manage)
  dev.code-workspace   # multi-root VS Code workspace — keep in sync (see below)
```

## Worktree rules (mandatory)

Worktrees are the first-class way to do feature work here. The user watches
them live in VS Code/Cursor, so visibility rules are not optional.

- **Create** a worktree for each task/feature:
  `git -C /workspace/main worktree add ../worktrees/<name> -b <branch>`
  then link the MCP config into it (Claude Code reads `.mcp.json` only from
  its start directory — without this, MCP tools silently vanish in the
  worktree): `ln -s ../../main/.mcp.json /workspace/worktrees/<name>/.mcp.json`
- **Remove** it after the branch is merged or abandoned:
  `git -C /workspace/main worktree remove ../worktrees/<name> && git -C /workspace/main worktree prune`
- **After every create or remove**, update `folders` in
  `/workspace/dev.code-workspace` to exactly match
  `git -C /workspace/main worktree list`: the `main` entry first, then one
  entry per worktree (`{"path": "worktrees/<name>", "name": "<name>"}`),
  sorted by name. Valid JSON, no trailing commas.
- Do **not** use Claude Code's built-in session worktrees for feature work —
  they live in hidden paths and defeat the visibility requirement.

## Git rules

- Never delete or break `/workspace/main`.
- Never commit to the default branch. All work goes through a feature branch
  in a worktree, pushed with a PR (`gh pr create` or `tea pr create`).
- Treat `main/` as read-mostly: pull/fetch there, develop in worktrees.

## Artifacts outbox — `/artifacts`

`/artifacts` is bind-mounted to the user's Mac and survives container and
volume destruction. Put agent **outputs that aren't code** there: screenshots,
test reports, exports, diagrams, and progress notes (`/artifacts/progress.md`)
you want to outlive this container. The user can open these in Finder
directly. Code never goes there — code exits via git PR only.

## Environment notes

- Egress is firewalled to an allowlist (GitHub, npm, PyPI, Anthropic, apt,
  nodejs.org + `EXTRA_ALLOWED_DOMAINS`). A refused outbound connection is the
  firewall, not a network flake — say so instead of retrying, and ask the
  user to add the domain if it's genuinely needed.
- The host is unreachable except for ports listed in `HOST_MCP_PORTS`.
- Run long tasks inside `tmux` so a dropped editor window never orphans them.
