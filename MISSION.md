# Mission: Learn Elixir/Phoenix and SpaceTraders — each through the other

## Why

I have never used the Elixir/Phoenix stack and never played SpaceTraders. I want to learn both at once, because they are the same activity: every SpaceTraders action is an HTTP endpoint, and this repo is an Elixir program that plays the game. The game makes the code concrete; the code makes the game concrete.

## Success looks like

- Read Elixir/Phoenix code in this repo fluently and make working changes (API client, contexts, LiveView) with `scripts/verify` green.
- Play SpaceTraders on my own: register an agent, navigate, extract, trade, fulfill a contract — through this app and through the API directly.
- Automate one real game loop (a mining run or a contract) as my own Elixir.

## Constraints

- Total beginner to Elixir/OTP and to SpaceTraders. Teach even "obvious" concepts in both.
- Each lesson teaches both at once — never one topic deferred "until later."
- Lessons are short, with a hands-on win (usually: run something real against the live game).
- Real bugs and real repos are the textbook; sandboxes are the exception.

## Out of scope

- Deep OTP/GenServer design, clustering, production deployment.
- Frontend polish / CSS design of the app itself.
