# What a Lean project must carry: Mathlib, a document, a build in CI, and no holes.
#
#     mix check lean
#
# Lean is CI-able, which is the whole argument. A language whose build is a single `lake build`
# has no excuse for being verified on one desk only, so a Lean project states itself in markdown
# and builds in CI at minimum, and `sorry` is a gate rather than a habit.
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
      },
      %{
        label: "every Lean project states itself in markdown",
        kind: :local,
        run: &documented/1,
        break: &Map.put(&1, :lean_docs, [{"contract-somewhere", "2-contract/somewhere"}])
      },
      %{
        label: "every Lean project builds in CI",
        kind: :local,
        run: &ci_gated/1,
        break: &Map.put(&1, :lean_ci, [{"contract-somewhere", "2-contract/somewhere"}])
      },
      %{
        label: "no Lean source leaves a proof unproved",
        kind: :local,
        run: &no_holes/1,
        break: &Map.put(&1, :lean_holes, [{"contract-somewhere", "Proof.lean", 42, "sorry"}])
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
  @doc """
  A Lean project MUST state itself in markdown.

  The minimum is a `README.md`, and the minimum is where this stops: the README rules already
  hold it to forty lines and forbid it listing the filesystem, so what is added here is that the
  document exists at all. Four Lean projects had no markdown of any kind, which no other gate
  here noticed because every one of them checks a README that is present.
  """
  def documented(ctx) do
    case ctx[:lean_docs] do
      nil ->
        projects = lean_projects(ctx)
        IO.puts("note   the Lean document check scanned #{length(projects)} Lean projects")

        for {name, path, dir} <- projects, not File.regular?(Path.join(dir, "README.md")) do
          {name, path}
        end
        |> Enum.map(fn {name, path} -> "#{name} is a Lean project with no README.md (#{path})" end)

      injected ->
        Enum.map(injected, fn {name, path} ->
          "#{name} is a Lean project with no README.md (#{path})"
        end)
    end
  end

  # A workflow that builds Lean, rather than a `.github/workflows` directory that exists. A
  # repository can carry a lint job and no build, and a gate satisfied by the directory would
  # call that CI. The evidence is the build being invoked.
  @ci_evidence ~r/lake\s+build|lake\s+exe|lean-action/

  @doc """
  A Lean project MUST build in CI.

  Lean is CI-able with one command against a cached Mathlib, so a proof verified only on the
  desk that wrote it is a choice rather than a constraint. `contract-triangulation` is the case
  this was written from: it was created, proved, and green on one macOS desk, which is the same
  criticism `interactor-triangulation` took for compiling twice ever.
  """
  def ci_gated(ctx) do
    case ctx[:lean_ci] do
      nil ->
        projects = lean_projects(ctx)
        IO.puts("note   the Lean CI check scanned #{length(projects)} Lean projects")

        for {name, path, dir} <- projects, not builds_in_ci?(dir) do
          {name, path}
        end
        |> Enum.map(fn {name, path} ->
          "#{name} is a Lean project with no CI that builds it (#{path}); " <>
            "a workflow using `leanprover/lean-action@v1` with `use-mathlib-cache: true` is what the rest use"
        end)

      injected ->
        Enum.map(injected, fn {name, path} ->
          "#{name} is a Lean project with no CI that builds it (#{path})"
        end)
    end
  end

  defp builds_in_ci?(dir) do
    dir
    |> Path.join(".github/workflows/*.{yml,yaml}")
    |> Path.wildcard()
    |> Enum.any?(fn f ->
      f |> read() |> strip_yaml_comments() |> then(&Regex.match?(@ci_evidence, &1))
    end)
  end

  defp strip_yaml_comments(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace(&1, ~r/#.*$/, ""))
  end

  @doc """
  No Lean source may leave a proof unproved.

  `sorry` elaborates and compiles. It leaves a declaration that looks exactly like a theorem, so
  the build stays green and the proof is not there -- the failure this workspace calls a check
  that reports, worse than none because it reads as coverage. `admit` is the tactic spelling of
  the same hole.

  This is textual and says so. The defining property is that no declaration's axiom set contains
  `sorryAx`, and asserting that means elaborating the project, which a doc gate running offline
  over seventeen checkouts cannot do. The axiom-level check belongs in each project's own CI --
  `contract-triangulation` has it as the `AxiomCheck` build target -- and this catches the
  declaration of a hole from one place, which is what stops one appearing unnoticed in sixteen
  others.

  Comments are stripped first, block as well as line, and that is not tidiness: all three
  occurrences of the word in this workspace today are prose explaining why `sorry` is not used,
  including in the file that gates it. A gate red on the sentence describing it would be the same
  defect the property gate records in reverse. Nested block comments end the strip early, which
  can only produce a false positive and never a false negative.
  """
  def no_holes(ctx) do
    case ctx[:lean_holes] do
      nil ->
        projects = lean_projects(ctx)
        IO.puts("note   the Lean hole check scanned #{length(projects)} Lean projects")

        for {name, _path, dir} <- projects,
            file <- lean_sources(dir),
            {line, n} <- file |> read() |> strip_lean_comments() |> String.split("\n") |> Enum.with_index(1),
            hole <- ~w(sorry admit),
            Regex.match?(~r/\b#{hole}\b/, line),
            do: {name, Path.relative_to(file, dir), n, hole}

      injected ->
        injected
    end
    |> Enum.map(fn {name, file, n, hole} -> "#{name}/#{file}:#{n} declares `#{hole}`" end)
  end

  @vendored ~w(.lake vendor deps _build node_modules .git build)

  defp lean_sources(dir) do
    dir
    |> Path.join("**/*.lean")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      path |> Path.relative_to(dir) |> Path.split() |> Enum.any?(&(&1 in @vendored))
    end)
  end

  defp strip_lean_comments(text) do
    text
    |> String.replace(~r|/-.*?-/|s, fn block ->
      # Keep the line count so a reported line number is the line in the file.
      String.duplicate("\n", length(String.split(block, "\n")) - 1)
    end)
    |> String.split("\n")
    |> Enum.map_join("\n", &String.replace(&1, ~r/--.*$/, ""))
  end

  # The project list every check above shares.
  defp lean_projects(ctx) do
    ws = Lib.workspace_root()
    mirrors = Lib.mirrors()
    read_only = Lib.read_only()
    allowed = Lib.allowed_orgs()

    for p <- Lib.projects(ctx.mtext),
        p.org in allowed,
        not Map.has_key?(mirrors, p.name),
        not Map.has_key?(read_only, p.name),
        dir = Path.join(ws, p.path),
        File.dir?(dir),
        lean?(dir),
        do: {p.name, p.path, dir}
  end
end
