defmodule ModelHubTest do
  use ExUnit.Case, async: false

  @tmp_root System.tmp_dir!() |> Path.join("nx_arm_hub_test_#{System.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@tmp_root)
    Application.put_env(:model_hub, :models, [])
    on_exit(fn ->
      File.rm_rf!(@tmp_root)
      Application.delete_env(:model_hub, :models)
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

    assert {:ok, ^path} = ModelHub.ensure_one(:cached, spec)
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
    assert {:error, _} = ModelHub.ensure_one(:wrong, spec)
    refute File.exists?(path)
  end

  test "path/1 returns :not_configured for unknown ids" do
    Application.put_env(:model_hub, :models, [])
    assert {:error, :not_configured} = ModelHub.path(:doesnt_exist)
  end

  test "path/1 returns :not_downloaded when configured but missing" do
    Application.put_env(:model_hub, :models,
      ghost: [source: {:url, "http://nope"}, path: Path.join(@tmp_root, "ghost.bin")]
    )

    assert {:error, :not_downloaded} = ModelHub.path(:ghost)
  end

  test "path/1 returns ok-tuple once the file is in place" do
    target = Path.join(@tmp_root, "present.bin")
    File.write!(target, "ok")

    Application.put_env(:model_hub, :models,
      present: [source: {:url, "http://nope"}, path: target]
    )

    assert {:ok, ^target} = ModelHub.path(:present)
  end

  test "ensure_all reports per-model errors" do
    Application.put_env(:model_hub, :models,
      bad: [
        source: {:url, "http://127.0.0.1:1/should-not-listen"},
        path: Path.join(@tmp_root, "bad.bin")
      ]
    )

    assert {:error, [{:bad, _reason}]} = ModelHub.ensure_all()
  end
end
