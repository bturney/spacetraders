# Authentication

Read before changing `lib/spacetraders_web/router.ex` or
`lib/spacetraders_web/operator_auth.ex`.

## Think with `current_scope`

`current_scope` is the logged-in Operator.

- Read the operator as `@current_scope.operator`. The assign is `current_scope`;
  there is no `current_operator` assign.
- Pass `current_scope` as the first argument to context modules; filter queries
  with `current_scope.operator`.

## Route placement

- Login-required routes go in the `live_session :require_authenticated_operator`
  block.
- Routes that work signed-in or signed-out go in the single
  `live_session :current_operator` block (defined once, never duplicated).
- Say which scope, `live_session`, and pipeline a route lives in, and why.

Sources of truth: routes in `lib/spacetraders_web/router.ex`; plugs and
`on_mount`s in `lib/spacetraders_web/operator_auth.ex`.