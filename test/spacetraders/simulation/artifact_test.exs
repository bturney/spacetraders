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

  test "schema-v1 provenance and identities remain byte-compatible", %{tmp_dir: tmp} do
    ambient = %{
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "init.defaultBranch",
      "GIT_CONFIG_VALUE_0" => "fixture-alternate",
      "GIT_AUTHOR_NAME" => "Ambient Author",
      "GIT_AUTHOR_EMAIL" => "author@example.invalid",
      "GIT_COMMITTER_NAME" => "Ambient Committer",
      "GIT_COMMITTER_EMAIL" => "committer@example.invalid"
    }

    previous = Map.new(ambient, fn {key, _} -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    System.put_env(ambient)
    {root, manifest} = retained_inputs(tmp)
    config = ~s({"architecture":"amd64","os":"linux"})
    name = sha(config) <> ".json"

    write_image(root, [
      {~c"manifest.json", Jason.encode!([%{"Config" => name}])},
      {String.to_charlist(name), config}
    ])

    assert {:ok, provenance} = Artifact.identify(root, manifest, "image.tar")
    # Captured from ab0ec3f before implementation, with fixed Git/tar fixture metadata.
    assert provenance["input_identity"] ==
             "sha256:69cda38d732c5a1f0b3a2ab5cb2b37106d2a7869c36b63a4989dc0a51acb0709"

    assert provenance["artifact_identity"] ==
             "sha256:fc1f87b2a46778331f7dee0f59ef3e80008e040b55d95a5b6953a27152a2d2fd"

    assert provenance["schema_version"] == 1
    refute Map.has_key?(provenance, "build_system")
  end

  test "schema-v2 compiler-only inputs retain history without requiring rebar3", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp, "otp-erlc")

    compiler =
      manifest
      |> Map.put("schema_version", 2)
      |> Map.put("build_system", "otp-erlc")
      |> Map.put("toolchain", %{"erlang_otp" => "28.1"})

    assert {:ok, provenance} = Artifact.validate(root, compiler)
    assert provenance["schema_version"] == 2
    assert provenance["build_system"] == "otp-erlc"
    assert provenance["toolchain"] == %{"erlang_otp" => "28.1"}
    assert provenance["qualification"] == "not_executed"
    assert provenance["source"]["fork_revision"] == compiler["fork_revision"]
    assert map_size(provenance["inputs"]) == 6
    refute Jason.encode!(provenance) =~ root
    refute Jason.encode!(provenance) =~ "rebar3"
  end

  test "versioned build-system and exact toolchain facts bind both identities", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp)
    config = ~s({"architecture":"amd64","os":"linux"})
    name = sha(config) <> ".json"

    write_image(root, [
      {~c"manifest.json", Jason.encode!([%{"Config" => name}])},
      {String.to_charlist(name), config}
    ])

    rebar = manifest |> Map.put("schema_version", 2) |> Map.put("build_system", "rebar3")
    compiler = %{rebar | "build_system" => "otp-erlc", "toolchain" => %{"erlang_otp" => "28.1"}}
    changed_otp = put_in(compiler, ["toolchain", "erlang_otp"], "28.1.1")
    changed_rebar = put_in(rebar, ["toolchain", "rebar3"], "3.25.2")

    results =
      for input <- [manifest, rebar, compiler, changed_otp, changed_rebar] do
        assert {:ok, provenance} = Artifact.identify(root, input, "image.tar")
        assert {:ok, ^provenance} = Artifact.identify(root, input, "image.tar")
        assert provenance["qualification"] == "not_executed"
        assert provenance["image"]["verification"] == "archive_config_only"
        assert provenance["toolchain"] == input["toolchain"]
        assert provenance["build_system"] == input["build_system"]
        provenance
      end

    assert results |> Enum.map(& &1["input_identity"]) |> Enum.uniq() |> length() == 5
    assert results |> Enum.map(& &1["artifact_identity"]) |> Enum.uniq() |> length() == 5
    assert results |> Enum.map(& &1["image"]) |> Enum.uniq() |> length() == 1
  end

  test "versioned build profiles reject unknown fields, tools and inconsistent declarations", %{
    tmp_dir: tmp
  } do
    {root, manifest} = retained_inputs(tmp)
    rebar = manifest |> Map.put("schema_version", 2) |> Map.put("build_system", "rebar3")
    compiler = %{rebar | "build_system" => "otp-erlc", "toolchain" => %{"erlang_otp" => "28.1"}}

    invalid = [
      Map.put(compiler, "schema_version", 3),
      Map.put(compiler, "schema_version", 2.0),
      Map.put(compiler, "schema_version", "2"),
      Map.put(compiler, "schema_version", 1),
      Map.delete(compiler, "schema_version"),
      Map.delete(compiler, "build_system"),
      Map.put(compiler, "build_system", "make"),
      Map.put(compiler, "build_system", nil),
      Map.put(compiler, "build_system", %{"name" => "otp-erlc"}),
      Map.put(compiler, "build_system", "rebar3"),
      Map.put(rebar, "build_system", "otp-erlc"),
      Map.put(compiler, "credentials", "never-export"),
      Map.put(compiler, "toolchain", %{}),
      Map.put(compiler, "toolchain", nil),
      Map.delete(compiler, "toolchain"),
      put_in(compiler, ["toolchain", "erlc"], "28.1"),
      put_in(compiler, ["toolchain", "rebar3"], nil),
      put_in(compiler, ["toolchain", "rebar3"], "not-used"),
      put_in(rebar, ["toolchain", "make"], "4.4"),
      Map.put(manifest, "build_system", "rebar3"),
      Map.put(manifest, "toolchain", compiler["toolchain"])
    ]

    for input <- invalid do
      assert {:error, :invalid_contract} = Artifact.validate(root, input)
    end

    for version <- [nil, 28.1, 28, "", "28", "latest", "28.x", "28.1-rc1", "28.1\n", "28.1.0.0.0"],
        input <- [compiler, rebar],
        tool <- Map.keys(input["toolchain"]) do
      assert {:error, :invalid_contract} =
               Artifact.validate(root, put_in(input, ["toolchain", tool], version))
    end
  end

  test "compiler-only profile does not waive retained input, privacy or ancestry requirements", %{
    tmp_dir: tmp
  } do
    {root, manifest} = retained_inputs(tmp, "otp-erlc")

    compiler =
      manifest
      |> Map.put("schema_version", 2)
      |> Map.put("build_system", "otp-erlc")
      |> Map.put("toolchain", %{"erlang_otp" => "28.1"})

    # Rebar profiles still require their configuration in the pinned source tree.
    assert {:error, :invalid_retained_history} = Artifact.validate(root, manifest)

    rebar = manifest |> Map.put("schema_version", 2) |> Map.put("build_system", "rebar3")
    assert {:error, :invalid_retained_history} = Artifact.validate(root, rebar)

    for role <- Map.keys(compiler["inputs"]) do
      assert {:error, :invalid_contract} =
               Artifact.validate(root, update_in(compiler, ["inputs"], &Map.delete(&1, role)))
    end

    assert {:error, :invalid_contract} =
             Artifact.validate(root, Map.put(compiler, "permission", "public-use"))

    assert {:error, :invalid_contract} =
             Artifact.validate(
               root,
               put_in(compiler, ["inputs", "build_recipe", "path"], "../recipe")
             )

    assert {:error, :invalid_retained_history} =
             Artifact.validate(root, %{
               compiler
               | "upstream_revision" => String.duplicate("0", 40)
             })

    File.chmod!(root, 0o755)
    assert {:error, :private_retention_required} = Artifact.validate(root, compiler)
    File.chmod!(root, 0o700)
    File.write!(Path.join(root, "Dockerfile"), "altered fixture")
    assert {:error, {:invalid_retained_input, "build_recipe"}} = Artifact.validate(root, compiler)
  end

  test "compiler-only history must still contain the supported source subtree", %{tmp_dir: tmp} do
    {root, manifest} = retained_inputs(tmp, "otp-erlc", "unrelated/src")

    compiler =
      manifest
      |> Map.put("schema_version", 2)
      |> Map.put("build_system", "otp-erlc")
      |> Map.put("toolchain", %{"erlang_otp" => "28.1"})

    assert {:error, :invalid_retained_history} = Artifact.validate(root, compiler)
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

    compiler =
      manifest
      |> Map.put("schema_version", 2)
      |> Map.put("build_system", "otp-erlc")
      |> Map.put("toolchain", %{"erlang_otp" => "28.1"})

    for input <- [manifest, compiler] do
      File.write!(path, Jason.encode!(input))
      File.chmod!(path, 0o600)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          Mix.Tasks.Simulation.Artifact.run(["validate", root])
        end)

      assert Jason.decode!(output)["qualification"] == "not_executed"
      assert Jason.decode!(output)["build_system"] == input["build_system"]
      refute output =~ root
    end

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

    :ok =
      :erl_tar.create(String.to_charlist(path), entries,
        mtime: 0,
        atime: 0,
        ctime: 0,
        uid: 0,
        gid: 0
      )

    File.chmod!(path, 0o600)
  end

  defp retained_inputs(tmp, build_system \\ "rebar3", source_path \\ "sim/sim-erlang/src") do
    repo = Path.join(tmp, "upstream")
    File.mkdir_p!(Path.join(repo, source_path))

    git!(repo, ["init", "--quiet", "--initial-branch=main", "--object-format=sha1", "--template="])

    git!(repo, ["config", "user.email", "fixture@example.invalid"])
    git!(repo, ["config", "user.name", "Fixture"])

    if build_system == "rebar3" do
      File.write!(Path.join(repo, "sim/sim-erlang/rebar.config"), "{deps, []}.\n")
    end

    source = Path.join([repo, source_path, "fixture.erl"])
    File.write!(source, "% inert fixture\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "upstream fixture"])
    upstream_revision = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()
    File.write!(source, "% inert fork fixture\n")
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
    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "GIT_"))
      |> Enum.map(&{&1, nil})

    {output, 0} =
      System.cmd(
        "git",
        ["-c", "core.attributesFile=/dev/null", "-c", "core.excludesFile=/dev/null" | args],
        cd: dir,
        stderr_to_stdout: true,
        env:
          cleared ++
            [
              {"GIT_CONFIG_NOSYSTEM", "1"},
              {"GIT_CONFIG_GLOBAL", "/dev/null"},
              {"GIT_ATTR_NOSYSTEM", "1"},
              {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"},
              {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"}
            ]
      )

    output
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
