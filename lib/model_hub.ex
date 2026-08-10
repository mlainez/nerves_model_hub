defmodule ModelHub do
  @moduledoc """
  First-boot model fetch for Nerves devices.

  Declare the models your firmware needs in app config and they get
  streamed from HuggingFace (or any HTTPS URL) to local storage on
  boot. After the first successful download the file lives on
  `/root` (or wherever you point it) and subsequent boots skip the
  network round-trip.

  ## Configuration

      config :model_hub,
        models: [
          tinyllama: [
            source: {:hf, "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
                          "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"},
            path: "/root/models/tinyllama.gguf",
            sha256: "optional-sha-for-integrity"
          ],
          whisper_tiny: [
            source: {:url, "https://example.com/whisper-tiny.gguf"},
            path: "/root/models/whisper-tiny.gguf"
          ]
        ]

  At app start, call `ModelHub.ensure_all/0` from your own
  Application supervisor — typically synchronously, before any
  consumer of those model files boots.

  ## Sources

    * `{:hf, "owner/repo", "filename"}` — resolves to
      `https://huggingface.co/owner/repo/resolve/main/filename`.
      Pass `{:hf, "owner/repo", "filename", revision: "rev"}` for
      a specific branch or commit.
    * `{:url, "https://..."}` — any HTTPS URL.
    * `{:file, "/srv/models/foo.gguf"}` — a local path, copied
      rather than downloaded. This is how firmware bakes models
      into a read-only rootfs overlay at build time and moves them
      onto writable storage on first boot, with no network at all.

  ## Atomicity

  Downloads write to `<path>.partial` and rename on success. A
  crash mid-download leaves the partial file; the next run retries
  from scratch (no resume yet).

  ## Network

  Uses Erlang `:httpc` — no new Rust network deps. Bring up
  connectivity (`vintage_net` etc.) before this runs; the boot
  hook only attempts a fetch when the target file is missing.
  """

  require Logger

  @app :model_hub

  @doc """
  Walk `config :model_hub, :models, [...]` and download any
  whose `:path` is missing. Returns `{:ok, %{id => path}}` on
  success, `{:error, [{id, reason}, ...]}` on partial failure.

  Optionally pass `app: :my_app` to read config from a different
  application namespace (handy when migrating from a previous
  hub library — pass `app: :nx_arm` to read `:nx_arm, :models`).
  """
  @spec ensure_all(keyword()) :: {:ok, %{atom() => Path.t()}} | {:error, [{atom(), term()}]}
  def ensure_all(opts \\ []) do
    app = Keyword.get(opts, :app, @app)
    models = Application.get_env(app, :models, [])

    {ok, errors} =
      models
      |> Enum.map(fn {id, spec} -> {id, ensure_one(id, spec)} end)
      |> Enum.split_with(fn {_id, r} -> match?({:ok, _}, r) end)

    successes = Map.new(ok, fn {id, {:ok, p}} -> {id, p} end)

    if errors == [] do
      {:ok, successes}
    else
      {:error, Enum.map(errors, fn {id, {:error, r}} -> {id, r} end)}
    end
  end

  @doc """
  Make sure a single named model is available. Returns
  `{:ok, path}` regardless of whether we downloaded or
  short-circuited on cache hit.
  """
  @spec ensure_one(atom(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def ensure_one(id, spec) do
    path = Keyword.fetch!(spec, :path)
    source = Keyword.fetch!(spec, :source)
    sha256 = Keyword.get(spec, :sha256)

    cond do
      File.exists?(path) and (sha256 == nil or sha_ok?(path, sha256)) ->
        Logger.debug("[model_hub] #{id}: cached at #{path}")
        {:ok, path}

      File.exists?(path) ->
        Logger.warning(
          "[model_hub] #{id}: cached file at #{path} failed SHA check, re-downloading"
        )
        File.rm(path)
        do_fetch(id, source, path, sha256)

      true ->
        do_fetch(id, source, path, sha256)
    end
  end

  @doc "Local path for a configured model id, after `ensure_all/0`."
  @spec path(atom(), keyword()) ::
          {:ok, Path.t()} | {:error, :not_configured | :not_downloaded}
  def path(id, opts \\ []) do
    app = Keyword.get(opts, :app, @app)

    case Application.get_env(app, :models, [])[id] do
      nil ->
        {:error, :not_configured}

      spec ->
        target = Keyword.fetch!(spec, :path)

        if File.exists?(target) do
          {:ok, target}
        else
          {:error, :not_downloaded}
        end
    end
  end

  # ----------------------------------------------------------------
  # Internal: download mechanics.
  # ----------------------------------------------------------------

  defp do_fetch(id, source, path, sha256) do
    File.mkdir_p!(Path.dirname(path))

    partial = path <> ".partial"
    File.rm(partial)

    case stage(id, source, partial) do
      :ok ->
        cond do
          sha256 != nil and not sha_ok?(partial, sha256) ->
            File.rm(partial)
            {:error, {:sha_mismatch, id}}

          true ->
            File.rename!(partial, path)
            bytes = File.stat!(path).size
            Logger.info("[model_hub] #{id}: OK (#{div(bytes, 1024 * 1024)} MB)")
            {:ok, path}
        end

      {:error, reason} ->
        File.rm(partial)
        {:error, reason}
    end
  end

  # Stage the source into `partial`. Both branches leave the bytes at
  # `partial` so `do_fetch/4` can run the same SHA check + atomic
  # rename regardless of where they came from.
  defp stage(id, {:file, src}, partial) do
    Logger.info("[model_hub] #{id}: copying #{src} → #{partial}")

    case File.cp(src, partial) do
      :ok -> :ok
      {:error, reason} -> {:error, {:copy_failed, src, reason}}
    end
  end

  defp stage(id, source, partial) do
    url = resolve(source)
    Logger.info("[model_hub] #{id}: fetching #{url} → #{partial}")
    stream_to_file(url, partial)
  end

  defp resolve({:url, url}), do: url

  defp resolve({:hf, repo, file}) do
    "https://huggingface.co/#{repo}/resolve/main/#{file}"
  end

  defp resolve({:hf, repo, file, opts}) do
    rev = Keyword.get(opts, :revision, "main")
    "https://huggingface.co/#{repo}/resolve/#{rev}/#{file}"
  end

  defp stream_to_file(url, dest) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    headers = [
      {~c"user-agent", ~c"model_hub/0.1.0 (Elixir/Nerves)"}
    ]

    request_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(host_of(url))
      ],
      timeout: :infinity,
      autoredirect: true
    ]

    case File.open(dest, [:write, :binary]) do
      {:ok, fd} ->
        case :httpc.request(
               :get,
               {String.to_charlist(url), headers},
               request_opts,
               stream: String.to_charlist(dest),
               body_format: :binary
             ) do
          {:ok, :saved_to_file} ->
            File.close(fd)
            :ok

          {:ok, {{_v, code, _r}, _h, _body}} ->
            File.close(fd)
            {:error, {:http_status, code}}

          {:error, reason} ->
            File.close(fd)
            {:error, {:http_error, reason}}
        end

      {:error, reason} ->
        {:error, {:file_open, reason}}
    end
  end

  defp host_of(url) do
    %URI{host: host} = URI.parse(url)
    host || ""
  end

  defp sha_ok?(path, expected) do
    actual =
      path
      |> File.stream!(2048, [:read, :binary])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    String.downcase(expected) == actual
  end
end
