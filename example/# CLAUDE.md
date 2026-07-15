# CLAUDE.md — Gatekeeper working agreement

Rules for working in this repo. These are requirements, not suggestions.

## Running the game locally

Three processes, started in order. No Docker in the dev container — run them
directly with `uv` / `npm`.

One-time setup (installs the optional `embeddings` extra that victory /
`adjudicate` need — `sentence-transformers` + `numpy`):

```bash
uv sync --all-packages --extra embeddings
```

1. **Recordkeeper** (MCP game-state server, `:8400`):
   ```bash
   uv run --no-sync python -m recordkeeper.server
   ```
2. **Orchestrator** (FastAPI + agents, `:8500`) — needs the model env, so load
   `.env`; it defaults to `RECORDKEEPER_URL=http://127.0.0.1:8400/mcp`:
   ```bash
   uv run --no-sync --env-file .env python -m orchestrator.app
   ```
3. **Frontend** (`frontend-next/`, Quasar dev server, `:9000`) — proxies
   `/games` → `127.0.0.1:8500`:
   ```bash
   cd frontend-next && npm install && npx quasar dev
   ```

- **Use `frontend-next/` — the active UI.** The older `frontend/` (Vite) is
  **deprecated**; don't run or build against it.
- **Dev prompt playground (`/dev/prompt-playground`)** is gated by an API key:
  set `GATEKEEPER_DEV_API_KEY` in the orchestrator's env and type the same value
  into the page's "Dev API key" field. Unset ⇒ the `/dev` endpoints return 503
  (disabled); a wrong/missing key ⇒ 401. Plain `/games` play needs no key.
- Open the app at the LAN IP (e.g. `http://192.168.35.81:9000`), not
  `localhost`, when testing via the browser MCP.
