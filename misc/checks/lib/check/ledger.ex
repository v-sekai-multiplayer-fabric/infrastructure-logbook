# What the books may not say.
#
# The booking logic stays in `ledger.py`, which derives hours from git history and is the
# single source of those numbers. This concern asks it questions and judges the answers; it
# does not recompute them. Retyping an allocator in a second language is how two answers to
# one question get created, and the whole point of the ledger is that there is one.
#
# An unmet precondition is a failure, never a skip: no python3, no ledger.py, a ledger that
# will not parse -- each is a FAIL here, because a silent skip reads exactly like a pass.
#
#     mix check ledger

defmodule Check.Ledger do
  alias Check.Lib

  def checks do
    [
      %{
        label: "a day never books more seconds than a day holds",
        kind: :local,
        run: &a_day_holds_a_day/1,
        # Generated from git, so no edit here can overbook a day. The control supplies the
        # reading instead, with the figure the un-allocated version actually produced.
        break: &Map.put(&1, :day, [{"2026-08-16", 144_144.0}])
      },
      %{
        label: "planned and spent time never share an account",
        kind: :local,
        run: &plan_and_spend_are_separate/1,
        # The check reads two files this repository generates, so no manifest edit can
        # perturb it. The control supplies the overlap instead.
        break: &Map.put(&1, :separation, ["Expenses:Delivery:Mesh"])
      }
    ]
  end

  @seconds_in_a_day 86_400

  @doc """
  A day's books MUST NOT sum past the seconds a day contains.

  The ledger allocates one pool -- every interval between consecutive commits anywhere in
  the workspace -- and charges each interval to the repository whose commit closed it. That
  makes a day's books a partition of that day's wall clock, so 86400 is not a budget
  somebody chose, it is arithmetic. A day over it means the allocation stopped being a
  partition and started double-counting, whatever the totals look like.

  This is not hypothetical. The first version summed each repository's own sessions instead
  of allocating, and charged 2026-08-16 with 144,144 s -- 1.67 days -- and nothing objected,
  because nothing was checking. It was found by reading, which is the way to find things
  that a check should be finding.

  The margin is thin enough to matter: the busiest day books 77,475 s, 89.7% of one. A
  regression here would look plausible rather than absurd, which is exactly when a gate
  earns its keep.
  """
  def a_day_holds_a_day(ctx) do
    case ctx[:day] || overbooked_days() do
      {:error, why} ->
        [why]

      days ->
        for {day, seconds} <- days do
          "#{day} books #{round(seconds)} s, and a day holds #{@seconds_in_a_day}; " <>
            "the allocation is double-counting rather than partitioning"
        end
    end
  end

  defp overbooked_days do
    case python("""
         for d, s in ledger.overbooked_days():
             print(f"{d}\\t{s}")
         """) do
      {:ok, out} ->
        for line <- String.split(out, "\n", trim: true) do
          [day, seconds] = String.split(line, "\t", parts: 2)
          {day, String.to_float(seconds)}
        end

      {:error, why} ->
        {:error, why}
    end
  end

  @doc """
  Planned time and spent time MUST never share an account or a unit.

  The plan estimates work nobody has done, so it books liabilities: an obligation
  outstanding. The ledger books expenses: hours that went somewhere. Put an estimate in an
  expense account and the plan reports itself as progress, which is the failure this whole
  ledger exists to stop, arriving from the inside.

  The unit does most of this work without help: planned time is PLANNED-SECONDS and spent
  time is SECONDS, and beancount will not balance across commodities, so netting one against
  the other fails at parse time with exit 1. This check is the belt to those braces -- it
  reads both files, intersects their account names, and fails on any overlap, because the
  day somebody unifies the units to tidy them up is the day the tool stops refusing.
  """
  def plan_and_spend_are_separate(ctx) do
    case ctx[:separation] || shared_accounts() do
      {:error, why} ->
        [why]

      shared ->
        for account <- Enum.sort(shared) do
          "#{account} carries both planned and spent time; an estimate reads as progress"
        end
    end
  end

  defp shared_accounts do
    with {:ok, out} <- python("print(ledger.SPENT)\nprint(ledger.PLANNED)"),
         [spent, planned] <- String.split(out, "\n", trim: true) do
      cond do
        not File.exists?(spent) -> {:error, "#{Path.basename(spent)} is missing"}
        not File.exists?(planned) -> {:error, "#{Path.basename(planned)} is missing"}
        true -> MapSet.intersection(accounts(spent), accounts(planned))
      end
    else
      {:error, why} -> {:error, why}
      _ -> {:error, "ledger.py did not name both ledger files"}
    end
  end

  @kinds ~w(Assets: Liabilities: Equity: Income: Expenses:)

  defp accounts(path) do
    for line <- path |> File.read!() |> String.split("\n"),
        s = String.trim(line),
        String.starts_with?(s, @kinds) or String.starts_with?(s, Enum.map(@kinds, &("open " <> &1))),
        into: MapSet.new() do
      s |> String.replace_prefix("open ", "") |> String.split() |> hd()
    end
  end

  # `ledger.py` is imported rather than re-implemented. It lives in misc/scripts, which is
  # found from the repository root rather than from this file: a compiled module's __DIR__
  # is where its source sat when it was built, which is not where the ledger is.
  defp python(body) do
    script = """
    import sys
    sys.path.insert(0, #{inspect(Path.join(Lib.root(), "misc/scripts"))})
    import ledger
    #{body}
    """

    case Lib.cmd("python3", ["-c", script]) do
      {out, 0} ->
        {:ok, out}

      {out, _} ->
        first = out |> String.split("\n", trim: true) |> List.last() |> Kernel.||("?")
        {:error, "ledger.py could not be read: #{String.slice(first, 0, 120)}"}
    end
  end
end

