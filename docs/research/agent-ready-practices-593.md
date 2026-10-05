# Agent-ready repo practices — #593

Research input for [#591](https://github.com/bturney/spacetraders/issues/591)
(Wayfinder: agent-ready repo). Question: what do current agent-ready repos and
first-party guidance do, and which practices fit a single-maintainer
Elixir/Phoenix repo worked by parallel agents in worktrees? Researched
2026-10-05 against `origin/main` at `5d98a50`.

## Verdict at a glance

| # | Practice | Fit |
| --- | --- | --- |
| 1 | Short canonical `AGENTS.md`, `CLAUDE.md` symlinked to it | **adopt** (already done; keep pruning) |
| 2 | Progressive disclosure: pointers in `AGENTS.md`, detail on demand | **adopt** (already done; trim `testing.md`) |
| 3 | Project skills for the issue → PR loop | **consider** (1–2 skills max, after the gate contract settles) |
| 4 | Agent hooks: format-on-edit, destructive-command guard | **consider** (thin, optional, measure `mix format` cost first) |
| 5 | Stop hook that runs the gate | **overkill** (277 s gate; too slow per turn) |
| 6 | Inner loop: `mix test <file>`, `--failed`, `--stale`, `--max-failures` | **adopt** (document as the agent default; gate before push only) |
| 7 | Test partitions with per-partition DB | **adopt** (biggest lever on a 254 s sync-dominated suite) |
| 8 | Quiet-on-success gate output, failure digest | **adopt** (23K tokens of success output today) |
| 9 | CI cache for `deps` / `_build` | **adopt** (≈60 s of 68 s prep is uncached rebuild) |
| 10 | Branch protection + required check + auto-merge | **adopt** (auto-merge already enabled; protection missing) |
| 11 | GitHub merge queue | **unavailable** (personal-account repo) and overkill |
| 12 | CI sharding across runners | **consider** later; local partitions first |
| 13 | Git pre-commit/pre-push hooks | **overkill** beyond an optional pre-push |
| 14 | `usage_rules` dependency-rule sync into `AGENTS.md` | **overkill** (inflates always-loaded context) |

## Measured state this note builds on

From #591 Notes and inspection of `origin/main`:

- `AGENTS.md` 43 lines; `CLAUDE.md` is a symlink to it. `docs/agents/*` is 338
  lines loaded on demand (`testing.md` alone 144).
- No committed `.claude/` (no project skills, hooks, or settings).
- Gate (`mix verify`): compile → format check → full `mix test --raise` → two
  codegen checks → boundary → boot. 279 s wall locally; suite 277 s, 254 s of
  it in sync tests. ~33 of 92 test files are `async: false`.
- Success output 1,511 lines / ~23K tokens; `docs/agents/testing.md` tells
  agents to redirect to a file and read the tail.
- CI (`verify.yml`): triggers on `pull_request` only. Run on 2026-10-05:
  container init 20 s, bootstrap + `deps.get` + migrate 68 s, gate 248 s,
  ≈5 m 40 s wall. No `actions/cache`.
- `main` unprotected. Repo is public, owned by a **User** account,
  `allow_auto_merge: true`, `delete_branch_on_merge: true`.
- `mix.exs` still carries Phoenix's generated `precommit` alias (runs `format`
  which writes, `deps.unlock --unused`, `test`) alongside `verify`.
- Test DB is a single URL; `testing.md` forbids `MIX_TEST_PARTITION` for DB
  selection.

## 1. Instruction surface: `AGENTS.md` and progressive disclosure

**What.** A single Markdown file at repo root holding what an agent cannot
infer: commands, environment quirks, non-obvious rules. Nested files override
by proximity.

