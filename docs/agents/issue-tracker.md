# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI.

## Conventions

- **Create**: `gh issue create --title "..." --body-file <file>`; select
  labels by workflow below.
- **Read**: `gh issue view <number> --comments`; add
  `--json title,body,labels,comments` for structured fields.
- **List**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with `--label` / `--state` filters.
- **Comment**: `gh issue comment <number> --body "..."`
- **Labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

## Issue labels

When a skill names a triage role, use the matching label string:
`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.

- **Request intake**: `needs-triage` for bug/enhancement requests awaiting
  maintainer evaluation. Prepared implementation tickets use their established
  triage state.
- **Tracking containers**: non-actionable programs and scoped specs use
  `tracking` instead of a triage state label; own native sub-issues. Executable
  work lives in their leaves.
- **Wayfinding**: maps use `wayfinder:map` + `tracking`; decision children use
  `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`) instead of triage
  state labels. The frontier query below determines readiness.

## Model tiers

Agent labels hint at the model tier required to resolve the issue. Dispatchers pick the implementer's model from the label.

| Tier | Claude (Claude Code only) | OpenAI (OpenCode / Codex) |
|---|---|---|
| `agent:mechanical` | Haiku 4.5 | GPT-6 Luna, medium |
| `agent:bounded` | Sonnet 5.5, medium | GPT-6.1 Sol, medium |
| `agent:deep` | Opus 5.5, high | GPT-6.1 Sol, high |

**Escalation rule:** When an agent hits an unresolvable blocker or `scripts/verify` fails twice on the same cause, re-dispatch one tier up. The label remains unchanged.

## Pull requests

**PRs as a request surface: no.** Read or review a pull request only when the
task explicitly names it.

**PR authoring.** A PR that meets every acceptance criterion of its issue
carries the closing keyword (`Closes #N`), so merging it closes the issue. A PR
that leaves any criterion unmet references the issue plainly (`#N`). Merge
itself requires an explicit Operator request.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue holding the Notes / Decisions-so-far / Fog body; use the workflow labels above.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies** — the canonical, UI-visible representation. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only — the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> --add-assignee @me` — the session's first write.
- **Resolve**: `gh issue comment <n> --body "<answer>"`, then `gh issue close <n>`, then append a context pointer (gist + link) to the map's Decisions-so-far.
