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
      },
      %{
        label: "no repository we may write to declares a blocked framework",
        kind: :local,
        run: &no_blocked_framework/1,
        break: &Map.put(&1, :blocked, [{"interactor-somewhere", "cpp", "rapidcheck"}])
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
  # Frameworks refused outright wherever this project may write, whatever else is present.
  #
  # This is a different rule from the settled one above and needs to be, in two ways.
  #
  # **It fires on presence, not on departure.** `settled_framework/1` reports an alternative
  # only while the chosen framework is absent, which is the right shape for "pick one" and the
  # wrong shape for "not this one": a repository declaring both satisfies it, because the
  # evidence for FuzzTest suppresses the finding against RapidCheck. Two frameworks in one
  # language is the thing being prevented, so a blocked one is a finding wherever it appears.
  # That case was live rather than hypothetical -- `interactor-triangulation` had two open pull
  # requests at once, one fetching RapidCheck and one porting to FuzzTest.
  #
  # **The boundary is wider.** The settled rule skips forks, because a fork's test framework is
  # its upstream's choice. Authority is the question here instead of authorship: a fork we
  # maintain sits on our own remote and is ours to push to, so `Lib.mirrors/0` is in scope.
  # `Lib.read_only/0` stays out -- membership is not authority, and nothing here writes to
  # another organisation's repository at all.
  @blocked %{"rapidcheck" => "cpp"}

  @doc """
  No repository this project may write to declares a blocked framework.

  RapidCheck is the entry. C++ here settled on Google FuzzTest, which is coverage-guided, and
  the two were not competing on quality: the case for RapidCheck was that FuzzTest would run on
  Linux only, so the properties would run nowhere anybody edits. That premise was wrong.
  FuzzTest builds and runs on macOS arm64 under AppleClang, because `ctest` runs it in
  unit-test mode and only the coverage-guided mode needs libFuzzer -- and on the first run it
  found a sliver the random generator had not.
  """
  def no_blocked_framework(ctx) do
    case ctx[:blocked] do
      nil -> ctx |> scan_blocked() |> Enum.map(&blocked_message/1)
      injected -> Enum.map(injected, &blocked_message/1)
    end
  end

  defp scan_blocked(ctx) do
    ws = Lib.workspace_root()
    read_only = Lib.read_only()
    allowed = Lib.allowed_orgs()

    projects =
      for p <- Lib.projects(ctx.mtext),
          p.org in allowed,
          not Map.has_key?(read_only, p.name),
          dir = Path.join(ws, p.path),
          File.dir?(dir),
          do: {p.name, dir}

    IO.puts("note   the blocklist scanned #{length(projects)} children we may write to")

    for {name, dir} <- projects,
        {framework, lang} <- @blocked,
        String.contains?(read_all(dir, @manifests[lang]), framework),
        do: {name, lang, framework}
  end

  defp blocked_message({name, lang, framework}) do
    "#{name} declares #{framework} in a #{lang} build file, which is blocked wherever this " <>
      "project may write; #{@settled[lang].why}"
  end

end
