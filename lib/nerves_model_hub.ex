defmodule NervesModelHub do
  @moduledoc """
  First-boot model fetch for Nerves devices.

  Declare the models your firmware needs in app config and they get
  streamed from HuggingFace (or any HTTPS URL) to local storage on
  boot. After the first successful download the file lives on
  `/root` (or wherever you point it) and subsequent boots skip the
  network round-trip.

  ## Configuration

      config :nerves_model_hub,
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

  At app start, call `NervesModelHub.ensure_all/0` from your own
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

  Downloads write to `<path>.partial`, are fsynced, and are renamed
  into place on success. A crash mid-download leaves the partial
  file; the next run retries from scratch (no resume). Empty files
  are never treated as cached.

  ## Network

  Uses Erlang `:httpc`. TLS peers are verified against the OS trust
  store, or CAStore's bundled roots when the OS has none. Bring up
  connectivity (`vintage_net` etc.) before this runs; a fetch is only
  attempted when the target file is missing. Gated Hugging Face repos
  (which need a token) are not supported.
  """

  require Logger

  @app :nerves_model_hub

  @doc """
  Walk `config :nerves_model_hub, :models, [...]` and download any
  whose `:path` is missing. Returns `{:ok, %{id => path}}` on
  success, `{:error, [{id, reason}, ...]}` on partial failure.

  Options:

    * `:models` — the model list to use instead of reading app config.
    * `:app` — read `config :<app>, :models` instead of
      `config :nerves_model_hub, :models` (`nerves_ai` uses `:nerves_ai`).
  """
  @spec ensure_all(keyword()) :: {:ok, %{atom() => Path.t()}} | {:error, [{atom(), term()}]}
  def ensure_all(opts \\ []) do
    app = Keyword.get(opts, :app, @app)
    models = Keyword.get_lazy(opts, :models, fn -> Application.get_env(app, :models, []) end)

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
      cached?(path) and (sha256 == nil or sha_ok?(path, sha256)) ->
        Logger.debug("[nerves_model_hub] #{id}: cached at #{path}")
        {:ok, path}

      cached?(path) ->
        Logger.warning(
          "[nerves_model_hub] #{id}: cached file at #{path} failed SHA check, re-downloading"
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

        if cached?(target) do
          {:ok, target}
        else
          {:error, :not_downloaded}
        end
    end
  end

  # ----------------------------------------------------------------
  # Internal: download mechanics.
  # ----------------------------------------------------------------

  # A zero-byte file is what an interrupted write can leave behind.
  defp cached?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp do_fetch(id, source, path, sha256) do
    partial = path <> ".partial"

    with :ok <- mkdir(Path.dirname(path)),
         _ = File.rm(partial),
         :ok <- stage(id, source, partial),
         :ok <- check_staged(id, partial, sha256),
         :ok <- fsync(partial),
         :ok <- rename(partial, path) do
      bytes = File.stat!(path).size
      Logger.info("[nerves_model_hub] #{id}: OK (#{div(bytes, 1024 * 1024)} MB)")
      {:ok, path}
    else
      {:error, _} = err ->
        File.rm(partial)
        err
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp check_staged(id, partial, sha256) do
    cond do
      not cached?(partial) -> {:error, {:empty_download, id}}
      sha256 != nil and not sha_ok?(partial, sha256) -> {:error, {:sha_mismatch, id}}
      true -> :ok
    end
  end

  # Flush file data to storage before the rename makes it visible, so
  # a power cut can't leave a truncated file under the final name.
  defp fsync(path) do
    with {:ok, fd} <- :file.open(String.to_charlist(path), [:read, :write, :binary, :raw]) do
      result = :file.sync(fd)
      :ok = :file.close(fd)
      result
    end
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:rename_failed, to, reason}}
    end
  end

  # Stage the source into `partial`. Both branches leave the bytes at
  # `partial` so `do_fetch/4` can run the same SHA check + atomic
  # rename regardless of where they came from.
  defp stage(id, {:file, src}, partial) do
    Logger.info("[nerves_model_hub] #{id}: copying #{src} → #{partial}")

    case File.cp(src, partial) do
      :ok -> :ok
      {:error, reason} -> {:error, {:copy_failed, src, reason}}
    end
  end

  defp stage(id, source, partial) do
    url = resolve(source)
    Logger.info("[nerves_model_hub] #{id}: fetching #{url} → #{partial}")
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

    headers = [{~c"user-agent", ~c"nerves_model_hub/0.1.0 (Elixir/Nerves)"}]

    # SNI comes from each request's host, so redirects to another host
    # (Hugging Face LFS files redirect to a CDN) verify correctly.
    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: cacerts(),
        depth: 4,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      connect_timeout: 30_000,
      timeout: :infinity,
      autoredirect: true
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_opts,
           stream: String.to_charlist(dest),
           body_format: :binary
         ) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_v, code, _r}, _h, _body}} -> {:error, {:http_status, code}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  # Prefer the OS trust store; fall back to CAStore's bundled Mozilla
  # roots when the system image ships none.
  defp cacerts do
    :public_key.cacerts_get()
  rescue
    _ -> CAStore.file_path() |> File.read!() |> :public_key.pem_decode() |> Enum.map(&elem(&1, 1))
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
