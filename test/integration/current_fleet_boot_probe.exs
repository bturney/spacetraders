# Run only by the isolated PostgreSQL migration proof, in a fresh VM. This is
# the real Application supervisor, not a substitute boot/preflight interface.
case Application.ensure_all_started(:spacetraders) do
  {:ok, _apps} ->
    IO.puts("boot succeeded")

  {:error, reason} ->
    IO.puts("boot rejected: #{inspect(reason)}")
    System.halt(1)
end
