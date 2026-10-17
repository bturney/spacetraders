defmodule SpaceTraders.Simulation.ArtifactTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.Simulation.Artifact

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "artifact-test-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    File.mkdir!(tmp)
    File.chmod!(tmp, 0o700)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp_dir: tmp}
  end

  test "retained inputs yield path-free provenance without upstream availability", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)

    assert {:ok, provenance} = Artifact.validate(root, manifest)
    assert provenance["scope"] == "standalone-http-world"
    assert provenance["qualification"] == "not_executed"
    assert provenance["source"]["fork_revision"] == manifest["fork_revision"]
    assert provenance["source"]["upstream_revision"] == manifest["upstream_revision"]
    assert provenance["inputs"]["source_bundle"] == manifest["inputs"]["source_bundle"]["sha256"]
    refute Jason.encode!(provenance) =~ root
    refute Jason.encode!(provenance) =~ "private-source.bundle"
    assert provenance["input_identity"] =~ ~r/\Asha256:[a-f0-9]{64}\z/
  end

  test "artifact identity binds retained inputs to archive bytes and image configuration", %{
    tmp_dir: tmp
  } do
    {root, manifest} = retained_inputs(tmp)

    config =
      ~s({"architecture":"amd64","os":"linux","config":{"Env":["SECRET=never-export"]},"rootfs":{"type":"layers","diff_ids":[]}})

    image = Path.join(root, "image.tar")
    config_name = sha(config) <> ".json"

    index =
      Jason.encode!([
        %{"Config" => config_name, "RepoTags" => ["private:fixture"], "Layers" => []}
      ])

    :ok =
      :erl_tar.create(
        String.to_charlist(image),
        [{~c"manifest.json", index}, {String.to_charlist(config_name), config}],
        []
      )

    File.chmod!(image, 0o600)

    assert {:ok, provenance} = Artifact.identify(root, manifest, "image.tar")
    assert provenance["image"]["image_id"] == "sha256:" <> sha(config)
    assert provenance["image"]["archive_sha256"] == sha(File.read!(image))
    assert provenance["image"]["verification"] == "archive_config_only"
    assert provenance["qualification"] == "not_executed"
    refute Jason.encode!(provenance) =~ "SECRET"
    refute Jason.encode!(provenance) =~ "private:fixture"

    assert {:error, :image_platform_mismatch} =
             Artifact.identify(root, %{manifest | "platform" => "linux/arm64"}, "image.tar")
  end

  test "API contract identity is checked against retained schema bytes", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)

    assert {:error, :api_schema_mismatch} =
             Artifact.validate(root, %{
               manifest
               | "api_schema_sha256" => String.duplicate("b", 64)
             })
  end

  test "agent command emits sanitized JSON, not private manifest fields", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    path = Path.join(root, "inputs.json")
    File.write!(path, Jason.encode!(manifest))
    File.chmod!(path, 0o600)

    output =
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Simulation.Artifact.run(["validate", root]) end)

    assert Jason.decode!(output)["qualification"] == "not_executed"
    refute output =~ root

    File.write!(path, Jason.encode!(Map.put(manifest, "credentials", "never-print-this")))

    assert_raise Mix.Error, ~r/invalid_contract/, fn ->
      Mix.Tasks.Simulation.Artifact.run(["validate", root])
    end
  end

  test "invalid retained paths fail closed without leaking filesystem exceptions", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)

    for path <- ["../outside", "/absolute", "file\0name"] do
      invalid = put_in(manifest, ["inputs", "build_recipe", "path"], path)
      assert {:error, :invalid_contract} = Artifact.validate(root, invalid)
    end
  end

  test "image metadata inspection is bounded before allocating member contents", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)

    config =
      Jason.encode!(%{
        "architecture" => "amd64",
        "os" => "linux",
        "padding" => String.duplicate("x", 1_048_576)
      })

    name = sha(config) <> ".json"

    write_image(root, [
      {~c"manifest.json", Jason.encode!([%{"Config" => name}])},
      {String.to_charlist(name), config}
    ])

    assert {:error, :invalid_image_archive} = Artifact.identify(root, manifest, "image.tar")
  end

  test "retention rejects broad permissions, symlinks, missing and altered bytes", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    File.chmod!(root, 0o755)
    assert {:error, :private_retention_required} = Artifact.validate(root, manifest)
    File.chmod!(root, 0o700)
    path = Path.join(root, "Dockerfile")
    File.chmod!(path, 0o644)
    assert {:error, {:invalid_retained_input, "build_recipe"}} = Artifact.validate(root, manifest)
    File.chmod!(path, 0o600)
    File.write!(path, "changed fixture")
    assert {:error, {:invalid_retained_input, "build_recipe"}} = Artifact.validate(root, manifest)
    File.rm!(path)
    assert {:error, {:invalid_retained_input, "build_recipe"}} = Artifact.validate(root, manifest)
    File.ln_s!(Path.join(root, "dependencies.lock"), path)
    assert {:error, {:invalid_retained_input, "build_recipe"}} = Artifact.validate(root, manifest)
  end

  test "image identity alone and unavailable source revisions cannot pass retention", %{
    tmp_dir: tmp
  } do
    {root, manifest} = retained_inputs(tmp)
    incomplete = update_in(manifest, ["inputs"], &Map.delete(&1, "source_bundle"))
    assert {:error, :invalid_contract} = Artifact.validate(root, incomplete)

    assert {:error, :invalid_retained_history} =
             Artifact.validate(root, %{
               manifest
               | "upstream_revision" => String.duplicate("0", 40)
             })

    File.write!(Path.join(root, "private-source.bundle"), "not a git bundle")
    invalid = put_in(manifest, ["inputs", "source_bundle", "sha256"], sha("not a git bundle"))
    assert {:error, :invalid_retained_history} = Artifact.validate(root, invalid)
  end

  test "changed build inputs get a new immutable identity", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    assert {:ok, original} = Artifact.validate(root, manifest)
    File.write!(Path.join(root, "Dockerfile"), "new private recipe fixture")

    changed =
      put_in(manifest, ["inputs", "build_recipe", "sha256"], sha("new private recipe fixture"))

    assert {:ok, updated} = Artifact.validate(root, changed)
    refute original["input_identity"] == updated["input_identity"]
    assert {:ok, ^updated} = Artifact.validate(root, changed)
  end

  test "spoofed image IDs and multiple-image archives are rejected", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    config = ~s({"architecture":"amd64","os":"linux"})
    wrong = String.duplicate("0", 64) <> ".json"

    write_image(root, [
      {~c"manifest.json", Jason.encode!([%{"Config" => wrong}])},
      {String.to_charlist(wrong), config}
    ])

    assert {:error, :invalid_image_archive} = Artifact.identify(root, manifest, "image.tar")
    write_image(root, [{~c"manifest.json", "[{},{}]"}])
    assert {:error, :invalid_image_archive} = Artifact.identify(root, manifest, "image.tar")
  end

  test "private image path failures are not misreported as platform mismatches", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    assert {:error, :invalid_image_archive} = Artifact.identify(root, manifest, "../outside")
    write_image(root, [{~c"manifest.json", "[]"}])
    File.chmod!(Path.join(root, "image.tar"), 0o644)
    assert {:error, :invalid_image_archive} = Artifact.identify(root, manifest, "image.tar")
  end

  test "history validation ignores inherited Git configuration", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    previous = System.get_env("GIT_CONFIG_COUNT")

    on_exit(fn ->
      if previous,
        do: System.put_env("GIT_CONFIG_COUNT", previous),
        else: System.delete_env("GIT_CONFIG_COUNT")
    end)

    System.put_env("GIT_CONFIG_COUNT", "not-a-number")
    assert {:ok, _} = Artifact.validate(root, manifest)
  end

  test "missing Git is an actionable sanitized error", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    previous = System.fetch_env!("PATH")
    on_exit(fn -> System.put_env("PATH", previous) end)
    System.put_env("PATH", tmp)
    assert {:error, :git_unavailable} = Artifact.validate(root, manifest)
  end

  defp write_image(root, entries) do
    path = Path.join(root, "image.tar")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [])
    File.chmod!(path, 0o600)
  end

  defp retained_inputs(tmp) do
    repo = Path.join(tmp, "upstream")
    File.mkdir_p!(Path.join(repo, "sim/sim-erlang/src"))
    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "fixture@example.invalid"])
    git!(repo, ["config", "user.name", "Fixture"])
    File.write!(Path.join(repo, "sim/sim-erlang/rebar.config"), "{deps, []}.\n")
    File.write!(Path.join(repo, "sim/sim-erlang/src/fixture.erl"), "% inert fixture\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "upstream fixture"])
    upstream_revision = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(repo, "sim/sim-erlang/src/fixture.erl"), "% inert fork fixture\n")
    git!(repo, ["commit", "--quiet", "-am", "fork fixture"])
    revision = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()

    root = Path.join(tmp, "retained")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    git!(repo, ["bundle", "create", Path.join(root, "private-source.bundle"), "--all"])

    inputs =
      Map.new(
        [
          {"source_bundle", "private-source.bundle"},
          {"dependencies_archive", "dependencies.tar"},
          {"dependency_lock", "dependencies.lock"},
          {"api_schema", "api.json"},
          {"toolchain_archive", "toolchain.tar"},
          {"build_recipe", "Dockerfile"}
        ],
        fn {role, path} ->
          full = Path.join(root, path)
          unless File.exists?(full), do: File.write!(full, "inert #{role} fixture\n")
          File.chmod!(full, 0o600)
          {role, %{"path" => path, "sha256" => sha(File.read!(full))}}
        end
      )

    # The retained bundle is the only source; no remote or continuing checkout exists.
    File.rm_rf!(repo)

    manifest = %{
      "schema_version" => 1,
      "scope" => "standalone-http-world",
      "fork_revision" => revision,
      "upstream_revision" => upstream_revision,
      "api_schema_sha256" => inputs["api_schema"]["sha256"],
      "platform" => "linux/amd64",
      "permission" => "operator-reported-private-use",
      "toolchain" => %{"erlang_otp" => "28.1", "rebar3" => "3.25.1"},
      "inputs" => inputs
    }

    {root, manifest}
  end

  defp git!(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
