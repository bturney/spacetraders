defmodule SpaceTraders.Simulation.Artifact do
  @moduledoc """
  Read-only validation of retained private simulator build inputs.

  This is an input-integrity boundary, not build, execution approval, permission
  verification, or simulator qualification. It never fetches, builds or boots.
  Private paths and raw command output are deliberately absent from results.
  """

  @roles ~w(source_bundle dependencies_archive dependency_lock api_schema toolchain_archive build_recipe)
  @fields ~w(schema_version scope fork_revision upstream_revision api_schema_sha256 platform permission toolchain inputs)

  @doc "Validates private retained bytes and history; returns only sanitized provenance."
  def validate(root, manifest) do
    with :ok <- contract(manifest),
         :ok <- private_directory(root),
         :ok <- inputs(root, manifest["inputs"]),
         :ok <- api_schema(manifest),
         :ok <- history(root, manifest) do
      provenance = %{
        "schema_version" => 1,
        "scope" => "standalone-http-world",
        "qualification" => "not_executed",
        "source" => Map.take(manifest, ~w(fork_revision upstream_revision)),
        "api_schema_sha256" => manifest["api_schema_sha256"],
        "platform" => manifest["platform"],
        "permission" => manifest["permission"],
        "toolchain" => manifest["toolchain"],
        "inputs" => Map.new(manifest["inputs"], fn {role, input} -> {role, input["sha256"]} end)
      }

      identity = "sha256:" <> digest(Jason.encode!(canonical(provenance)))
      {:ok, Map.put(provenance, "input_identity", identity)}
    end
  end

  defp api_schema(m) do
    if m["api_schema_sha256"] == m["inputs"]["api_schema"]["sha256"],
      do: :ok,
      else: {:error, :api_schema_mismatch}
  end

  @doc """
  Binds a private Docker-save archive to its config image ID and input identity.

  Does not load the image, verify layer contents, boot, or assert readiness.
  The receiver must verify the archive checksum and loaded image/platform before
  execution. Never exports tags, environment, paths or other raw image metadata.
  """
  def identify(root, manifest, archive) do
    with {:ok, provenance} <- validate(root, manifest),
         {:ok, path} <- private_image(root, archive),
         {:ok, image} <- image_identity(path),
         true <- image["platform"] == manifest["platform"] do
      result = Map.put(provenance, "image", image)

      {:ok,
       Map.put(result, "artifact_identity", "sha256:" <> digest(Jason.encode!(canonical(result))))}
    else
      false -> {:error, :image_platform_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :invalid_image_archive}
    end
  end

  defp private_image(root, archive) do
    with true <- safe_path?(archive),
         :ok <- private_parents(root, Path.split(archive) |> Enum.drop(-1)),
         {:ok, %{type: :regular, mode: mode}} <- File.lstat(Path.join(root, archive)),
         true <- Bitwise.band(mode, 0o077) == 0 do
      {:ok, Path.join(root, archive)}
    else
      _ -> {:error, :invalid_image_archive}
    end
  end

  defp image_identity(path) do
    with {:ok, index} <- tar_member(path, "manifest.json"),
         {:ok, [%{"Config" => name}]} <- Jason.decode(index),
         true <-
           is_binary(name) and
             Regex.match?(~r/\A(?:[a-f0-9]{64}\.json|blobs\/sha256\/[a-f0-9]{64})\z/, name),
         {:ok, config} <- tar_member(path, name),
         true <- digest(config) == name |> Path.basename() |> String.replace_suffix(".json", ""),
         {:ok, %{"os" => os, "architecture" => arch}} <- Jason.decode(config),
         true <- os == "linux" and arch in ~w(amd64 arm64) do
      {:ok,
       %{
         "image_id" => "sha256:" <> digest(config),
         "archive_sha256" => file_digest(path),
         "platform" => os <> "/" <> arch,
         "verification" => "archive_config_only"
       }}
    else
      _ -> {:error, :invalid_image_archive}
    end
  end

  defp tar_member(path, name) do
    member = String.to_charlist(name)

    with {:ok, entries} <- :erl_tar.table(String.to_charlist(path), [:verbose]),
         [{^member, :regular, size, _, _, _, _}] <-
           Enum.filter(entries, &(elem(&1, 0) == member)),
         true <- size <= 1_048_576,
         {:ok, [{^member, bytes}]} <-
           :erl_tar.extract(String.to_charlist(path), [:memory, {:files, [member]}]) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_image_archive}
    end
  end

  defp contract(m) when is_map(m) do
    valid? =
      Enum.sort(Map.keys(m)) == Enum.sort(@fields) and
        m["schema_version"] == 1 and m["scope"] == "standalone-http-world" and
        m["permission"] == "operator-reported-private-use" and
        hex?(m["fork_revision"], 40) and hex?(m["upstream_revision"], 40) and
        hex?(m["api_schema_sha256"], 64) and m["platform"] in ~w(linux/amd64 linux/arm64) and
        toolchain?(m["toolchain"]) and input_contract?(m["inputs"])

    if valid?, do: :ok, else: {:error, :invalid_contract}
  end

  defp contract(_), do: {:error, :invalid_contract}

  defp toolchain?(%{"erlang_otp" => otp, "rebar3" => rebar} = tools) do
    map_size(tools) == 2 and
      Enum.all?([otp, rebar], &(is_binary(&1) and Regex.match?(~r/\A\d+(?:\.\d+){1,3}\z/, &1)))
  end

  defp toolchain?(_), do: false

  defp input_contract?(inputs) when is_map(inputs) do
    Enum.sort(Map.keys(inputs)) == Enum.sort(@roles) and
      Enum.all?(inputs, fn
        {_, %{"path" => path, "sha256" => sha} = input} ->
          map_size(input) == 2 and safe_path?(path) and hex?(sha, 64)

        _ ->
          false
      end)
  end

  defp input_contract?(_), do: false

  defp safe_path?(path) when is_binary(path) do
    path != "" and not String.contains?(path, <<0>>) and Path.type(path) == :relative and
      Enum.all?(Path.split(path), &(&1 not in [".", "..", ""]))
  end

  defp safe_path?(_), do: false

  defp hex?(value, length) when is_binary(value),
    do: byte_size(value) == length and Regex.match?(~r/\A[a-f0-9]+\z/, value)

  defp hex?(_, _), do: false

  defp private_directory(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      _ -> {:error, :private_retention_required}
    end
  end

  defp inputs(root, inputs) do
    Enum.reduce_while(inputs, :ok, fn {role, input}, :ok ->
      path = Path.join(root, input["path"])

      result =
        with :ok <- private_parents(root, Path.split(input["path"]) |> Enum.drop(-1)),
             {:ok, %{type: :regular, mode: mode}} <- File.lstat(path),
             true <- Bitwise.band(mode, 0o077) == 0,
             true <- file_digest(path) == input["sha256"] do
          :ok
        else
          _ -> {:error, {:invalid_retained_input, role}}
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp private_parents(_, []), do: :ok

  defp private_parents(root, [part | rest]) do
    next = Path.join(root, part)
    with :ok <- private_directory(next), do: private_parents(next, rest)
  end

  defp history(root, m) do
    temp =
      Path.join(
        System.tmp_dir!(),
        "simulator-history-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    File.mkdir!(temp)
    File.chmod!(temp, 0o700)
    repo = Path.join(temp, "history.git")
    bundle = Path.join(Path.expand(root), m["inputs"]["source_bundle"]["path"])

    try do
      with :ok <- git(["clone", "--bare", "--quiet", "--", bundle, repo]),
           :ok <- git(["--git-dir", repo, "cat-file", "-e", m["fork_revision"] <> "^{commit}"]),
           :ok <-
             git([
               "--git-dir",
               repo,
               "merge-base",
               "--is-ancestor",
               m["upstream_revision"],
               m["fork_revision"]
             ]),
           :ok <-
             git([
               "--git-dir",
               repo,
               "cat-file",
               "-e",
               m["fork_revision"] <> ":sim/sim-erlang/rebar.config"
             ]),
           :ok <-
             git([
               "--git-dir",
               repo,
               "cat-file",
               "-e",
               m["fork_revision"] <> ":sim/sim-erlang/src"
             ]) do
        :ok
      else
        {:error, :git_unavailable} = error -> error
        _ -> {:error, :invalid_retained_history}
      end
    after
      File.rm_rf!(temp)
    end
  end

  defp git(args) do
    # No remotes, network protocols, hooks, inherited config or replacement refs.
    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "GIT_"))
      |> Enum.map(&{&1, nil})

    {_, status} =
      System.cmd(
        "git",
        [
          "--no-replace-objects",
          "-c",
          "protocol.allow=never",
          "-c",
          "protocol.file.allow=always" | args
        ],
        stderr_to_stdout: true,
        env:
          cleared ++
            [
              {"GIT_CONFIG_NOSYSTEM", "1"},
              {"GIT_CONFIG_GLOBAL", "/dev/null"},
              {"GIT_TERMINAL_PROMPT", "0"}
            ]
      )

    if status == 0, do: :ok, else: {:error, :git_validation_failed}
  rescue
    ErlangError -> {:error, :git_unavailable}
  end

  defp file_digest(path) do
    path
    |> File.stream!([], 64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp canonical(map) when is_map(map),
    do: map |> Enum.sort() |> Enum.map(fn {key, value} -> [key, canonical(value)] end)

  defp canonical(value), do: value
end
