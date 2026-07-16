# AGENTS.md — global agent rules

Rules every agent in every container follows. This is the **bundled default**
so a fresh clone works out of the box. To use your own, point `RULES_PATH` at
another rules repo (e.g. `~/git/agent-conf/rules`) via `./.env` — see the
README. Precedence: the project repo's own `CLAUDE.md`/`AGENTS.md` and
`/workspace/rules.local.md` override anything here.

## Working style

- Read before you write. Understand the surrounding code and match its
  conventions, naming, and structure.
- Make the smallest change that fully solves the task; don't refactor unrelated
  code in the same change.
- When something is ambiguous, state your assumption and proceed — don't stall.

## Git & pull requests

- Never commit directly to the default branch. Branch, commit, open a PR.
- Write clear commit messages: what changed and why, not how.
- Keep a PR to one coherent change, and say how you verified it.

## Safety

- Never print or exfiltrate credential values. The egress firewall is a
  backstop, not a license to probe.
- Destructive or irreversible actions (deleting data, force-pushing, touching
  another project) need explicit confirmation first.

## Verification

- Run the project's tests and linters when they exist. Report failures
  honestly — don't claim done on unverified work.
