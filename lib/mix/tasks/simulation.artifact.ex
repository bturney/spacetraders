defmodule Mix.Tasks.Simulation.Artifact do
  use Mix.Task

  @shortdoc "Validates retained private simulator inputs without building or booting"
  @moduledoc """
      mix simulation.artifact validate /private/retained/version
      mix simulation.artifact identify /private/retained/version image.tar

  Reads private `inputs.json`; emits allowlisted JSON provenance. No application
  startup, Docker invocation, upstream contact, build, boot or readiness claim.
  See `docs/simulation/private-build.md` for the contract and outstanding gates.
  """

  alias SpaceTraders.Simulation.Artifact

  @impl true
  def run([command, root | rest]) when command in ["validate", "identify"] do
    Mix.Task.run("compile")

    with {:ok, manifest} <- read_manifest(root),
         {:ok, provenance} <- dispatch(command, root, manifest, rest) do
      Mix.shell().info(Jason.encode!(provenance))
    else
      {:error, reason} -> Mix.raise("simulation artifact: #{inspect(reason)}")
    end
  end

  def run(_),
    do: Mix.raise("usage: mix simulation.artifact validate ROOT | identify ROOT ARCHIVE")

  defp dispatch("validate", root, manifest, []), do: Artifact.validate(root, manifest)

  defp dispatch("identify", root, manifest, [archive]),
    do: Artifact.identify(root, manifest, archive)

  defp dispatch(_, _, _, _), do: {:error, :invalid_arguments}

  defp read_manifest(root) do
    path = Path.join(root, "inputs.json")

    with {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, bytes} <- File.read(path),
         {:ok, manifest} <- Jason.decode(bytes) do
      {:ok, manifest}
    else
      _ -> {:error, :invalid_private_manifest}
    end
  end
end