- **Always launch the Python services with `uv run --no-sync`.** A plain
  `uv run` re-syncs the venv to default deps and **prunes the `embeddings`
  extra**, so `attempt_victory` / `adjudicate` then die with `No module named
'numpy'` (the embeddings tests are skipped when the extra is absent, so the
  suite won't catch it).
- **Restart both Python services after pulling / switching branches.** A
  long-running dev server outlives code changes; a version mismatch between
  recordkeeper and orchestrator surfaces as Pydantic validation errors on the
  MCP boundary (e.g. `Failed to validate tool result for attempt_victory` when
  one side has the old category-based `VictoryResult.breakdown` and the other
  the RIASEC one). When in doubt, kill and relaunch both on current code.
- Launch detached (e.g. `setsid nohup … &`) so the servers survive the session.
- Smoke the stack without the UI: `curl -X POST http://127.0.0.1:8500/games
-H 'Content-Type: application/json' -d '{}'` should return a new game with
  `starting_villagers`.

## Planning & logging

- **Always work off a PLN.** Substantive work follows a plan of record (the
  `PLN - …` notes in the Obsidian vault, `Projects/Gatekeeper/`). Don't start
  building without an accepted PLN.
- **Small bugfixes get a LOG, not a PLN.** For a small/isolated fix, append a
  `LOG - …` entry describing the fix instead of authoring a full PLN.

## Explaining concepts

- **Pitch explanations at a comp-sci-student level.** When explaining a concept,
  algorithm, or design idea (in chat, PLNs, or docs), assume programming and
  basic math fluency but **no** prior ML / information-retrieval / game-design
  background. Build from first principles, use a small worked example with real
  numbers, and name the failure modes — don't just cite the term.
- **Reusable explainers become `REF - …` notes in the vault**
  (`Projects/Gatekeeper/`), so other PLNs/LOGs can link them instead of
  re-explaining (e.g. `REF - Embeddings, Anchor Poles & IDF`).

## Delegating work

- **Spawn implementation work as subagents.** Don't do large/parallelizable work
  inline.
- **Try `cursor-agent -p` first, then Haiku.** Prefer delegating to the Cursor CLI in
  headless print mode (`cursor-agent -p`). If that isn't available or suitable, fall
  back to Haiku subagents (the Agent tool with `model: haiku`).

## Testing — required

- **New code is always tested.** No new code lands without tests covering it.
- **API endpoints maintain a contract, and the contract is the source of truth.**
  Endpoints are tested against an explicit contract (e.g.
  `recordkeeper/tests/test_contracts.py`). Any endpoint change that is **not**
  reflected in the contract **must cause a test failure** — never loosen or
  delete a contract test to make a change pass; update the contract deliberately.
- **UI testing priority — Playwright → component → unit, in that order.** Reach
  for the highest-value level first.
  - **Mocks are derived from the API contracts.** Don't hand-roll ad-hoc mocks
    that can drift. **Importing the contract types/fixtures and mocking against
    them is the preferred option**, so a contract change breaks the UI tests too.
- **Develop UI against the browser MCP.** While building UI, use the available
  browser MCP to test in a real browser, and verify **desktop, tablet, and
  mobile** viewports.

## Database

- **All database operations and migrations must be idempotent** — safe to run
  repeatedly with the same result, no duplicate rows, no errors on re-run.

## Persistent data & deployment

- **New on-disk state ⇒ extend the deploy volumes.** Any feature that writes
  data meant to outlive a container (a new SQLite DB, a cache/asset dir, uploads,
  generated files) must (a) write under the service's mounted data dir
  (`/app/data` today) and (b) be reflected in `docker-compose.prod.yml` as a
  volume under `GATEKEEPER_DATA_ROOT`. Never let persistent data live only in the
  container's writable layer — it is destroyed on every image rebuild/redeploy.
  When you add such a path, update the compose mounts **in the same change**.
- **Persisted data is versioned and migrated forward.** Anything written to disk
  that the app later reads back (game-state JSON, `content.db`, any new store)
  carries a schema version, and newer code migrates older data up on load — it
  must not crash on or silently corrupt data written by a previous version. See
  the data-versioning approach (game-state `schema_version` + ordered migrations;
  `content.db` `PRAGMA user_version` migrations; backup-before-migrate;
  fail-fast on a data version newer than the code). Migrations stay idempotent
  (see Database, above).
  - **Exception — regenerable transient stores.** A store whose contents are
    _non-canonical and reconstructable_ (e.g. the active-encounter store: a lost
    file just means starting the next traveler) carries a `schema_version` and
    migrates older data forward like any other store, but on data it cannot read
    — a version newer than the code, unparseable bytes, or a shape it can't
    validate — it **skips that one record** (logs, presents as absent, preserves
    the file by leaving it or moving it aside) instead of failing fast. Crashing
    the whole service over one regenerable per-game file would be worse than
    re-deriving it. This carve-out is ONLY for stores with no canonical data to
    protect; canonical stores (game-state JSON, `content.db`) still fail fast.

## Committing

- **Lint before every commit.** Run the linter and fix all issues _before_
  committing — a commit must never introduce lint failures.
  - Python: `ruff` (see `pyproject.toml`).
  - Frontend: `npm run lint` (and the unit suite / build green) before committing.

## CI workflow files (`.github/workflows/`)

- **Never edit `.github/workflows/*` directly — the agent can't push workflow
  changes.** The session's GitHub token lacks the `workflow` OAuth scope, so any
  push (or API write) that touches a workflow file is rejected (`refusing to allow
an OAuth App to create or update workflow … without workflow scope`) and blocks
  the whole branch. Instead, **stage the intended workflow as a full copy under
  the top-level `ci-staged/` directory** — edits meant for
  `.github/workflows/ci.yml` go in `ci-staged/ci.yml`, `images.yml` →
  `ci-staged/images.yml`, etc. Commit + push that copy (it's a normal file, not a
  workflow file). The **user then applies the copy to the real workflow** (they
  have `workflow` scope), and a **follow-up commit drops the `ci-staged/` copy**.
  Leave the real `.github/workflows/*` file untouched in the agent's own commits.

## Pull requests

- **Always open PRs against `main`.** Never set another feature branch as the
  base — a PR based on another branch merges _into that branch_, not main, which
  is a silent footgun (you click "merge" and land the work in the wrong place).
  Every PR's base is `main`, full stop.
- **Order dependencies with numbered titles, not stacked bases.** If PRs must land
  in a specific order (a later one won't apply until an earlier one merges), keep
  them all based on `main` and **number the order in each PR title** —
  `[1/3] …`, `[2/3] …`, `[3/3] …` — and note the dependency in the body. Never
  encode the order by pointing one PR's base at another PR's branch.
- **Opening a PR ⇒ launch a `/code-review`.** Immediately after opening a pull
  request, run a `/code-review` against it and address the findings before the
  PR is considered ready.

## Git hygiene (multi-agent / worktrees)

This repo is worked by **multiple agents at once**, often in separate
`git worktree`s that all share one `.git`. Worktrees isolate the _working files_,
_HEAD_, and _index_ — but **branches, the object store, and the stash are shared
across every worktree and the main checkout.** That sharing is the trap.

- **Never use `git stash`.** There is **one global stash stack for the whole
  repo**, so a `stash` / `pop` / `drop` in your worktree reaches into another
  agent's WIP (you'll see their entries in `git stash list`). To park changes,
  make a throwaway commit on **your own** branch instead:
  `git commit -am wip` … later `git reset --soft HEAD~1`.
- **Don't change HEAD in a checkout you don't own.** For branch-switching,
  cherry-pick, or any multi-branch operation, spin a **throwaway worktree** off
  the remote — `git worktree add /tmp/wt-<task> origin/main` — do the work there,
  then `git worktree remove` it. Switching the branch of a shared checkout
  disrupts whoever else is using it.
- **Don't force-update, reset, rebase, or delete a branch another worktree is
  on.** A branch can only be checked out in one worktree; rewriting its history
  still breaks the others.
- **Detect your context when in doubt:** `git rev-parse --git-common-dir`
  (differs from `--git-dir` in a linked worktree) and `git worktree list`.
- True isolation (own refs/objects/stash) needs a separate **clone**, not a
  worktree — worktrees deliberately share the repo.
