# SpaceTraders + Elixir/Phoenix Resources

## Knowledge

- [SpaceTraders Docs — official](https://docs.spacetraders.io)
  The game's rulebook: Getting started, Quickstart, Game concepts (agents/factions, systems and waypoints, navigation, extraction, markets), API guide, rate limits. Use for: any claim about how the game works.
- [Bundled OpenAPI spec — `priv/spec/SpaceTraders.json` (v2.3.0)](file: priv/spec/SpaceTraders.json)
  The game's contract as data; the API client structs are generated from it (`mix space_traders.gen.models`). Use for: the exact shape of any endpoint's request/response.
- [Joy of Elixir — "A gentle introduction to programming" (Free online book)](https://joyofelixir.com)
  Beginner-friendly Elixir, aimed at people with little-to-no programming experience. Use for: early Elixir concepts.
- [Elixir — Getting Started (official)](https://elixir-lang.org/getting-started/introduction.html)
  Official guided tour of the language. Use for: reference-grade explanations of syntax and core modules.
- [Elixir School](https://elixirschool.com)
  Structured, community-written lessons. Use for: topic lookups (functions, pattern matching, pipes, Ecto).
- [Phoenix Framework — hexdocs](https://hexdocs.pm/phoenix/overview.html)
  Reference for the web layer (routing, controllers, LiveView). Use for: anything under `lib/spacetraders_web/`.
- [README.md + CONTEXT.md (this repo)](file: README.md)
  How the app is wired (bootstrap, `scripts/verify`, seed, secrets) and the canonical domain language (Agent/Operator/System/Waypoint). Use for: app-specific facts and vocabulary.

## Wisdom (Communities)

- [SpaceTraders Discord](https://discord.gg/jhVzqRf) (invite on docs.spacetraders.io)
  Active community of players and tool builders; the place to test gameplay tactics and get feedback on your bot.
- [Elixir Forum](https://elixirforum.com)
  High-signal Elixir/Phoenix Q&A and show-and-tell. Use for: getting unstuck on the stack.
- [r/elixir](https://reddit.com/r/elixir)
  Elixir community on Reddit; good for finding reading lists and project inspiration.

## Gaps

- None critical yet. If a specific gameplay area (e.g., survey/refine, jump gates) needs depth, the bundled spec + docs usually suffice; a community check may fill gaps.
