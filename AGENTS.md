# AGENTS.md

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles mapped to the labels `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## App

Phoenix 1.8 (Bandit + LiveView), SQLite via `ecto_sqlite3`. Toolchain versions owned by `.tool-versions`.

- `scripts/bootstrap` — from a clean checkout: installs the pinned OTP/Elixir toolchain without sudo, fetches deps.
- The gate: `scripts/verify` — format, warnings-as-errors compile, tests, real boot + `/health` 200. Run it before pushing; CI runs it on every PR.
- `scripts/teardown` — stops a server rooted here, removes `_build` and `*.db`. Deps are shared across checkouts (below) and left in place.
- Run/test commands live in README → Development.

### Agent dev shell

The pinned toolchain is **not** on PATH. In every fresh shell, source it first:

```sh
source scripts/_toolchain.sh   # puts pinned mix/elixir on PATH, sets MIX_DEPS_PATH
```

Deps are shared across checkouts at `$MIX_DEPS_PATH`; `_build` is per-checkout, so a fresh worktree pays one first compile. Don't run concurrent `mix deps.get` from branches with different lockfiles.

### Ticket loop (worktree per ticket)

1. `git worktree add ../spacetraders-<NN> -b feature/<NN>-<slug>` off `main`.
2. `source scripts/_toolchain.sh`, then `mix deps.get`.
3. Iterate `mix test <file>` — the test DB is dropped and re-migrated every run, so edited migrations always apply.
4. Gate with `scripts/verify`, then `/code-review`, commit, PR.

<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs and `live_session` scopes:
  - A plug `:fetch_current_scope_for_operator` that is included in the default browser pipeline
  - A plug `:require_authenticated_operator` that redirects to the log in page when the operator is not authenticated
  - A `live_session :current_operator` scope - for routes that need the current operator but don't require authentication, similar to `:fetch_current_scope_for_operator`
  - A `live_session :require_authenticated_operator` scope - for routes that require authentication, similar to the plug with the same name
  - In both cases, a `@current_scope` is assigned to the Plug connection and LiveView socket
  - A plug `redirect_if_operator_is_authenticated` that redirects to a default path in case the operator is authenticated - useful for a registration page that should only be shown to unauthenticated operators
- **Always let the user know in which router scopes, `live_session`, and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_operator` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.operator` to filter the query results
- To derive/access `current_operator` in templates, **always use the `@current_scope.operator`**, never use **`@current_operator`** in templates or LiveViews
- **Never** duplicate `live_session` names. A `live_session :current_operator` can only be defined __once__ in the router, so all routes for the `live_session :current_operator`  must be grouped in a single block
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug and `live_session` as described below**

### Routes that require authentication

LiveViews that require login should **always be placed inside the __existing__ `live_session :require_authenticated_operator` block**:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_operator]

      live_session :require_authenticated_operator,
        on_mount: [{SpaceTradersWeb.OperatorAuth, :require_authenticated}] do
        # phx.gen.auth generated routes
        live "/operators/settings", OperatorLive.Settings, :edit
        live "/operators/settings/confirm-email/:token", OperatorLive.Settings, :confirm_email
        # our own routes that require logged in operator
        live "/", MyLiveThatRequiresAuth, :index
      end
    end

Controller routes must be placed in a scope that sets the `:require_authenticated_operator` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_operator]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

LiveViews that can work with or without authentication, **always use the __existing__ `:current_operator` scope**, ie:

    scope "/", MyAppWeb do
      pipe_through [:browser]

      live_session :current_operator,
        on_mount: [{SpaceTradersWeb.OperatorAuth, :mount_current_scope}] do
        # our own routes that work with or without authentication
        live "/", PublicLive
      end
    end

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->
