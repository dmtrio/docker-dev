## Serena (semantic code tools)

- **Serena is rooted at ONE project at a time and defaults to `/workspace/main`.**
  Before using it on worktree code, call `activate_project <worktree-path>` —
  otherwise reads and *edits* silently target `main`, not your worktree. Do this
  at the START of each phase, right after `git worktree add`.
- **Use Serena for reading/tracing first** — this is its highest-value use:
  `get_symbols_overview` to map a file, `find_symbol … include_body` to pull just
  the symbol you need, `find_referencing_symbols` to trace callers. Targeted
  symbol reads beat grep + reading whole files, and docstrings it surfaces often
  hand you the design (e.g. a guard condition).
- **Structure-aware edits** (`replace_symbol_body`, `insert_after_symbol`,
  `replace_content`) are reliable once the right project is active, and good for
  the same edit across several files. The harness still requires a prior Read
  before its own Edit tool, so mixing Serena reads with native edits is expected
  — don't fight it.
- Serena's line numbers are **0-based**.
- **For Serena-heavy code work in a worktree, prefer delegating to
  `cursor-agent -p` launched from inside that worktree.** cursor's MCP config
  roots Serena at `$PWD`, so it gets worktree-correct symbols automatically with
  no `activate_project` step — smoother than the Claude Code + Serena pairing for
  multi-worktree work. (`cursor-agent mcp list` should show `serena: ready`.)
