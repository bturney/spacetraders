# Teaching Notes

- Deliver lessons as self-contained HTML under `lessons/`; use `assets/teach/lesson.css` and `assets/teach/quiz.js`.
- The learner reads from Discord and a browser, not a server terminal. Provide tunnel URLs whenever serving pages or the application.
- Before every Elixir command, source `scripts/_toolchain.sh`.
- Use SpaceTraders domain terms from `CONTEXT.md`: Operator is the human; Agent is the in-game identity; a Ship executes Jobs and Intents.
- First sequence: Elixir values and matches, Phoenix request flow, LiveView event flow, then OTP ShipServer.
- The learner has prior programming experience but has not coded much in recent years. Introduce one syntax form at a time, define basic terms, and do not assume current Kotlin or functional-programming knowledge.
- Use a diagram before a real code sample. The learner found the revised LiveView distinction clear: browser click -> `handle_event`; ShipServer message -> `handle_info`.
