# What the remotes say, which a checkout cannot answer.
#
# Everything here costs a round trip, so everything here is :network and runs at pre-push
# rather than on every commit. What belongs in this file is only what a clone cannot carry:
# a repository's default branch, its fork flag, the Pages URL it serves, and whether a name
# still resolves to itself. A licence and a revision are on disk once `repo sync` has run,
# and asking GitHub for either is a round trip to learn something already local.
#
#     mix check remotes

defmodule Check.Remotes do
  alias Check.Lib

  def checks do
    [
      %{
        label: "every manifest revision exists on its remote",
        kind: :network,
        run: &revisions_exist/1,
        break: &Lib.break_manifest(&1, ~s(revision="dev"), ~s(revision="no-such-xyz"))
      },
      %{
        label: "README revision exceptions match the manifest",
        kind: :network,
        run: &revision_table/1,
        # Comparing against live default branches cannot be perturbed by editing a file
        # here, so the control replaces the answer: a repository claiming to default to what
        # the manifest already tracks must stop being an exception, and the README must go
        # wrong.
        break: &Map.put(&1, :defaults, %{"datasource-foundationdb" => "portability-consensus"})
      },
      %{
        label: "the mirror list matches what GitHub calls a fork",
        kind: :network,
        run: &mirror_list/1,
        # Asking GitHub cannot be perturbed by editing a file here, so the control replaces
        # the answer: a repository that is a fork and is not on the list must be reported.
        break: &Map.put(&1, :forks, %{"transport-asset" => {true, "somebody-else/transport-asset"}})
      },
      %{
        label: "no document names a repository that moved",
        kind: :network,
        run: &names_resolve/1,
        break:
          &Map.put(&1, :docs, [
            {"1-transport/fanout", "README.md",
             "It reads from fabric-authority-plane every tick.\n"}
          ])
      },
      %{
        label: "a project that serves Pages keeps the name its URL contains",
        kind: :network,
        run: &pages_names/1,
        # Asking GitHub what it serves cannot be perturbed by editing a file here, so the
        # control replaces the answer -- with the exact URL the real rename produced.
        break:
          &Map.put(&1, :pages, %{
            "multiplayer-fabric-manuals" =>
              "https://v-sekai-multiplayer-fabric.github.io/contract-manuals/"
          })
      }
    ]
  end

  @doc "Every revision the manifest names must be a branch that exists on the remote."
  def revisions_exist(ctx) do
    Lib.projects(ctx.mtext)
    |> Task.async_stream(&ls_remote/1, max_concurrency: 16, timeout: 180_000)
    |> Enum.flat_map(fn
      {:ok, msg} -> List.wrap(msg)
      {:exit, _} -> ["a remote check timed out"]
    end)
  end

  defp ls_remote(p) do
    case Lib.cmd("git", ["ls-remote", "--heads", p.url, p.revision]) do
      {out, 0} ->
        if String.trim(out) == "",
          do: "#{p.name}: branch #{p.revision} does not exist on remote",
          else: nil

      _ ->
        "#{p.name}: cannot reach #{p.url}"
    end
  end

  @doc """
  The README lists the projects tracking something other than their own default branch.

  This compared each revision against the manifest's modal branch, which asked the wrong
  question. `main` being commonest here is a fact about this manifest, not about any
  repository in it, so a project whose own default is `gyre` or `legacy` or `master` came
  out as an exception for agreeing with itself.

  The question worth asking is whether the manifest tracks something the repository does not
  default to, because that is the case somebody has to have chosen and may need to undo. It
  costs a call per project, so this is a network check; it was local when it compared the
  manifest against itself, which is exactly why it could not see this.
  """
  def revision_table(ctx) do
    projects = Lib.projects(ctx.mtext)
    got = default_branches(ctx, projects)

    unreadable =
      for p <- projects, is_nil(got[p.name]) do
        "cannot read the default branch of #{p.name}"
      end

    actual =
      for p <- projects, d = got[p.name], d != nil, p.revision != d, into: MapSet.new() do
        {p.name, p.revision}
      end

    if Lib.flat(ctx.rtext) =~ "tracks its repository's default branch" do
      unreadable ++ table_rows(ctx.rtext, actual) ++ table_count(ctx.rtext, actual)
    else
      unreadable ++ ["README: no 'tracks its repository's default branch' sentence to check"]
    end
  end

  defp default_branches(ctx, projects) do
    case ctx[:defaults] do
      nil ->
        Lib.gh_many(
          Map.new(projects, fn p -> {p.name, ["repos/#{p.org}/#{p.name}", "--jq", ".default_branch"]} end)
        )
        |> Map.new(fn {k, v} -> {k, blank_to_nil(v)} end)

      injected ->
        Map.new(projects, fn p -> {p.name, Map.get(injected, p.name)} end)
    end
  end

  defp table_rows(rtext, actual) do
    rows =
      ~r/^\| `([\w.-]+)` \| `([^`]+)` \|$/m
      |> Regex.scan(rtext)
      |> MapSet.new(fn [_, name, rev] -> {name, rev} end)

    documented_but_default =
      for {name, rev} <- Enum.sort(MapSet.difference(rows, actual)) do
        "README documents {'#{name}', '#{rev}'}, which tracks its own default"
      end

    exception_but_undocumented =
      for {name, rev} <- Enum.sort(MapSet.difference(actual, rows)) do
        "{'#{name}', '#{rev}'} tracks something other than its default, README omits it"
      end

    documented_but_default ++ exception_but_undocumented
  end

  # The sentence introducing the table counts its rows in words, and adding a row does not
  # update it. That went stale once already: the table grew while the prose did not, and
  # every other check passed, because they compare rows and none of them reads the number.
  @words %{
    "zero" => 0, "one" => 1, "two" => 2, "three" => 3, "four" => 4, "five" => 5,
    "six" => 6, "seven" => 7, "eight" => 8, "nine" => 9, "ten" => 10
  }

  defp table_count(rtext, actual) do
    case Regex.run(~r/The (\w+) that do(?:es)? not/, Lib.flat(rtext)) do
      nil ->
        ["README: no 'The <n> that do not' sentence to check"]

      [_, word] ->
        if Map.get(@words, String.downcase(word)) == MapSet.size(actual),
          do: [],
          else: ["README says '#{word}', the manifest has #{MapSet.size(actual)}"]
    end
  end

  @doc """
  The list of repositories whose README is upstream's MUST match what GitHub reports.

  A mirror is exempt from the forty-line rule and from the licence check, because its README
  belongs to whoever wrote the code. That is a real exemption and a hand-kept list, which is
  the combination that rots: a fork added later keeps being measured against a rule that does
  not apply to it, and an entry that stops being a fork keeps an exemption it no longer earns.

  So the list is held to the fact. Every repository GitHub flags as a fork must be in it,
  with the parent GitHub names; every entry must be a flagged fork or carry a written reason.
  """
  def mirror_list(ctx) do
    projects = Lib.projects(ctx.mtext)
    ours = Enum.filter(projects, &(&1.remote == Lib.our_remote()))
    mirrors = Lib.mirrors()
    unflagged = Lib.unflagged_mirrors()
    facts = fork_facts(ctx, ours)

    for p <- ours, msg = mirror_verdict(p, facts[p.name], mirrors, unflagged), msg != nil do
      msg
    end
    |> Enum.sort()
  end

  defp fork_facts(ctx, ours) do
    case ctx[:forks] do
      nil ->
        Lib.gh_many(
          Map.new(ours, fn p ->
            {p.name, ["repos/#{p.org}/#{p.name}", "--jq", ~s([.fork, .parent.full_name // ""] | @tsv)]}
          end)
        )
        |> Map.new(fn
          {k, nil} -> {k, :unreadable}
          {k, raw} ->
            case String.split(raw, "\t") do
              [fork | rest] -> {k, {fork == "true", rest |> List.first() |> blank_to_nil()}}
            end
        end)

      injected ->
        Map.new(ours, fn p -> {p.name, Map.get(injected, p.name, {false, nil})} end)
    end
  end

  defp mirror_verdict(p, :unreadable, _mirrors, _unflagged),
    do: "cannot read whether #{p.name} is a fork"

  defp mirror_verdict(p, nil, _mirrors, _unflagged),
    do: "cannot read whether #{p.name} is a fork"

  defp mirror_verdict(p, {fork?, parent}, mirrors, unflagged) do
    listed? = Map.has_key?(mirrors, p.name)

    cond do
      fork? and not listed? ->
        "#{p.name} is a fork of #{parent}, and is not exempted as a mirror"

      fork? and parent != nil and mirrors[p.name] != parent ->
        "#{p.name} is exempted as a mirror of #{mirrors[p.name]}, " <>
          "but GitHub says its parent is #{parent}"

      not fork? and listed? and not Map.has_key?(unflagged, p.name) ->
        "#{p.name} is exempted as a mirror but GitHub does not call it a fork, " <>
          "and no reason is written down"

      true ->
        nil
    end
  end

  @doc """
  No document may name a repository that only answers on a redirect.

  GitHub keeps every old name working, so a rename leaves prose that resolves and is wrong,
  and nothing fails anywhere. RFD 0111 asks for the pins in the same pass as the rename, and
  this is what makes that checkable rather than remembered.
  """
  def names_resolve(ctx) do
    projects = Lib.projects(ctx.mtext)
    live = org_repo_names()

    if MapSet.size(live) == 0 do
      ["cannot list the organisation's repositories"]
    else
      docs = Lib.child_docs(ctx, projects)

      wanted =
        docs
        |> Enum.flat_map(fn {_p, _n, text} -> tokens(text) end)
        |> Enum.reject(&MapSet.member?(live, &1))
        |> Enum.uniq()
        |> Enum.sort()

      resolved =
        Lib.gh_many(Map.new(wanted, fn t -> {t, ["repos/#{Lib.our_remote()}/#{t}", "--jq", ".name"]} end))
        |> Map.new(fn {k, v} -> {k, blank_to_nil(v)} end)

      for {path, name, text} <- docs,
          tok <- text |> tokens() |> Enum.uniq() |> Enum.sort(),
          not MapSet.member?(live, tok),
          now = resolved[tok],
          now != nil and now != tok do
        "#{path}/#{name} names #{tok}, which is now #{now}"
      end
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  # A fenced block is a command or a config, not prose making a claim, and a clone URL that
  # still redirects is somebody's working command line. A repository under another owner is
  # that owner's, whatever it is called here -- ahujasid/blender-mcp is upstream of
  # transport-blender-mcp, and resolving the bare token against this organisation turns a
  # correct citation into a rename to apply.
  defp tokens(text) do
    text
    |> String.replace(~r/```.*?```/s, "")
    |> String.replace(~r/github\.com\/(?!#{Regex.escape(Lib.our_remote())}\/)[\w.-]+\/[\w.-]+/, "")
    |> then(&Regex.scan(~r/\b[a-z][a-z0-9]*(?:-[a-z0-9]+){1,4}\b/, &1))
    |> Enum.map(&hd/1)
  end

  defp org_repo_names do
    case Lib.gh(["orgs/#{Lib.our_remote()}/repos?per_page=100", "--paginate", "--jq", ".[].name"]) do
      nil -> MapSet.new()
      out -> out |> String.split() |> MapSet.new()
    end
  end

  @doc """
  A project that serves GitHub Pages MUST keep the name its published URL contains.

  A repository rename redirects git and the web UI. It does not redirect Pages: the site
  moves to org.github.io/<new-name>/ and every published link 404s, with nothing in the
  repository to notice. That is not hypothetical -- `multiplayer-fabric-manuals` was renamed
  to `contract-manuals` for the hexagon layout and took every published RFD link with it.

  The check reads the URL GitHub actually serves rather than a list kept by hand, because a
  list is the thing that goes stale when Pages is switched on for something new.
  """
  def pages_names(ctx) do
    ours = Enum.filter(Lib.projects(ctx.mtext), &(&1.remote == Lib.our_remote()))

    got =
      case ctx[:pages] do
        nil ->
          Lib.gh_many(
            Map.new(ours, fn p -> {p.name, ["repos/#{p.org}/#{p.name}/pages", "--jq", ".html_url"]} end)
          )
          |> Map.new(fn {k, v} -> {k, blank_to_nil(v)} end)

        injected ->
          Map.new(ours, fn p -> {p.name, Map.get(injected, p.name)} end)
      end

    for p <- ours,
        url = got[p.name],
        url != nil,
        slug = url |> String.trim_trailing("/") |> String.split("/") |> List.last(),
        slug != p.name do
      "#{p.name} serves Pages at #{url}, whose name is #{slug}; " <>
        "a Pages URL does not redirect, so the published links are dead"
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end

