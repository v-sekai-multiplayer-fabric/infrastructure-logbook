# One property-testing framework per language, and the same one everywhere.
#
#     mix check properties
#
# A property test states what must hold for every input rather than for the inputs somebody
# thought of, and this organisation already runs three of them. What it did not have is one
# answer per language: `interactor-triangulation` reached for RapidCheck while nothing else in
# C++ used it, and a second framework in a language is a second set of generators, a second
# shrinker and a second way to write the same assertion.

defmodule Check.Properties do
  alias Check.Lib

  def checks do
    [
      %{
        label: "a property test uses the framework its language has settled on",
        kind: :local,
        run: &settled_framework/1,
        # Reads the children's trees, which no edit here reaches, so the control supplies the
        # reading rather than perturbing a file.
        break: &Map.put(&1, :properties, [{"interactor-somewhere", "cpp", "rapidcheck"}])
      }
    ]
  end

  # The settled answer per language, and what a departure looks like. Each `alternatives` entry
  # is a framework that does the same job and is not the one chosen: finding it is the finding.
  @settled %{
    "cpp" => %{
      chosen: "fuzztest",
      evidence: ~r/fuzztest|FUZZ_TEST/,
      alternatives: ~w(rapidcheck),
      why: "Google FuzzTest: coverage-guided, so it finds inputs a random generator does not"
    },
    "elixir" => %{
      chosen: "propcheck",
      evidence: ~r/propcheck|PropCheck/,
      alternatives: ~w(stream_data),
      why: "PropCheck, with Dialyzer beside it: the types are checked as well as the properties"
    },
    "python" => %{
      chosen: "hypothesis",
      evidence: ~r/hypothesis|given\(/,
      alternatives: ~w(pytest-quickcheck),
      why: "Hypothesis: the shrinker is the reason, and nothing else in Python has one as good"
    }
  }

  # Where a dependency is declared, per language. A framework is named in a build file long
  # before it is imported, and the build file is the shorter thing to read.
  @manifests %{
    "cpp" => ~w(CMakeLists.txt conanfile.txt vcpkg.json),
    "elixir" => ~w(mix.exs),
    "python" => ~w(pyproject.toml requirements.txt setup.py)
  }

  @vendored ~w(thirdparty third_party vendor deps _build node_modules .git build)

  @doc """
  A repository that writes property tests uses the framework its language settled on.

  Only a **departure** is a finding. A repository with no property tests at all is not one, and
  saying so matters: this gate is about two frameworks in one language, not about coverage.

  Forks are skipped. `Lib.mirrors/0` names them, and a fork's test framework is its upstream's
  choice — changing it would fork a build file this project does not own, which is the same
  boundary the README rules stop at.
  """
  def settled_framework(ctx) do
    case ctx[:properties] do
      nil -> ctx |> scan() |> Enum.map(&message/1)
      injected -> Enum.map(injected, &message/1)
    end
  end

  defp scan(ctx) do
    ws = Lib.workspace_root()
    mirrors = Lib.mirrors()
    read_only = Lib.read_only()
    allowed = Lib.allowed_orgs()

    # Authority, not authorship. `Lib.ours/1` is our own remote only, and it silently excluded
    # `interactor-triangulation` -- which is on `fire`, writes property tests, and is exactly
    # the repository this gate was written for. A boundary that leaves out the case that
    # prompted the rule is the wrong boundary; this is the one the citation gate stops at.
    projects =
      for p <- Lib.projects(ctx.mtext),
          p.org in allowed,
          not Map.has_key?(mirrors, p.name),
          not Map.has_key?(read_only, p.name),
          dir = Path.join(ws, p.path),
          File.dir?(dir),
          do: {p.name, dir}

    IO.puts("note   the property checks scanned #{length(projects)} children")

    for {name, dir} <- projects,
        {lang, settled} <- @settled,
        found <- departures(dir, lang, settled),
        do: {name, lang, found}
  end

  defp departures(dir, lang, settled) do
    text = read_all(dir, @manifests[lang])

    # An alternative named in a build file is the finding. The chosen one being absent is not:
    # a repository is free to write no property tests, and most do not.
    Enum.filter(settled.alternatives, fn alt ->
      String.contains?(text, alt) and not Regex.match?(settled.evidence, text)
    end)
  end

  defp read_all(dir, names) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.reject(fn path ->
      path |> Path.relative_to(dir) |> Path.split() |> Enum.any?(&(&1 in @vendored))
    end)
    |> Enum.filter(&(Path.basename(&1) in names and File.regular?(&1)))
    |> Enum.map_join("\n", fn f ->
      case File.read(f) do
        {:ok, t} -> strip_comments(t)
        _ -> ""
      end
    end)
  end

  # Comments are stripped before anything is matched, and this is not tidiness.
  #
  # The first version of this gate read whole files and reported clean against a repository
  # that had really departed: a comment in a *different* build file explained why FuzzTest was
  # chosen, that mention counted as evidence, and the finding was suppressed. Prose about a
  # framework is not a declaration of one, and a gate that cannot tell them apart is green for
  # the wrong reason -- which is the failure mode this workspace keeps finding in its own
  # checks.
  defp strip_comments(text) do
    text
    |> String.split("\n")
    |> Enum.map(&Regex.replace(~r/#.*$/, &1, ""))
    |> Enum.join("\n")
  end

  defp message({name, lang, found}) do
    settled = @settled[lang]

    "#{name} declares #{found} in a #{lang} build file and no #{settled.chosen}; " <>
      "#{settled.why}. Two frameworks in one language is two sets of generators and two " <>
      "ways to write the same assertion"
  end
end
