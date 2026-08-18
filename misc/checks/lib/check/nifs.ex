# How this organisation reaches the BEAM from C++, and what it may not hand-roll.
#
# Fine (elixir-nx/fine, Apache-2.0) is already the answer here: `taskweft/nif` vendors it and
# `interactor-ward` and `datasource-queen` carry it as thirdparty/taskweft/fine.hpp. This
# concern holds that in place rather than introducing it, which is the cheapest moment to add a
# gate -- before the second way of doing it exists.
#
#     mix check nifs

defmodule Check.Nifs do
  alias Check.Lib

  def checks do
    [
      %{
        label: "every repository that reaches the BEAM from C++ uses Fine",
        kind: :local,
        run: &fine_is_used/1,
        # Reads the children's trees, which no edit here reaches, so the control supplies the
        # reading: a repository with NIF code and no Fine anywhere in it.
        break: &Map.put(&1, :nifs, [{"interactor-somewhere", :no_fine, "src/nif.cpp"}])
      },
      %{
        label: "no first-party source hand-rolls an Erlang term",
        kind: :local,
        run: &no_raw_terms/1,
        break: &Map.put(&1, :nifs, [{"interactor-somewhere", :raw_enif, "src/encode.cpp"}])
      }
    ]
  end

  # Vendored code is not ours to rewrite, and Fine itself calls the C API on every line -- a
  # check that read it would report its own dependency as the defect.
  @vendored ~w(thirdparty third_party vendor deps _build node_modules .git)

  # What says a file talks to the BEAM. `ERL_NIF_TERM` is on the list because a header that
  # passes terms around without including erl_nif.h itself is still term-handling code.
  @nif_evidence ~r/\berl_nif\.h\b|\bERL_NIF_INIT\b|\bErlNifEnv\b|\bERL_NIF_TERM\b/

  # What says Fine is in use. Any one of the three is enough: the header vendored or included,
  # the hex dependency, or the include path a Makefile sets.
  @fine_evidence ~r/\bfine\.hpp\b|\bfine::|\{:fine\b|\bFINE_INCLUDE_DIR\b/

  # The boilerplate Fine exists to remove. Encoding and decoding, not the whole C API: a NIF
  # still calls enif_alloc and enif_thread_create, and neither is a term.
  @raw_term_call ~r/\benif_(make|get)_[a-z_]+\s*\(/

  @sources ~w(.c .cc .cpp .cxx .h .hh .hpp .hxx)

  # Where the other two kinds of Fine evidence live. `{:fine` is a hex dependency and sits in
  # mix.exs; `FINE_INCLUDE_DIR` is an include path and sits in whatever drives the build. Neither
  # is a C++ extension, so neither was ever read: `@fine_evidence` listed all three patterns while
  # `sources/1` could only ever supply the first, and a repository using Fine the ordinary way --
  # as a dependency, with the build pointing at its headers -- was reported as having no Fine.
  #
  # A gate that is wrong about correct code is worse than one that misses: the fix a reader
  # reaches for is to switch it off. Proved by test rather than by reading, against a real
  # checkout, for each of the three paths separately.
  @evidence_names ~w(mix.exs Makefile CMakeLists.txt rebar.config build.sh Makefile.probe)
  @evidence_exts ~w(.mk .cmake .mix .exs)

  @doc """
  A repository that reaches the BEAM from C++ MUST use Fine.

  Erlang's C API is a large surface and every project that touches it grows the same set of
  ad-hoc helpers, copied from the last project. Fine is that set, written once, and this
  organisation already vendors it. The gate exists so the second copy is never written: a
  repository that handles terms and cannot show Fine is one that has started its own.

  Two things make this checkable rather than a preference. Vendored trees are skipped, because
  Fine itself is C API code and reading it would report the dependency as the defect. And the
  count of repositories scanned is printed, because a scan that finds nothing because it looked
  at nothing reads exactly like a clean one.
  """
  def fine_is_used(ctx) do
    case ctx[:nifs] do
      nil -> ctx |> scan() |> Enum.filter(&match?({_, :no_fine, _}, &1)) |> Enum.map(&message/1)
      injected -> injected |> Enum.filter(&match?({_, :no_fine, _}, &1)) |> Enum.map(&message/1)
    end
  end

  @doc """
  No first-party source builds or reads an Erlang term by hand.

  `enif_make_*` and `enif_get_*` are what Fine replaces. A file that calls them directly is
  writing the boilerplate again, and doing it beside code that uses Fine is worse than doing it
  instead -- two conventions in one repository means the next reader has to learn which files
  follow which.

  The rest of the C API is untouched by this. A NIF still allocates and still starts threads,
  and neither of those is a term.
  """
  def no_raw_terms(ctx) do
    case ctx[:nifs] do
      nil -> ctx |> scan() |> Enum.filter(&match?({_, :raw_enif, _}, &1)) |> Enum.map(&message/1)
      injected -> injected |> Enum.filter(&match?({_, :raw_enif, _}, &1)) |> Enum.map(&message/1)
    end
  end

  # Both concerns read the same walk. It is done once per run and cached in the process
  # dictionary: scanning twice would double the work and print the count twice, and a count
  # printed twice reads as two scans rather than one.
  defp scan(ctx) do
    case Process.get(:nif_scan) do
      nil ->
        found = walk(ctx)
        Process.put(:nif_scan, found)
        found

      cached ->
        cached
    end
  end

  defp walk(ctx) do
    ws = Lib.workspace_root()
    projects = Lib.ours(Lib.projects(ctx.mtext))

    scanned =
      for p <- projects, dir = Path.join(ws, p.path), File.dir?(dir), do: {p.name, dir}

    # A scan that found nothing because it looked at nothing reads exactly like a clean one,
    # so the count is printed and a zero is called out rather than left to be inferred.
    case length(scanned) do
      0 ->
        IO.puts("note   the NIF checks scanned 0 children; nothing here was examined")

      n ->
        IO.puts("note   the NIF checks scanned #{n} children")
    end

    Enum.flat_map(scanned, fn {name, dir} ->
      files = sources(dir)
      nif_files = Enum.filter(files, &Regex.match?(@nif_evidence, read(&1)))

      cond do
        nif_files == [] ->
          []

        true ->
          fine? = Enum.any?(files ++ build_files(dir), &Regex.match?(@fine_evidence, read(&1)))
          raw = Enum.filter(nif_files, &Regex.match?(@raw_term_call, read(&1)))

          missing = if fine?, do: [], else: [{name, :no_fine, rel(dir, hd(nif_files))}]
          missing ++ for f <- raw, do: {name, :raw_enif, rel(dir, f)}
      end
    end)
    |> Enum.sort()
  end

  defp sources(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.reject(fn path ->
      parts = path |> Path.relative_to(dir) |> Path.split()
      Enum.any?(parts, &(&1 in @vendored))
    end)
    |> Enum.filter(&(Path.extname(&1) in @sources and File.regular?(&1)))
  end

  # Only for the Fine-evidence question. NIF detection and the raw-term rule stay on C and C++
  # sources, because a mix.exs naming a dependency is not a file that handles a term.
  defp build_files(dir) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.reject(fn path ->
      parts = path |> Path.relative_to(dir) |> Path.split()
      Enum.any?(parts, &(&1 in @vendored))
    end)
    |> Enum.filter(fn path ->
      base = Path.basename(path)
      (base in @evidence_names or Path.extname(base) in @evidence_exts) and File.regular?(path)
    end)
  end

  # A gate that crashes reads as a broken build rather than as a finding, and it is about to be
  # pointed at files nobody here wrote. An unreadable or non-UTF-8 file is not evidence of Fine
  # and not evidence of a term, so it reads as neither instead of ending the run.
  defp read(path) do
    case File.read(path) do
      {:ok, text} -> if String.valid?(text), do: text, else: ""
      {:error, _} -> ""
    end
  end

  defp rel(dir, path), do: Path.relative_to(path, dir)

  defp message({name, :no_fine, file}),
    do:
      "#{name} handles Erlang terms in #{file} and shows no Fine; the C API's boilerplate " <>
        "is what elixir-nx/fine already replaced, and taskweft/nif vendors it"

  defp message({name, :raw_enif, file}),
    do:
      "#{name}/#{file} calls enif_make_/enif_get_ directly; Fine encodes and decodes from the " <>
        "function signature, and two conventions in one repository is one too many"
end
