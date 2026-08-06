# Teaching Notes

## Learner profile

- Complete beginner to the Elixir/Phoenix stack and to SpaceTraders (stated in session 1).
- Prior programming experience (other languages?) — UNKNOWN, asked in session 1. Pacing depends on the answer.
- Reader asked for action-first output (global config): lead with the next action, number steps, one bounded action per step, cap lists at 5, give time estimates, show what now works.

## How to teach this pair

- Always teach game + stack together. One request round-trip IS one Elixir lesson.
- Hands-on in the real repo (`mix run`, `iex`, `mix test`) beats sandboxes.
- Real bugs in this repo are first-class teaching material.
- SpaceTraders universe resets periodically; `resetDate` from `GET /` tells us the current era.
- The game's API client is thin and readable — `lib/spacetraders/api.ex` is the anchor for early lessons.

## Conventions

- Glossary lives at `reference/glossary.html`; all explainers must use its terms (Agent, Waypoint, System, Ship, Contract, Module, Function, Tuple, Pipe, Pattern match, `{:ok, _}`/`{:error, _}`).
- Lessons link the shared stylesheet `../assets/teach/lesson.css` and `quiz.js`. New reusable pieces go in `assets/teach/` — never inline a component a second lesson would duplicate.
- Teaching files (lessons/, reference/, learning-records/, MISSION.md, RESOURCES.md, NOTES.md) live alongside the app. `assets/teach/` is deliberately separate from the Phoenix app's `assets/{css,js,vendor}` build tree.
- Deliver lessons to the user over a tunnel: serve a symlinked dir (lessons, reference, assets, lib, priv, test, the md files) via `kimaki tunnel -p <port> -- python3 -m http.server <port>` in a tuistory session; never expose the repo root (`.env`, `*.db`).

## Open questions for the learner

- Prior programming language experience? (affects whether to teach "what is a function" vs Elixir-specific syntax)
- Want community suggestions (SpaceTraders Discord, Elixir Forum) surfaced, or prefer solo?
- Preferred time per lesson / cadence?

## Session 1 — resume point (paused)

- Workspace fully scaffolded; Lesson 1 is ready and unstarted by the learner.
- **Lesson 1:** `lessons/0001-the-game-is-an-api.html` — "The game is an API". Teaches the game + stack together via a real bug: `SpaceTraders.API.get_status/0` failed against the live game because `decode/2` demanded a `"data"` key the root endpoint never sends (flat body). Bug was intentionally left in the tree for the learner to discover + fix.
- **Bug now fixed (engineering task, not the lesson):** `lib/spacetraders/api.ex` decodes `:raw` bodies flat; `test/spacetraders/api/client_test.exs` stubs the honest flat root shape (the old stub shipped the bug by wrapping the lie). Two new guards close the fixture-drift class: `test/spacetraders/api/spec_conformance_test.exs` (ties every endpoint's `data`-envelope assumption to the bundled OpenAPI spec) and `scripts/verify-live` (opt-in live smoke). Both go red if the bug returns.
- **Lesson 1 reframed (decision: reframe, not re-seed):** the "break it" exercise is now a case study — run the round-trip, read why it used to fail, meet the three guards (regression test, spec-conformance test, live smoke). Added a quiz Q4 on the flat-vs-`data` envelope. The code-walk links now point at the fixed `:raw` clause (api.ex:353) and `decode_data/2` (355–358).
- **View:** lesson is tunneled at `https://2316534e22ed95adfe21-8123-tunnel.kimaki.dev/lessons/0001-the-game-is-an-api.html` (tuistory session `spacetraders-lessons`, serves symlinked `/tmp/spacetraders-lessons`). If the URL is dead on return, re-tunnel: `kimaki tunnel -p 8123 -- python3 -m http.server 8123` from `/tmp/spacetraders-lessons`.
- **Not yet done:** learner still needs to run the lesson (discover → fix → verify → `mix test`). Question 1 (prior programming experience) still unanswered — ask first next session.
- Teaching files are committed in git (MISSION.md, NOTES.md, RESOURCES.md, lessons/, learning-records/, reference/).
