defmodule ModelHub.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :model_hub,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: [],
      name: "ModelHub",
      description:
        "First-boot model downloader from HuggingFace / URLs with SHA verification, for Nerves",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger, :inets, :ssl, :public_key, :crypto]]

  defp package do
    [
      name: :model_hub,
      licenses: ["Apache-2.0"],
      files: ~w(lib mix.exs README.md LICENSE),
      links: %{"GitHub" => "https://github.com/mlainez/model_hub"}
    ]
  end
end
