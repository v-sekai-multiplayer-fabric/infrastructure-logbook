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

  # Every concern, in the order they run. One list, because it used to be two -- a map of name
  # to module, and a separate `@order` naming the same keys again to give the run an order a map
  # does not have.
  #
  # Two lists of the same keys is a fact stated twice, and this one drifted the first time
  # somebody added a concern: registered in the map, absent from the order. `run/1` filters the
  # requested names against the order, so the new concern filtered to nothing. `mix check nifs`
  # then ran no checks at all and printed `0 failing check(s)` -- a pass reporting on an empty
  # set, which is the silent skip this module's own docstring calls a failure, and it read as a
  # broken module rather than as a missing registration.
  #
  # Deriving both from one ordered list makes that impossible instead of checkable. There is no
  # gate for it below because there is nothing left to gate: a concern is registered once, and a
  # concern that is not in this list does not exist rather than existing and never running.
  @concerns [
    {"manifest", Check.Manifest},
    {"readme", Check.Readme},
    {"remotes", Check.Remotes},
    {"authority", Check.Authority},
    {"workspace", Check.Workspace},
    {"words", Check.Words},
    {"nifs", Check.Nifs}, {"properties", Check.Properties},
    {"licences", Check.Licences},
    {"ledger", Check.Ledger}
  ]

  @order Enum.map(@concerns, &elem(&1, 0))
  @modules Map.new(@concerns)

  @impl Mix.Task
  def run(argv) do
    {flags, named} = Enum.split_with(argv, &String.starts_with?(&1, "-"))

    case Enum.reject(named, &Map.has_key?(@modules, &1)) do
      [] -> :ok
      unknown -> Mix.raise("no such concern: #{Enum.join(unknown, ", ")}. " <>
                             "Known: #{Enum.join(@order, ", ")}")
    end

    wanted = if named == [], do: @order, else: Enum.filter(@order, &(&1 in named))

    wanted
    |> Enum.flat_map(& @modules[&1].checks())
    |> Check.Lib.run(flags)
  end
end
