defmodule Mix.Tasks.Check do
  @shortdoc "Run the doc gate: every concern, or one named concern"

  @moduledoc """
  The one entry point. Each concern is a module that states its own checks, and this
  assembles them.

      mix check                 # every concern
      mix check --fast          # what the checkout answers; the commit stage
      mix check --slow          # what only a remote answers; the pre-push stage
      mix check --self-test     # every check must fail on broken input
      mix check authority       # one concern, by name
      mix check readme ledger   # two of them

  Naming a concern is not a filter over the output -- the other concerns are not run at all,
  which is the point of the split. A change to the licence policy is re-read and re-run
  without loading the ledger or touching the network.

  Exits non-zero on drift. An unmet precondition (no network, missing file) is a FAIL, never
  a skip: a silent skip reads exactly like a pass.
  """

  use Mix.Task

  @concerns %{
    "manifest" => Check.Manifest,
    "readme" => Check.Readme,
    "remotes" => Check.Remotes,
    "authority" => Check.Authority,
    "workspace" => Check.Workspace,
    "words" => Check.Words,
    "ledger" => Check.Ledger
  }

  # The order concerns run in. A map has no order and the output is read top to bottom, so
  # this states one rather than letting the key order decide.
  @order ~w(manifest readme remotes authority workspace words ledger)

  @impl Mix.Task
  def run(argv) do
    {flags, named} = Enum.split_with(argv, &String.starts_with?(&1, "-"))

    case Enum.reject(named, &Map.has_key?(@concerns, &1)) do
      [] -> :ok
      unknown -> Mix.raise("no such concern: #{Enum.join(unknown, ", ")}. " <>
                             "Known: #{Enum.join(@order, ", ")}")
    end

    wanted = if named == [], do: @order, else: Enum.filter(@order, &(&1 in named))

    wanted
    |> Enum.flat_map(& @concerns[&1].checks())
    |> Check.Lib.run(flags)
  end
end
