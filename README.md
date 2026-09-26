# nerves_model_hub

> ### ⚠️ Very early work — built for a workshop, not for production
>
> This package was written for the **Goatmire Elixir workshop** on running
> Nerves on Fairphone 3 hardware. It exists for tinkering and teaching.
>
> There are no stability guarantees and APIs will change without notice.
>
> See [`nerves_ai`](https://github.com/mlainez/nerves_ai) for the full
> stack and the workshop context.

First-boot model fetch for Nerves devices.

Declare the model files your firmware needs in app config; they land on
writable storage at boot and stay there. Part of the
[`nerves_ai`](https://github.com/mlainez/nerves_ai) stack, but it has no
AI dependencies — it's a general-purpose "make sure these files exist"
library.

## Why

Model weights are too big to commit and often too big to bake into every
firmware image. They also must not be re-downloaded on every boot. This
library declares them once, fetches what's missing, and gets out of the
way.

## Install

```elixir
defp deps do
  [{:nerves_model_hub, github: "mlainez/nerves_model_hub"}]
end
```

## Configure

```elixir
config :nerves_model_hub,
  models: [
    tinyllama: [
      source: {:hf, "TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF",
                    "tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf"},
      path: "/data/models/tinyllama.gguf",
      sha256: "optional-but-recommended"
    ],
    yolov5n: [
      source: {:file, "/srv/models/yolov5n.onnx"},
      path: "/data/models/yolov5n.onnx"
    ]
  ]
```

Then call it once, early, before anything that reads those files:

```elixir
{:ok, paths} = NervesModelHub.ensure_all()
```

## Sources

| Source | Behaviour |
|---|---|
| `{:hf, "owner/repo", "file"}` | Resolves to the HuggingFace `resolve/main` URL. Pass a 4-tuple with `revision:` to pin a branch or commit. |
| `{:url, "https://…"}` | Any HTTPS URL. |
| `{:file, "/srv/…"}` | A local path — **copied, not downloaded**. Use this to bake models into a read-only rootfs overlay at build time and move them onto writable storage on first boot, with no network at all. |

## Behaviour worth knowing

**Idempotent.** A model whose `:path` already exists and is non-empty is
skipped. If you gave a `:sha256` and the cached file fails the check, it's
deleted and re-fetched. The SHA check re-reads the whole file on every
boot, which takes a few seconds for large models on slow storage.

**Atomic.** Everything stages to `<path>.partial`, is fsynced, and is
renamed on success, so a crash or power cut mid-fetch never leaves a
truncated file that looks valid. There's no resume — an interrupted
fetch restarts.

**TLS.** Peers are verified against the OS trust store, or CAStore's
bundled Mozilla roots when the system image ships none. Redirects to
other hosts, such as Hugging Face's LFS CDN, are followed and verified.
Gated Hugging Face repos, which need an access token, are not supported.

**Non-fatal.** `ensure_all/0` returns `{:error, [{id, reason}, …]}` for
partial failures rather than raising, so one missing model doesn't stop
your device booting.

**Network is your problem.** It uses Erlang's `:httpc` and assumes
connectivity is already up — bring up `vintage_net` (or equivalent)
first. `{:file, …}` sources need no network at all.

## API

```elixir
NervesModelHub.ensure_all()               # fetch everything missing
NervesModelHub.ensure_one(:id, spec)      # one model
NervesModelHub.path(:id)                  # {:ok, path} | {:error, :not_downloaded}
```

`ensure_all/1` options:

* `models:` — use this model list instead of reading app config.
* `app:` — read `config :<app>, :models` instead of
  `config :nerves_model_hub, :models`.

`nerves_ai` reads `config :nerves_ai, :models` and calls `ensure_all/1`
from a background task that retries failed downloads with backoff.

## Toolchain

Built and tested with Erlang/OTP 29.1.1 and Elixir 1.20.4, matching the
official Nerves systems (see `.tool-versions`).

## License

Apache-2.0
