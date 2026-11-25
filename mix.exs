defmodule Hayata.MixProject do
  use Mix.Project

  def project do
    otp_release = System.otp_release() |> String.to_integer()

    [
      app: :hayata,
      version: "2.1.0",
      elixir: ">= 1.11.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(otp_release),
      erlc_paths: erlc_paths(otp_release),
      erlc_options: [:debug_info],
      description: "An Erlang/OTP framework for building AI agents.",
      package: package()
    ]
  end

  def application do
    [
      mod: {:hayata_app, []},
      registered: [:hayata_sup],
      extra_applications: [:inets, :ssl, :telemetry, :mnesia]
    ]
  end

  defp deps(otp_release) do
    base = [
      {:telemetry, "1.4.2"}
    ]

    case otp_release >= 27 do
      true ->
        base

      false ->
        base ++ [{:jsx, "~> 3.1"}]
    end
  end

  defp erlc_paths(otp_release) do
    case otp_release >= 27 do
      true -> ["src"]
      false -> ["src", "compat"]
    end
  end

  defp package do
    [
      name: "hayata",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/zgbjgg/hayata"
      },
      files: [
        "src",
        "compat",
        "include",
        "mix.exs",
        "rebar.config",
        "rebar.config.script",
        "rebar.lock",
        "README.md",
        "LICENSE.md",
        "README_ELIXIR.md",
      ]
    ]
  end
end
