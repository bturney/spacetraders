# LiveView dashboard is the control surface; no CLI

The LiveView dashboard is the sole manual control surface for the game. No bespoke CLI: escript cannot host a supervision tree and `iex -S mix` / mix tasks boot the whole app per invocation. `iex` and mix tasks cover developer scratch instead.
