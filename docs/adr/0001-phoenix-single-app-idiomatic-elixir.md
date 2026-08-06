# Phoenix 1.8 single mix app, idiomatic Elixir

Phoenix 1.8 (Bandit, LiveView) as one mix app over plain OTP, written idiomatic Elixir — the domain as Phoenix contexts with clean public module APIs, LiveView and mix tasks as thin consumers. Deliberately not an umbrella and not strict hexagonal ports-and-adapters. The fleet command panel is textbook LiveView and the generator wires Bandit + SQLite in one command; contexts give the same boundary value as hexagonal without the ceremony.
