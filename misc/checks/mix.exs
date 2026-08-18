defmodule FabricChecks.MixProject do
  @moduledoc """
  The doc gate, as one application.

  Each concern is a module under `lib/check/`, and each is runnable on its own:

      mix check                 # every concern
      mix check --fast          # what the checkout answers; the commit stage
      mix check --slow          # what only a remote answers; the pre-push stage
      mix check --self-test     # every check must fail on broken input
      mix check authority       # one concern, by name

  No dependencies. Everything it reads is the manifest, the checkout, `gh`, `git` and
  `ledger.py`, all of which are already required to work here.
  """

  use Mix.Project

  def project do
    [
      app: :fabric_checks,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      deps: deps(),
      elixirc_paths: ["lib"],
      dialyzer: dialyzer()
    ]
  end

  # dialyxir is the only dependency, it is dev-only, and it never ships: the gate itself
  # runs on stdlib alone, so a checkout with no hex cache can still run `mix check`.
  defp deps do
    [{:dialyxir, "~> 1.4", only: [:dev], runtime: false}]
  end

  # Mix and xmerl are called into and would otherwise be unknown functions. The PLT is kept
  # inside the project so a cold CI runner caches one directory and not a home directory it
  # does not own.
  defp dialyzer do
    [
      plt_add_apps: [:mix, :xmerl, :public_key],
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      flags: [:error_handling, :underspecs, :unmatched_returns]
    ]
  end

  # xmerl parses the manifest. It ships with OTP, so this declares it rather than fetches it.
  def application do
    [extra_applications: [:xmerl]]
  end
end