**Who.** The [agents.md](https://agents.md/) convention is supported by Codex,
Copilot, Jules, Gemini CLI, Cursor, Zed, Aider, Factory and others, used by
"over 60,000" projects, and stewarded by the Agentic AI Foundation under the
Linux Foundation. Codex concatenates root→cwd files and stops at
`project_doc_max_bytes` = 32 KiB
([OpenAI](https://learn.chatgpt.com/docs/agent-configuration/agents-md)).
Claude Code reads `AGENTS.md` when no `CLAUDE.md` exists, or via import/symlink
([Claude Code memory](https://code.claude.com/docs/en/memory)); it advises
"target under 200 lines per CLAUDE.md file" and path-scoped rules for
part-of-codebase guidance. Anthropic's
[best practices](https://code.claude.com/docs/en/best-practices): "For each
line, ask: Would removing this cause Claude to make mistakes? If not, cut it",
and "Bloated CLAUDE.md files cause Claude to ignore your actual instructions."
The underlying principle is "the smallest possible set of high-signal tokens"
with just-in-time retrieval
([Anthropic, context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)).
Phoenix 1.8 now generates an agent-rules file whose first rule is "Use `mix
precommit` alias when you are done"
([phoenix installer template](https://github.com/phoenixframework/phoenix/blob/main/installer/templates/usage-rules/project.md)).

**Fit: adopt (largely in place).** The repo already matches the shape: 43-line
canonical file, symlinked `CLAUDE.md`, pointer list into `docs/agents/*`.
Remaining decisions for the target design:

- Each line must name a command or a rule an agent would otherwise get wrong;
  the freshness ritual (`git merge-base …`, "#267") and the LiveView
  `@form_drafts` rule are candidates to move into a skill or path-scoped doc.
- `docs/agents/testing.md` mixes inner-loop how-to with a seam-ownership
  catalogue; split so the common path (≈20 lines) is reachable in one hop.
- Pick one "done" command and name it in `AGENTS.md`; `precommit` vs `verify`
  is two answers today, and agents trained on Phoenix will try `precommit`.

## 2. Project skills / commands

**What.** On-demand instruction bundles (`SKILL.md` + optional scripts).
Only the `description` is always in context; the body loads on invocation
([Claude Code skills](https://code.claude.com/docs/en/skills): "a skill's body
loads only when it's used, so long reference material costs almost nothing
until you need it"). Follows the open [Agent Skills](https://agentskills.io)
format. `disable-model-invocation: true` restricts side-effecting workflows to
explicit `/name` use. Anthropic's best-practices page uses a `fix-issue` skill
(view issue → implement → test → commit → PR) as its canonical example.

**Fit: consider, small.** The global `~/.claude` skills already cover research,
TDD, review, PR writing (#591 marks them inputs, not targets). A project skill
earns its place only for repo-specific procedure that would otherwise sit in
`AGENTS.md`: e.g. one `implement-issue` skill encoding branch-from-origin/main,
inner loop, gate, PR body. Keep it tool-agnostic by having the skill call
`scripts/*` rather than embed logic. Defer until the gate/output contract is
fixed, or the skill will encode today's 23K-token gate.

## 3. Agent hooks (format-on-edit, guards)

**What.** Deterministic shell commands at agent lifecycle points. "Unlike
CLAUDE.md instructions which are advisory, hooks are deterministic"
([best practices](https://code.claude.com/docs/en/best-practices)). Canonical
examples in the [hooks guide](https://code.claude.com/docs/en/hooks-guide):
`PostToolUse` on `Edit|Write` runs a formatter on the edited file; a
`PreToolUse` script exits 2 to block edits to protected paths and its stderr
is fed back to the agent. A `Stop` hook can block turn end until a check passes.
Gotcha for worktrees: `${CLAUDE_PROJECT_DIR}` stays at the launch checkout;
hooks must read `cwd` from input JSON to act on the worktree
([worktrees](https://code.claude.com/docs/en/worktrees)).

**Fit.**

- Format-on-edit: **consider.** Removes the whole "format check failed"
  round-trip. Cost: `mix format <file>` boots a VM and, with the LiveView
  formatter plugin, may compile; measure per-edit latency before adopting. A
  cheaper equivalent is running `mix format` once inside the inner-loop script.
- Destructive-command / protected-path guard: **consider**, narrow list only
  (`priv/spec/SpaceTraders.json`, generated API modules, `git reset --hard` on
  shared stash). Claude Code already enforces worktree isolation itself.
- Stop hook running the gate: **overkill.** A 277 s gate per turn end is a
  throughput tax; reserve the gate for pre-push/CI.
- Keep hooks in `.claude/settings.json` as thin wrappers over `scripts/*` so
  other agents can call the same scripts (#591 "tool-agnostic").

## 4. Fast inner verification loop (Mix/ExUnit)

**What, from [`mix test` docs (1.18.4)](https://mix.hexdocs.pm/1.18.4/Mix.Tasks.Test.html):**

- `--stale`: "run only the test files which reference modules that have
  changed since the last time you ran this task with `--stale`" (transitive
  deps; manifest lives in `_build`, so it is per worktree).
- `--failed`: "runs only tests that failed the last time they ran".
- `--max-failures N`: stop the suite after N failures (fail fast).
- `--partitions N` + `MIX_TEST_PARTITION`: split files round-robin across OS
  processes, because "it is not always possible to run all tests concurrently"
  in one VM.
- `--max-cases` defaults to 2× cores; only async modules run concurrently.
- `--slowest N` names the hot spots.
- `mix compile` is incremental by default; Elixir 1.19 adds
  `MIX_OS_DEPS_COMPILE_PARTITION_COUNT` for parallel dep compilation and
  reports faster large-project compiles
  ([Elixir 1.19 release](https://elixir-lang.org/blog/2025/10/16/elixir-v1-19-0-released/));
  the repo pins 1.18.4.

Phoenix's generated config names the test DB
`"<app>_test#{System.get_env("MIX_TEST_PARTITION")}"` so each partition gets
its own database ([Phoenix testing guide](https://github.com/phoenixframework/phoenix/blob/main/guides/testing/testing.md)).
Ecto's sandbox allows concurrent tests only on PostgreSQL and not in shared
mode ([Ecto.Adapters.SQL.Sandbox](https://ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html)).

**Fit.**

- Agent default loop = `mix test <file>` → `mix test --failed` →
  `mix test --stale` → gate before push: **adopt**. Cheap, built-in, and the
  docs already name single-file runs. `--stale`'s manifest being per-`_build`
  suits worktrees.
- Partitions: **adopt, highest leverage.** 254 of 277 s is sync tests, which
  `--max-cases` cannot parallelise; 4 partitions on 4 cores is the only
  built-in way to use the idle cores. Requires reversing the "do not use
  `MIX_TEST_PARTITION` to select databases" rule and provisioning N migrated
  DBs. Partitions are separate DBs, so `RuntimeAuthority` terminating backends
  stays inside one partition. Expect imbalance (round-robin by file);
  `--slowest` informs any split of heavy files.
- Converting sync tests to async: **consider** per hotspot; many are sync by
  design (real commits, app-wide clock), so partitions are the safer win.
- `--max-failures 1` in the inner loop: **adopt**; not in the gate, where a
  full failure list is worth one run.

## 5. CI feedback cycle

**What and who.**

- Dependency/build caching: the Elixir CI pattern caches `deps` and `_build`
  keyed on `hashFiles('**/mix.lock')`
  ([Fly.io Phoenix Files](https://fly.io/phoenix-files/github-actions-for-elixir-ci/),
  [erlef/setup-beam](https://github.com/erlef/setup-beam/)). The toolchain dir
  can be cached keyed on `.tool-versions`.
- Auto-merge: "merges a pull request automatically after all required reviews
  and status checks pass"; only meaningful with branch protection requiring
  checks ([GitHub docs](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request)).
- Merge queue: needs a `merge_group` trigger in workflows
  ([GitHub docs](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue));
  "available on private and public repos on the GitHub Enterprise Cloud plan
  and all public repos owned by organizations"
  ([GitHub changelog](https://github.blog/changelog/2023-07-12-pull-request-merge-queue-is-now-generally-available/)).

**Fit.**

- Cache toolchain + `deps` + `_build`: **adopt.** Prep is 68 s per job ×2 jobs,
  mostly re-download/re-compile on an unchanged lockfile; the gate's compile
  leg also benefits.
- Branch protection with the `product-verification` check required, then
  `gh pr merge --auto`: **adopt.** It is the decided merge rule (#591) and
  removes the push → wait → poll → merge step. Auto-merge is already enabled at
  repo level. Note `AGENTS.md`'s "Merge requires an explicit Operator request"
  must be reconciled: the Operator's request can be the act of arming
  auto-merge.
- Merge queue: **unavailable** (`bturney/spacetraders` is user-owned) and
  **overkill**: with one maintainer, "require branches up to date" plus
  auto-merge covers the semantic-conflict case at the cost of a rebase+rerun.
  Integration branches (`/implement-spec`) already serialise parallel work.
- Partition CI across a job matrix: **consider** after local partitions; 4
  runners × (20 s init + prep) only pays once prep is cached.
- `release-deployment-verification` runs on every PR in parallel; no wall-time
  cost, keep.

## 6. Context-economical tool output

**What and who.** HumanLayer's "context-efficient backpressure": wrap each
stage so success prints one line (`✓ stage`) and failure dumps that stage's
full output; enable fail-fast flags. Rationale: passing output wastes "2-3%"
of context per run, and agents truncating with `head` cause expensive re-runs
([HumanLayer](https://www.humanlayer.dev/blog/context-efficient-backpressure)).
Anthropic's tool guidance: default to filtering/truncation with sensible
limits, make error output actionable, Claude Code caps tool responses at 25K
tokens ([Anthropic, writing tools](https://www.anthropic.com/engineering/writing-tools-for-agents))
— the gate's ~23K-token success output sits just under that cap.

**Fit: adopt.**

- Gate prints one line per check on success and the failing check's output
  (plus the transcript path) on failure. Keeps the "exit status is the
  verdict" invariant: output shaping is presentation only.
- Remove the noise at source rather than filter it: the 164 JSON error-log
  lines and 55 debug dumps in a passing run are test hygiene
  (`capture_log`, `@moduletag :capture_log`), not formatter work.
- Failure digest: ExUnit's own failure block is already compact; a custom
  `--formatter` is **overkill**.
- Bare `scripts/verify` without a DB should fail in one line naming the fix
  (precondition check), not 51 lines of `econnrefused` — matches "actionable
  errors" guidance.

## 7. Parallel isolation (touches #591's parallel model)

Claude Code worktrees isolate files only; "a worktree is a fresh checkout, so
initialize your development environment there", `.worktreeinclude` copies
gitignored files, and worktrees under `.claude/worktrees/` are swept
automatically ([worktrees](https://code.claude.com/docs/en/worktrees)). DBs,
ports, and containers are the repo's problem. The 13 leftover per-branch
Postgres containers suggest: one shared Postgres server, one database per
worktree (+ per partition), named deterministically and droppable, rather than
one container per branch. Port collision is already handled by `PORT=4002`
only for the boot check.

## Overkill for a single-maintainer repo

- Merge queue (also unavailable on a user-owned repo).
- Stop hook that runs the full gate every turn.
- Git pre-commit hooks duplicating agent hooks/CI; at most an opt-in pre-push.
- `usage_rules` syncing every dependency's rules into always-loaded context.
- Custom ExUnit formatter for digests.
- Multi-runner CI sharding before caching and local partitions land.
- Many small project skills; one workflow skill plus `docs/agents/*` suffices.

## Open questions for the target design

1. Partition count and DB naming: `spacetraders_test_<worktree>_<n>`? Who
   creates/migrates them, and is that inside or outside the gate?
2. Does `precommit` die, or become the documented inner-loop alias?
3. Does the Operator's merge request become "arm auto-merge"?
4. Inner-loop entry point: plain `mix test` flags in `AGENTS.md`, or a
   `scripts/check` wrapper that also formats and prints quiet output?

## Sources

- AGENTS.md convention — https://agents.md/
- OpenAI Codex AGENTS.md discovery — https://learn.chatgpt.com/docs/agent-configuration/agents-md
- Claude Code best practices — https://code.claude.com/docs/en/best-practices
- Claude Code memory / AGENTS.md — https://code.claude.com/docs/en/memory
- Claude Code skills — https://code.claude.com/docs/en/skills
- Agent Skills standard — https://agentskills.io
- Claude Code hooks guide — https://code.claude.com/docs/en/hooks-guide
- Claude Code worktrees — https://code.claude.com/docs/en/worktrees
- Anthropic, effective context engineering — https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents
- Anthropic, writing tools for agents — https://www.anthropic.com/engineering/writing-tools-for-agents
- HumanLayer, context-efficient backpressure — https://www.humanlayer.dev/blog/context-efficient-backpressure
- `mix test` 1.18.4 — https://mix.hexdocs.pm/1.18.4/Mix.Tasks.Test.html
- Elixir 1.19 release — https://elixir-lang.org/blog/2025/10/16/elixir-v1-19-0-released/
- Phoenix testing guide (partitions) — https://github.com/phoenixframework/phoenix/blob/main/guides/testing/testing.md
- Phoenix generated agent rules — https://github.com/phoenixframework/phoenix/blob/main/installer/templates/usage-rules/project.md
- Ecto SQL Sandbox — https://ecto-sql.hexdocs.pm/Ecto.Adapters.SQL.Sandbox.html
- Fly.io, GitHub Actions for Elixir CI — https://fly.io/phoenix-files/github-actions-for-elixir-ci/
- erlef/setup-beam — https://github.com/erlef/setup-beam/
- GitHub auto-merge — https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/automatically-merging-a-pull-request
- GitHub merge queue — https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue
- GitHub merge queue GA / availability — https://github.blog/changelog/2023-07-12-pull-request-merge-queue-is-now-generally-available/
