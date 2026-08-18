# Every Lean project depends on Mathlib.
#
#     mix check lean
#
# Lean without Mathlib has no `ring`, no `nlinarith` and no `Real`, so anything past linear
# integer arithmetic becomes hand-rolled lemmas. That is slower to write and weaker than what
# Mathlib already proves, and a proof nobody finishes is a proof this workspace does not have.
# The cost is build time, and `lake exe cache get` is what that cost is for.

defmodule Check.Lean do
  alias Check.Lib

  def checks do
    [
      %{
        label: "every Lean project depends on Mathlib",
        kind: :local,
        run: &mathlib_available/1,
        # Reads the children's trees, which no edit here reaches, so the control supplies the
        # reading rather than perturbing a file.
        break: &Map.put(&1, :lean, [{"contract-somewhere", "2-contract/somewhere"}])
      }
    ]
  end

  # A Lean project is one elan and lake would recognise as one. `lean-toolchain` is the file
  # elan reads and every Lean project here has one; a lakefile alone is named as well, so a
  # package that pins its toolchain elsewhere is still in scope rather than silently exempt.
  @markers ~w(lean-toolchain lakefile.lean lakefile.toml)

  # Where the dependency can be stated, and both are read.
  #
  # `lake-manifest.json` is the resolved set and it is the one that matters: `contract-protocol`,
  # `contract-interest-mgmt` and `interactor-spatial-oracle` all have Mathlib and none of them
  # names it, because each requires a `lean-*-core` package that does. A gate reading only the
  # lakefile would have called all three departures -- three confident false positives, from
  # exactly the "window nobody thought about" this workspace keeps writing down.
  #
  # The lakefile is read too, because a fresh clone has not run `lake update` and has no
  # manifest. Declared-but-unresolved is a dependency; absent from both is not.
  @declarations ~w(lakefile.lean lakefile.toml)
  @resolved "lake-manifest.json"

  @doc """
  A Lean project MUST have Mathlib available to it, declared or resolved.

  Only a departure is a finding, and the scan count is printed, because a check that looked at
  nothing reads exactly like a check that found nothing.
  """
  def mathlib_available(ctx) do
    case ctx[:lean] do
      nil -> ctx |> scan() |> Enum.map(&message/1)
      injected -> Enum.map(injected, &message/1)
    end
  end

  defp scan(ctx) do
    ws = Lib.workspace_root()
    mirrors = Lib.mirrors()
    read_only = Lib.read_only()
    allowed = Lib.allowed_orgs()

    # Authority, not authorship -- the same boundary the property gate settled on. A fork's
    # dependencies are its upstream's choice and adding Mathlib to one would fork a build file
    # this project does not own.
    projects =
      for p <- Lib.projects(ctx.mtext),
          p.org in allowed,
          not Map.has_key?(mirrors, p.name),
          not Map.has_key?(read_only, p.name),
          dir = Path.join(ws, p.path),
          File.dir?(dir),
          lean?(dir),
          do: {p.name, p.path, dir}

    IO.puts("note   the Lean check scanned #{length(projects)} Lean projects")

    for {name, path, dir} <- projects, not mathlib?(dir), do: {name, path}
  end

  defp lean?(dir), do: Enum.any?(@markers, &File.regular?(Path.join(dir, &1)))

  defp mathlib?(dir) do
    declared =
      Enum.any?(@declarations, fn f ->
        dir |> Path.join(f) |> read() |> strip_comments() |> names_mathlib?()
      end)

    declared or (dir |> Path.join(@resolved) |> read() |> names_mathlib?())
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  defp names_mathlib?(text), do: String.contains?(String.downcase(text), "mathlib")

  # Comments are stripped before anything is matched, for the reason the property gate records:
  # prose about a dependency is not a declaration of one, and a gate that cannot tell them apart
  # goes green for the wrong reason. A `-- mathlib is deliberately not used here` would
  # otherwise satisfy the check it is explaining the absence of.
  defp strip_comments(text) do
    text
    |> String.replace(~r|/-.*?-/|s, " ")
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      line |> String.replace(~r/--.*$/, "") |> String.replace(~r/#.*$/, "")
    end)
  end

  defp message({name, path}) do
    "#{name} is a Lean project with no Mathlib, declared or resolved (#{path}); " <>
      "add `require mathlib from git \"https://github.com/leanprover-community/mathlib4\" " <>
      "@ \"v4.30.0\"` and run `lake exe cache get`"
  end
end
