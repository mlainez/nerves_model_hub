defmodule ModelHubTest do
  use ExUnit.Case, async: false

  @tmp_root System.tmp_dir!() |> Path.join("nerves_model_hub_test_#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_root)
    Application.put_env(:nerves_model_hub, :models, [])
    on_exit(fn ->
      File.rm_rf!(@tmp_root)
      Application.delete_env(:nerves_model_hub, :models)
    end)

    :ok
  end

  test "ensure_one short-circuits when file is already present" do
    path = Path.join(@tmp_root, "cached.bin")
    File.write!(path, "already here")

    spec = [
      source: {:url, "http://0.0.0.0:1/does-not-matter"},
      path: path
    ]

    assert {:ok, ^path} = NervesModelHub.ensure_one(:cached, spec)
  end

  test "ensure_one re-downloads if SHA mismatch" do
    path = Path.join(@tmp_root, "wrong-sha.bin")
    File.write!(path, "wrong bytes")

    spec = [
      source: {:url, "http://0.0.0.0:1/does-not-exist"},
      path: path,
      sha256: "0000000000000000000000000000000000000000000000000000000000000000"
    ]

    # We expect failure (unreachable URL) but the cached file must
    # be deleted first because the SHA didn't match.
    assert {:error, _} = NervesModelHub.ensure_one(:wrong, spec)
    refute File.exists?(path)
  end

  test "path/1 returns :not_configured for unknown ids" do
    Application.put_env(:nerves_model_hub, :models, [])
    assert {:error, :not_configured} = NervesModelHub.path(:doesnt_exist)
  end

  test "path/1 returns :not_downloaded when configured but missing" do
    Application.put_env(:nerves_model_hub, :models,
      ghost: [source: {:url, "http://nope"}, path: Path.join(@tmp_root, "ghost.bin")]
    )

    assert {:error, :not_downloaded} = NervesModelHub.path(:ghost)
  end

  test "path/1 returns ok-tuple once the file is in place" do
    target = Path.join(@tmp_root, "present.bin")
    File.write!(target, "ok")

    Application.put_env(:nerves_model_hub, :models,
      present: [source: {:url, "http://nope"}, path: target]
    )

    assert {:ok, ^target} = NervesModelHub.path(:present)
  end

  describe "{:file, _} source" do
    test "copies a local file into place" do
      src = Path.join(@tmp_root, "baked.gguf")
      dest = Path.join([@tmp_root, "data", "models", "model.gguf"])
      File.write!(src, "model bytes")

      assert {:ok, ^dest} = NervesModelHub.ensure_one(:baked, source: {:file, src}, path: dest)
      assert File.read!(dest) == "model bytes"
      # Source is left intact — it lives in a read-only rootfs overlay.
      assert File.exists?(src)
    end

    test "creates intermediate directories and leaves no .partial behind" do
      src = Path.join(@tmp_root, "src.bin")
      dest = Path.join([@tmp_root, "deeply", "nested", "out.bin"])
      File.write!(src, "x")

      assert {:ok, ^dest} = NervesModelHub.ensure_one(:nested, source: {:file, src}, path: dest)
      refute File.exists?(dest <> ".partial")
    end

    test "errors when the source file is missing, without leaving a partial" do
      src = Path.join(@tmp_root, "absent.bin")
      dest = Path.join(@tmp_root, "never.bin")

      assert {:error, {:copy_failed, ^src, :enoent}} =
               NervesModelHub.ensure_one(:absent, source: {:file, src}, path: dest)

      refute File.exists?(dest)
      refute File.exists?(dest <> ".partial")
    end

    test "ensure_all stages every baked-in model (the firmware boot path)" do
      for name <- ~w(a.gguf b.onnx) do
        File.write!(Path.join(@tmp_root, name), name)
      end

      dest_a = Path.join([@tmp_root, "data", "a.gguf"])
      dest_b = Path.join([@tmp_root, "data", "b.onnx"])

      Application.put_env(:nerves_model_hub, :models,
        a: [source: {:file, Path.join(@tmp_root, "a.gguf")}, path: dest_a],
        b: [source: {:file, Path.join(@tmp_root, "b.onnx")}, path: dest_b]
      )

      assert {:ok, %{a: ^dest_a, b: ^dest_b}} = NervesModelHub.ensure_all()
      assert File.read!(dest_b) == "b.onnx"

      # Second boot is a no-op: the files are already staged.
      assert {:ok, %{a: ^dest_a, b: ^dest_b}} = NervesModelHub.ensure_all()
    end
  end

  test "ensure_all reports per-model errors" do
    Application.put_env(:nerves_model_hub, :models,
      bad: [
        source: {:url, "http://127.0.0.1:1/should-not-listen"},
        path: Path.join(@tmp_root, "bad.bin")
      ]
    )

    assert {:error, [{:bad, _reason}]} = NervesModelHub.ensure_all()
  end

  test "an empty cached file is not trusted" do
    path = Path.join(@tmp_root, "empty.bin")
    File.write!(path, "")
    src = Path.join(@tmp_root, "real.bin")
    File.write!(src, "real bytes")

    assert {:ok, ^path} = NervesModelHub.ensure_one(:empty, source: {:file, src}, path: path)
    assert File.read!(path) == "real bytes"
  end

  test "an empty download is an error, not a cached model" do
    src = Path.join(@tmp_root, "zero.bin")
    File.write!(src, "")
    dest = Path.join(@tmp_root, "out/zero.bin")

    assert {:error, {:empty_download, :zero}} =
             NervesModelHub.ensure_one(:zero, source: {:file, src}, path: dest)

    refute File.exists?(dest)
    refute File.exists?(dest <> ".partial")
  end

  test "ensure_all honours an explicit :models option" do
    src = Path.join(@tmp_root, "m.bin")
    File.write!(src, "m")
    dest = Path.join(@tmp_root, "m_out.bin")

    assert {:ok, %{m: ^dest}} =
             NervesModelHub.ensure_all(models: [m: [source: {:file, src}, path: dest]])
  end

  test "an unwritable target directory returns an error instead of raising" do
    src = Path.join(@tmp_root, "x.bin")
    File.write!(src, "x")
    blocker = Path.join(@tmp_root, "blocker")
    File.write!(blocker, "a file, not a directory")

    assert {:error, {:mkdir_failed, _, _}} =
             NervesModelHub.ensure_one(:x, source: {:file, src}, path: Path.join(blocker, "x.bin"))
  end
end
