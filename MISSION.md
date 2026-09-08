# Mission: Learn Elixir by operating SpaceTraders

## Why
Use the existing SpaceTraders dashboard and bot to become productive in Elixir, Phoenix, LiveView, Ecto, and OTP. The goal is to read, change, test, and safely operate this application rather than complete a disconnected language tutorial.

## Success looks like
- Trace a dashboard command from browser event to the SpaceTraders API and back.
- Make a small, tested Elixir change in an existing domain context.
- Explain why one Ship has a supervised process and how it recovers after a restart.
- Run the application and its tests from the headless Linux server without a local Elixir installation.

## Constraints
- The primary checkout runs on a headless Linux server reached through Tailscale and Kimaki.
- Browser access uses `kimaki tunnel`; persistent commands use tuistory.
- The learner is an experienced Python, Go, Java, and Kotlin engineer, but new to Erlang and Elixir.
- Lessons must remain usable without an LLM.

## Out of scope
- Installing the Erlang/Elixir toolchain on a MacBook.
- Learning Erlang syntax before it is needed to understand the BEAM and OTP.
- Generic exercises unrelated to this application.
