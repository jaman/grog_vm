defmodule GrogVM.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/jaman/grog_vm"

  def project do
    [
      app: :grog_vm,
      version: @version,
      elixir: "~> 1.18",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      description:
        "SCUMM v5 scripts compiled to Elixir and run against a host the game supplies.",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v" <> @version,
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
