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
- **Lesson 1:** `lessons/0001-the-game-is-an-api.html` — "The game is an API". Teaches the game + stack together via a real bug: `SpaceTraders.API.get_status/0` fails against the live game because `decode/2` (`lib/spacetraders/api.ex:353`) demands a `"data"` key the root endpoint never sends. Verified 2-line fix: `defp decode(body, :raw) when is_map(body), do: body` + fix the stub at `test/spacetraders/api/client_test.exs:15` to the flat shape. Bug intentionally LEFT in the tree for the learner to discover + fix.
- **View:** lesson is tunneled at `https://2316534e22ed95adfe21-8123-tunnel.kimaki.dev/lessons/0001-the-game-is-an-api.html` (tuistory session `spacetraders-lessons`, serves symlinked `/tmp/spacetraders-lessons`). If the URL is dead on return, re-tunnel: `kimaki tunnel -p 8123 -- python3 -m http.server 8123` from `/tmp/spacetraders-lessons`.
- **Not yet done:** learner still needs to run the lesson (discover → fix → verify → `mix test`). Question 1 (prior programming experience) still unanswered — ask first next session.
- Teaching files are untracked in git; consider committing them for durability if learner confirms.
