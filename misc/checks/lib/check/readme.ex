# What this repository's README claims, and what the children's READMEs may not become.
#
# The manifest is the source of truth; the README is prose about it. Any disagreement is a
# README bug, and this is the concern that says so.
#
#     mix check readme

defmodule Check.Readme do
  alias Check.Lib

  def checks do
    [
      %{
        label: "README counts match the manifest",
        kind: :local,
        run: &counts/1,
        break: &break_count/1
      },
      %{
        label: "every path the README names exists",
        kind: :network,
        run: &referenced_paths/1,
        # `default.xml` is the one path the manifest README will always name, because it is
        # the file that repository exists to hold. The pattern was `misc/checks`, which went
        # dead the moment the checks moved out of it: a control that replaces nothing passes
        # while proving nothing, which is what `--self-test` is for.
        break: &Lib.break_readme(&1, "default.xml", "default-nope.xml")
      },
      %{
        label: "every README this project owns is under 40 lines",
        kind: :local,
        run: &readme_length/1,
        # Padding the README past the limit is the failure this gate exists to catch, and
        # it exercises the same line count the real check reads.
        # The heading is one the manifest README actually carries: a pattern that stops
        # matching makes the control dead rather than red, which `--self-test` reports and
        # which the old heading here became when the checks moved out of that repository.
        break: &Lib.break_readme(&1, "## The layout", "## The layout" <> String.duplicate("\n", 45))
      },
      %{
        label: "no README lists the filesystem",
        kind: :local,
        run: &no_filesystem_listing/1,
        # Reads children's READMEs against their real directories, which no edit here
        # reaches, so the control replaces the reading.
        break: &Map.put(&1, :listing, [{"transport-somewhere", 7}])
      },
      %{
        label: "no README lays a listing out as a table",
        kind: :local,
        run: &no_table_listing/1,
        # A control that names a file dies the day somebody renames it, and this one did
        # inside the hour it was written: it named `CLAUDE.md` and `ledger/`, and both left
        # this repository the same morning. So it names nothing. It reads two real entries of
        # a real checkout and lays them out as a table, which is the defect exactly, and the
        # only way left for it to die is a project with fewer than two files -- which it
        # reports as a dead control rather than passing over.
        break: &table_control/1
      }
    ]
  end

  # Bump whatever count the README states, rather than naming one. A literal here is a copy
  # of a number that lives in another repository and changes whenever a project is added, and
  # it has already gone dead once: it broke "47 projects across 5" for long enough that the
  # README reached 52 with the control replacing nothing and certifying nothing. Pinning it to
  # the current number only moves the next death, and CI proves that -- it clones `fabric` at
  # main, so the number there is not even the number on the desk that wrote this.
  defp break_count(ctx) do
    rtext =
      Regex.replace(~r/(\d+)( projects across )/, ctx.rtext, fn _all, n, rest ->
        Integer.to_string(String.to_integer(n) + 1) <> rest
      end)

    %{ctx | rtext: rtext}
  end

  @doc "The README's project and org counts must equal what the manifest holds."
  def counts(ctx) do
    {_default, remotes, projects} = Lib.parse_manifest(ctx.mtext)

    case Regex.run(~r/(\d+) projects across (\d+) GitHub orgs/, Lib.flat(ctx.rtext)) do
      nil ->
        ["README: no 'N projects across M GitHub orgs' sentence to check"]

      [_, n, m] ->
        []
        |> add_if(
          String.to_integer(n) != length(projects),
          "README says #{n} projects, manifest has #{length(projects)}"
        )
        |> add_if(
          String.to_integer(m) != map_size(remotes),
          "README says #{m} orgs, manifest has #{map_size(remotes)} remotes"
        )
    end
  end

  # Paths the README names that belong to another repository. These are verified against
  # that repo rather than excused: a foreign reference is still a claim. Runtime paths
  # (created by a tool, never tracked) are the only things skipped outright.
  @external %{
    "dataflow-coco-gemx/check_readme_claims.py" => "weftspun/dataflow-coco-gemx"
  }
  # Directories a tool makes, which no repository tracks and none can be asked for. Both
  # checkout paths are `repo sync`'s doing rather than a claim about a file, and each is
  # already answered by a gate that asks the right question: the manifest lists
  # `0-infrastructure/logbook` as a project, and `Check.Remotes` asks GitHub whether the
  # repository behind it is there.
  @runtime MapSet.new([".repo/manifests", "0-infrastructure/logbook", "node_modules/.bin", ".repo/"])
  @owned_suffixes ~w(.py .exs .xml .md .json .yml .yaml .toml .cfg .sh)

  @doc """
  Every path the README names must exist -- here, or in the repo it is attributed to.

  Naming a file that is not there is the most common way documentation lies, and an
  allowlist of 'external' names just moves the lie somewhere unchecked.
  """
  def referenced_paths(ctx) do
    # Backticked spans AND the words inside fenced blocks: a command in a code fence that
    # names a script which is not there is the same lie, and the more copy-pasted one.
    backticked = Regex.scan(~r/`([^`\s]+)`/, ctx.rtext) |> Enum.map(&Enum.at(&1, 1))

    fenced =
      Regex.scan(~r/```.*?```/s, ctx.rtext)
      |> Enum.flat_map(fn [block] -> String.split(block) end)

    (backticked ++ fenced)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&check_token/1)
  end

  defp check_token(tok) do
    cond do
      MapSet.member?(@runtime, tok) ->
        []

      Map.has_key?(@external, tok) ->
        {target, path} =
          case @external[tok] do
            nil -> {tok, nil}
            repo -> {repo, tok |> String.split("/") |> List.last()}
          end

        api = "repos/#{target}" <> if path, do: "/contents/#{path}", else: ""

        if Lib.gh([api, "--jq", ".name"]),
          do: [],
          else: ["README names `#{tok}`, absent from #{target}"]

      not repo_path?(tok) ->
        []

      not File.exists?(Path.join(Lib.manifest_root(), tok)) ->
        ["README names `#{tok}`, which does not exist in that repo"]

      true ->
        []
    end
  end

  defp repo_path?(tok) do
    cond do
      String.starts_with?(tok, ["http", "~", "-", "<", "$", "@"]) -> false
      String.contains?(tok, ":") -> false
      String.ends_with?(tok, "/") -> false
      String.ends_with?(tok, @owned_suffixes) -> true
      # A slashed token is only a path if its first segment is really a directory here;
      # this keeps branch names such as feat/turboquant-on-master from being mistaken
      # for one.
      true ->
        String.contains?(tok, "/") and
          File.dir?(Path.join(Lib.manifest_root(), tok |> String.split("/") |> hd()))
    end
  end

  @doc """
  Every README this project is the primary source for stays under 40 lines.

  A README that grows past a screen stops being read, and the part nobody reads is the part
  that goes stale without anybody noticing. The limit applies to the git repositories on
  this project's own remote, and skips a mirror, whose README belongs to its upstream.

  A child that is not cloned is skipped rather than reported. This check therefore holds
  where it runs, which is every workspace that has the child on disk.
  """
  def readme_length(ctx) do
    max = Lib.readme_max()
    ws = Lib.workspace_root()
    own = line_count(ctx.rtext)

    mine =
      if own >= max, do: ["README.md is #{own} lines, limit #{max - 1}"], else: []

    children =
      for p <- Lib.ours(Lib.projects(ctx.mtext)),
          path = Path.join([ws, p.path, "README.md"]),
          File.exists?(path),
          n = path |> File.read!() |> line_count(),
          n >= max do
        "#{p.path}/README.md is #{n} lines, limit #{max - 1}"
      end

    mine ++ children
  end

  # A file ending in a newline has as many lines as it has newlines, not one more. Counting
  # the empty string after the final "\n" made every 39-line README read as 40 and put four
  # children over a limit they were inside, which is the shape of error a port makes and a
  # comparison against the old output catches.
  defp line_count(text) do
    body = if String.ends_with?(text, "\n"), do: String.slice(text, 0..-2//1), else: text
    if body == "", do: 0, else: length(String.split(body, "\n"))
  end

  @doc """
  A README this project writes MUST NOT contain a listing of its own directories.

  `ls` already answers that question, and answers it correctly forever. A listing in prose
  answers it as of whenever somebody last looked: add a directory and the README is
  silently incomplete, rename one and it is silently wrong, and no check anywhere compares
  the two. It is the same duplication the forty-line rule exists to squeeze out.

  Detection is grounded rather than guessed. A fenced block counts as a listing when two or
  more of its lines open with a token that names a directory that actually exists in that
  checkout, so an ordinary shell block or a code sample cannot trip it.

  Forks are exempt for the reason they are exempt from the length rule: that README belongs
  to whoever wrote the code.
  """
  def no_filesystem_listing(ctx) do
    case ctx[:listing] do
      nil -> scan_listings(ctx)
      injected ->
        for {name, n} <- injected do
          "#{name}/README.md lists #{n} of its own directories; `ls` already does that"
        end
    end
  end

  defp scan_listings(ctx) do
    ws = Lib.workspace_root()

    for p <- Lib.ours(Lib.projects(ctx.mtext)),
        readme = Path.join([ws, p.path, "README.md"]),
        File.exists?(readme),
        hits = listing_hits(readme, Path.join(ws, p.path)),
        hits >= 2 do
      "#{p.path}/README.md lists #{hits} of its own directories; " <>
        "`ls` already does that, and does not go stale"
    end
    |> Enum.sort()
  end

  defp listing_hits(readme, dir) do
    dirs =
      case File.ls(dir) do
        {:ok, entries} -> entries |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> MapSet.new()
        _ -> MapSet.new()
      end

    # Only an unlanguaged fence. A block that declares sh or bash is a command somebody
    # runs, and its first word may well name a directory -- `cmake -S . -B build` tripped
    # this against the cmake/ directory in two repositories before the language was read.
    ~r/```\n(.*?)```/s
    |> Regex.scan(File.read!(readme))
    |> Enum.flat_map(fn [_, block] -> String.split(block, "\n") end)
    |> Enum.count(fn line ->
      case line |> String.trim() |> String.split() do
        [] ->
          false

        [head | _] ->
          head = String.trim_trailing(head, "/")
          head != "" and MapSet.member?(dirs, head |> String.split("/") |> hd())
      end
    end)
  end

  @doc """
  A README this project writes MUST NOT lay a listing out as a table.

  The same rule as the fence above, in the other syntax and with the same failure behind it.
  A row of `` `settings.json` `` against a gloss is a listing of the checkout wearing a
  table's clothes: add a file and the README is silently incomplete, rename one and it is
  silently wrong, and `ls` was answering that question correctly the whole time. A table is
  also the one shape of prose the forty-line limit rewards, which is how four of them
  arrived.

  Detection is grounded the same way, so a table that is really tabular survives it. A row
  counts only when its first cell names a path that exists in that checkout, and two are
  needed. `entity-packet`'s wire format scores zero, because a byte offset is not a
  filename, and so does `bus`'s platform matrix; the file lists in the logbook, `gyre` and
  `entity-store` score three to five.

  Forks are exempt for the reason they are exempt from the other two rules: that README
  belongs to whoever wrote the code.
  """
  def no_table_listing(ctx) do
    ws = Lib.workspace_root()

    docs =
      case ctx[:tables] do
        nil ->
          for p <- Lib.ours(Lib.projects(ctx.mtext)),
              readme = Path.join([ws, p.path, "README.md"]),
              File.exists?(readme),
              do: {p.path, File.read!(readme)}

        injected ->
          injected
      end

    for {path, text} <- docs,
        hits = table_hits(text, Path.join(ws, path)),
        hits >= 2 do
      "#{path}/README.md lays #{hits} of its own files out as a table; " <>
        "that is a listing, and `ls` already does it without going stale"
    end
    |> Enum.sort()
  end

  defp table_control(ctx) do
    ws = Lib.workspace_root()
    root = Lib.root()

    # Grounded in this repository rather than in a sibling. Scanning the children died in CI
    # for the same reason the named files died here: it read a checkout that was not there.
    # A bare clone has no siblings, so the control injected nothing and reported itself dead.
    # This repository is the one directory guaranteed to exist wherever the checks run at all.
    case File.ls(root) do
      {:ok, [_, _ | _] = entries} ->
        [a, b] = entries |> Enum.sort() |> Enum.take(2)

        Map.put(ctx, :tables, [
          {Path.relative_to(root, ws), "| | |\n|---|---|\n| `#{a}` | one |\n| `#{b}` | two |\n"}
        ])

      _ ->
        ctx
    end
  end

  # A row is only read as a row when the document has a rule row somewhere, which is what
  # makes it a table rather than a line that happens to open with a pipe.
  defp table_hits(text, dir) do
    lines = text |> String.split("\n") |> Enum.map(&String.trim/1)

    if Enum.any?(lines, &rule_row?/1) do
      Enum.count(lines, fn line ->
        not rule_row?(line) and named_path?(first_cell(line), dir)
      end)
    else
      0
    end
  end

  # `|---|---|` and `| :--- | ---: |`: the line that separates a header from its body, and
  # the only line in a table that is punctuation rather than content.
  defp rule_row?(line), do: Regex.match?(~r/^\|[\s:|-]*-[\s:|-]*\|$/, line)

  defp first_cell("|" <> rest) do
    rest |> String.split("|") |> hd() |> String.trim() |> String.replace("`", "")
  end

  defp first_cell(_), do: ""

  defp named_path?("", _dir), do: false

  defp named_path?(cell, dir) do
    File.exists?(Path.join(dir, String.trim_trailing(cell, "/")))
  end

  defp add_if(list, false, _), do: list
  defp add_if(list, true, msg), do: list ++ [msg]
end

