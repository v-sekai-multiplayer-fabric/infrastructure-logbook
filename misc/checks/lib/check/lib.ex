# The parts every concern needs, and nothing that belongs to one of them.
#
# Each concern is its own module under lib/check/ and each states its own checks. What lives here is what
# would otherwise exist in seven copies: reading the manifest, asking GitHub, knowing where
# the workspace root is, the policy tables that more than one concern consults, and the
# runner that prints a result and decides the exit code.
#
# A check is a map:
#
#     %{label: "...", kind: :local | :network, run: fn ctx -> [failure, ...] end,
#       break: fn ctx -> ctx end}
#
# `run` returns a list of failures, empty when the invariant holds. `break` returns a
# context that must make `run` fail -- the negative control, without which a gate certifies
# nothing. Python held these as module globals that the self-test assigned to; here the
# context is a value passed in, so a control cannot leak out of the check it belongs to.

defmodule Check.Lib do
  @moduledoc "Shared reading, shared policy, and the runner."

  require Record

  Record.defrecord(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))

  Record.defrecord(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  @doc """
  This repository's root, found by looking for it rather than by counting directories.

  A compiled module's `__DIR__` is where its source sat when it was built, and a mix task
  runs from wherever the caller was standing, so neither is a reliable base. Both are tried
  as starting points and each walks up until it finds `.git` beside `misc/checks`.

  `.git` is the marker because a repository root is what is being looked for, and that is
  the only thing every git checkout has. It was `CLAUDE.md`, and a document is a poor marker
  for a directory: deleting that file took every gate down with it, raising before a single
  check ran, because a prose file nobody thought of as load-bearing was.

  `misc/checks` stays in the pair so the answer is *this* repository rather than whichever
  one the caller happened to be standing in. Both are cheap to test and neither is a claim
  about content.

  It looked for `default.xml` beside `README.md` before that, because the manifest and the
  checks were one repository. They are not, and a marker naming the manifest would now find
  somebody else's root.
  """
  def root do
    [File.cwd!(), __DIR__]
    |> Enum.find_value(&climb_to(&1, [".git", "misc/checks"]))
    |> case do
      nil -> raise "cannot find .git beside misc/checks above #{File.cwd!()} or #{__DIR__}"
      found -> found
    end
  end

  defp climb_to(start, markers) do
    start
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != "/"))
    |> Enum.concat(["/"])
    |> Enum.find(fn dir -> Enum.all?(markers, &File.exists?(Path.join(dir, &1))) end)
  end

  @doc """
  Where the manifest repository is checked out, which is no longer where this one is.

  `repo init` clones the manifest to `.repo/manifests` and reads it from there, so that
  path is the manifest's home in a synced workspace and there is exactly one of it. This
  repository is an ordinary project on the `0-` side, two directories down from the root,
  and it reaches the manifest the way any project would: by finding the workspace root and
  looking in `.repo`.

  `FABRIC_MANIFEST` overrides it, and CI is the case that needs the override. A bare clone
  of this repository has no `.repo` and no sibling projects, so the manifest checks would
  have nothing to read; the workflow clones the manifest repository and points this at it,
  which keeps the gate answering the same question it answers on a desk.
  """
  def manifest_root do
    case System.get_env("FABRIC_MANIFEST") do
      nil -> Path.join([workspace_root(), ".repo", "manifests"])
      dir -> Path.expand(dir)
    end
  end

  def manifest_path, do: Path.join(manifest_root(), "default.xml")
  def readme_path, do: Path.join(manifest_root(), "README.md")

  @doc """
  Where the children sit: the directory that holds `.repo`.

  Every project checked out by `repo` sits under that directory, so finding it is the same
  question for all of them and this repository answers it the same way. It used to test for
  being at `.repo/manifests` and climb two, which was a rule about one repository's own
  placement; on the `0-` side that rule reads a directory that is not there.

  A plain clone has no `.repo` above it and no children beside it. That is a real layout --
  it is what CI runs -- so it falls back to this repository's own root and the checks that
  scan children then scan none, which `Check.Workspace` reports rather than passing quietly.
  """
  def workspace_root do
    case climb_to(root(), [".repo"]) do
      nil -> root()
      dir -> dir
    end
  end

  @doc "Collapse whitespace so a line wrap in the README cannot defeat a check."
  def flat(text), do: String.replace(text, ~r/\s+/, " ")

  # --- the manifest ------------------------------------------------------------------

  @doc """
  `{default_attrs, remotes, projects}` from the manifest text.

  xmerl is stdlib, so this parses the XML rather than pattern-matching it. A manifest that
  stops being well formed should fail loudly here, not silently match fewer projects.
  """
  def parse_manifest(text) do
    {doc, _} = :xmerl_scan.string(String.to_charlist(text), quiet: true)
    children = xmlElement(doc, :content)

    remotes =
      children
      |> elements_named(:remote)
      |> Map.new(fn e -> {attr(e, :name), attr(e, :fetch)} end)

    default =
      case elements_named(children, :default) do
        [e | _] -> %{remote: attr(e, :remote), revision: attr(e, :revision), sync_j: attr(e, :"sync-j")}
        [] -> nil
      end

    projects =
      children
      |> elements_named(:project)
      |> Enum.map(fn e ->
        name = attr(e, :name)
        remote = attr(e, :remote)
        fetch = Map.get(remotes, remote)

        %{
          name: name,
          # `path` is optional and defaults to the name, which is what repo does.
          path: attr(e, :path) || name,
          remote: remote,
          revision: attr(e, :revision),
          org: org_of(fetch),
          url: "#{fetch}/#{name}.git"
        }
      end)

    {default, remotes, projects}
  end

  def projects(text), do: parse_manifest(text) |> elem(2)

  def org_of(nil), do: ""
  def org_of(url), do: url |> String.trim_trailing("/") |> String.split("/") |> List.last()

  defp elements_named(children, want) do
    Enum.filter(children, fn
      e when Record.is_record(e, :xmlElement) -> xmlElement(e, :name) == want
      _ -> false
    end)
  end

  defp attr(element, want) do
    element
    |> xmlElement(:attributes)
    |> Enum.find_value(fn a ->
      if xmlAttribute(a, :name) == want, do: to_string(xmlAttribute(a, :value))
    end)
  end

  # --- asking GitHub -----------------------------------------------------------------

  @doc """
  Refuse a network call when the offline half is running.

  `--fast` selects the checks that a checkout can answer, and CI runs nothing else, because
  a repository-scoped token cannot read the organisation. That made the offline half offline
  by coincidence: every `:local` check happened not to call out, and nothing said it had to
  keep happening. A `gh` call added to a `:local` check would have gone unnoticed here and
  failed only on a runner.

  So it is stated instead. Every call to GitHub funnels through `gh/1` and every call to a
  remote through `cmd/3`, and both raise when the run declared itself offline. The rule is
  now the code rather than a habit, and breaking it fails on the desk where it was written.
  """
  def network!(what) do
    if Application.get_env(:fabric_checks, :network) == :forbidden do
      raise """
      #{what}

      That is a network call, and this run is the offline half. A check that reaches the
      network is :network and not :local -- change its kind rather than its call.
      """
    end

    :ok
  end

  @doc """
  One `gh api` call, returning stdout or nil. The unit the pool below maps over.

  stderr is captured rather than inherited. Asking for the Pages URL of a repository that
  serves none is a 404, which is the answer and not a fault, and letting gh print it puts
  a dozen lines of noise above a result that says everything passed.
  """
  def gh(args) do
    network!("gh api #{Enum.join(args, " ")}")
    do_gh(args)
  end

  # The catch lives here and not on gh/1. On gh/1 it swallowed the refusal above along with
  # everything else, so the guard compiled, read correctly, and did nothing -- which a test
  # of the guard caught and a reading of it would not have. It exists for one case, a `gh`
  # that is not installed, and it is kept away from anything that raises on purpose.
  defp do_gh(args) do
    case System.cmd("gh", ["api" | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  catch
    :error, _ -> nil
  end

  @doc """
  Run many `gh api` calls at once, keyed however the caller keys them.

  Serially the network checks took 181 s, nearly all of it waiting. Sixteen at a time,
  which is what `<default sync-j="16">` already asks repo for against the same host, so
  this is not a new number to tune.

  What belongs here is only what a checkout cannot answer. A repository's licence, its
  revisions and its current name are all on disk once `repo sync` has run, and asking
  GitHub for them is a round trip to learn something already local.
  """
  def gh_many(calls) do
    calls
    |> Task.async_stream(fn {k, args} -> {k, gh(args)} end,
      max_concurrency: 16,
      timeout: 120_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, pair} -> pair
      {:exit, _} -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  @doc """
  Run a shell command, returning `{output, status}`. Used where a check reads git.

  `git ls-remote` is a network call wearing git's clothes, so it goes through the same
  refusal as `gh`. Everything else here -- `check-ignore`, `find` -- reads the disk.
  """
  def cmd(exe, args, opts \\ []) do
    if exe == "git" and "ls-remote" in args do
      network!("git ls-remote #{Enum.at(args, 2)}")
    end

    do_cmd(exe, args, opts)
  end

  # Same reason as do_gh/1: the catch is for a missing executable, and it must not be in a
  # position to swallow a deliberate refusal.
  defp do_cmd(exe, args, opts) do
    System.cmd(exe, args, Keyword.merge([stderr_to_stdout: true], opts))
  catch
    :error, _ -> {"", 127}
  end

  # --- policy, consulted by more than one concern -------------------------------------

  def our_remote, do: "v-sekai-multiplayer-fabric"

  def readme_max, do: 40

  @doc """
  A fork this organisation maintains: we may write to it, and its README is still upstream's.

  This is the middle of three categories, and the middle one exists because authority and
  authorship are different questions that one list used to answer together.

    * **Ours outright.** Every gate applies.
    * **A fork we maintain** -- here. It sits on our own remote, so it is ours to push to and
      ours to add files to: the licence, `CITATION.cff` and `.DS_Store` gates all reach it. Its
      README does not, because editing that forks a document upstream owns and this project
      would then carry the diff forever.
    * **Another organisation's**, in `read_only/0`. Membership is not authority, so nothing
      here writes to one at all -- not a README, not a `CITATION.cff`.

  Being in the middle rather than exempt is the point for `CITATION.cff` especially. A fork is
  the repository whose provenance most needs stating -- it is upstream's code plus a branch
  nobody upstream has -- and lumping it with the untouchables left exactly those repositories
  never asked what they were made of.

  Each entry states its evidence rather than an opinion, and both carry GitHub's fork flag.
  """
  def mirrors do
    %{
      # This project owns the Windows builds here and none of the code, so the README is
      # upstream's to write. GitHub carries the fork flag for both of these.
      "datasource-foundationdb" => "apple/foundationdb",
      # The meshing pen's input surface. Forked so this project may write to it at all:
      # the mission is that anyone can build in world, and its front end sat on a remote
      # we may only read. The README stays V-Sekai's. Fork flag.
      "transport-xr-grid" => "V-Sekai/transport-xr-grid"
    }
  end

  @doc """
  Mirrors GitHub does not back with a fork flag. A fork made by pushing an existing history
  rather than by pressing the button carries no flag and no parent, so the evidence has to be
  stated instead of fetched -- and stating it is the point: an exemption with a reason can be
  argued with, and a list nobody can check is a list that grows.

  It is empty. `entities-godot` was the only entry and it left the manifest with
  `entities-assembly`, so there is nothing here to check rather than nothing worth checking.
  The map stays because the distinction it draws is the one `mirror_list/1` needs the moment
  a second unflagged fork arrives, and rediscovering it then is how the reason gets lost.
  """
  def unflagged_mirrors do
    %{}
  end

  @doc """
  The organisations this project may write to. Everything else in the manifest is read: its
  code is checked out, built against and cited, and nothing here pushes a commit, opens a
  pull request or files an issue against it.

  The list is short on purpose. A repository we can technically write to is not a repository
  we are entitled to change, and admin rights are a poor proxy for permission -- five
  V-Sekai repositories, one on taskweft and one on meshula were renamed from here on
  exactly that reasoning, which is the mistake this exists to stop repeating.

  `taskweft` is on the list because it is ours, stated by its owner rather than inferred
  from the admin bit that is sitting right there. That is the distinction the paragraph
  above is about: what put it here is the sentence, not the permission.

  `sinew-mocap`, `weftspun`, `lattice-world-weft`, `weftfit`, `chibifire-characters` and
  `chibifire-stages` are here on the same sentence from the same owner. No project in this
  manifest sits on any of them yet, so none of those entries decides anything today. They
  are written now so that the day a project arrives from one, the answer is already on the
  page instead of being read off the admin bit in a hurry.
  """
  @spec allowed_orgs() :: [String.t()]
  def allowed_orgs do
    [
      "v-sekai-multiplayer-fabric",
      "v-sekai-fire",
      "fire",
      "taskweft",
      "sinew-mocap",
      "weftspun",
      "lattice-world-weft",
      "weftfit",
      "chibifire-characters",
      "chibifire-stages"
    ]
  end

  @doc """
  Projects outside those organisations, each with whose they are. An entry here is a
  statement that the repository is read-only to this project; a project from an unlisted
  organisation fails the check rather than being quietly assumed one way or the other.
  """
  def read_only do
    %{
      # Added when interactor-triangulation's libraries became projects rather than empty
      # submodules. A library a build links is upstream's whatever directory it is checked
      # out into, and these two sit inside another project's checkout at libs/, which is
      # where its build expects them. They are already in fixed_names for the same reason,
      # from the other side: the name is not ours to change either.
      "geogram" => "BrunoLevy/geogram, linked by interactor-triangulation at libs/geogram",
      "pmp-library" => "pmp-library/pmp-library, linked by interactor-triangulation at libs/pmp-library",
      "QCBOR" => "laurencelundblade/QCBOR, the CBOR codec contract-bus links at libs/qcbor"
    }
  end

  @doc """
  Names that are not this repository's to change, so recomposition gives way rather than
  forcing a rename. `path` and `name` are independent in repo -- a project sits on its side
  either way -- so recomposition is a convention this repository imposes and these are where
  it costs more than it is worth. Each entry states its reason.
  """
  def fixed_names do
    %{
      # A repository name is also a published address when it serves Pages, and GitHub does
      # not redirect a Pages URL on rename. This one was renamed to contract-manuals and
      # every published RFD link 404'd until it was renamed back.
      "multiplayer-fabric-manuals" => "it publishes GitHub Pages, whose URL contains the name",
      # A library a project links sits inside that project's checkout, because its build
      # expects it there. The path is then three segments deep and cannot rebuild a
      # single-segment name, and the name is not ours to change either way.
      "geogram" => "BrunoLevy/geogram, linked by interactor-triangulation at libs/geogram",
      "pmp-library" => "pmp-library/pmp-library, linked by interactor-triangulation at libs/pmp-library",
      "QCBOR" => "laurencelundblade/QCBOR, linked by contract-bus at libs/qcbor",
      # The first entry here that is ours. Every one above it is a name another organisation
      # owns, so no rename could make the path rebuild it and the exception states a fact.
      # This one states a choice, and the choice is on the path rather than on the name:
      # Claude Code reads `.claude` and nothing else, so that path is fixed by a tool outside
      # this workspace, and a single-segment path rebuilds itself. Matching the name to it
      # meant a repository called `.claude`, which is hidden from an ordinary listing and
      # clones into a directory most shells will not show you. One of the two had to give,
      # the path could not, so the name did.
      "dot-claude" => "path is `.claude` because Claude Code reads that and only that",
      # The same fixed path, one level further in. Claude Code reads `.claude/plugins`, so
      # the path rebuilds to `.claude-plugins` and the repository is `agent-plugins`. The
      # name is not going to become that, and the path cannot move, so this is the second
      # entry stating a choice and it is the same choice as the one above it.
      "agent-plugins" => "path is `.claude/plugins` because Claude Code reads plugins there"
    }
  end

  @doc "The projects whose documents and files are this project's to write."
  def ours(projects) do
    Enum.filter(projects, &(&1.remote == our_remote() and not Map.has_key?(mirrors(), &1.name)))
  end

  # --- children's documents ------------------------------------------------------------

  @child_docs ~w(README.md CLAUDE.md AGENTS.md)

  @doc """
  `[{project_path, doc_name, text}]` for our children, or the injected fixture.

  Checks that scan the children read files rather than text passed in, so a breakage that
  edits the manifest or the README cannot reach them. Every document they read comes
  through here, and `ctx.docs` replaces the result. That is what makes their negative
  controls real: the control injects a defective document and the check must go red.
  """
  def child_docs(ctx, projects) do
    case ctx[:docs] do
      nil ->
        ws = workspace_root()

        for p <- ours(projects), name <- @child_docs, path = Path.join([ws, p.path, name]),
            File.exists?(path) do
          {p.path, name, File.read!(path)}
        end

      injected ->
        injected
    end
  end

  # --- the runner ------------------------------------------------------------------

  @doc """
  Run `checks` against argv and exit.

  `--fast` is the checkout, `--slow` is the network. Everything a `repo sync` already put
  on disk is answered from disk, so fast is the larger half and the one that runs on every
  commit; slow asks GitHub only about repository settings a clone cannot carry.

  A deferred check prints as deferred rather than vanishing, because a silent skip reads
  exactly like a pass.
  """
  def run(checks, argv) do
    self_test? = "--self-test" in argv
    only_local? = "--fast" in argv or "--local-only" in argv
    only_network? = "--slow" in argv

    ctx = %{
      mtext: File.read!(manifest_path()),
      rtext: File.read!(readme_path())
    }

    # Declared before a single check runs, and global rather than per-process so the pools
    # in gh_many/1 and revisions_exist/1 inherit it.
    Application.put_env(:fabric_checks, :network, if(only_local?, do: :forbidden, else: :allowed))

    selected =
      Enum.reject(checks, fn c ->
        (only_local? and c.kind == :network) or (only_network? and c.kind == :local)
      end)

    deferred = if only_local?, do: Enum.filter(checks, &(&1.kind == :network)), else: []

    failed = Enum.count(selected, fn c -> report(c.label, c.run.(ctx)) end)
    failed = failed + if self_test?, do: self_test(selected, ctx), else: 0

    scanned_children(ctx)
    for c <- deferred, do: IO.puts("defer  #{c.label}  (runs at pre-push, not skipped)")
    IO.puts("\n#{failed} failing check(s)")
    exit_with(failed)
  end

  # A document check with no children on disk passes because it saw nothing, which reads
  # exactly like passing because everything was clean. Say which it was.
  defp scanned_children(ctx) do
    seen =
      ctx
      |> child_docs(projects(ctx.mtext))
      |> MapSet.new(fn {path, _name, _text} -> path end)
      |> MapSet.size()

    tail =
      if seen == 0,
        do: "; a bare clone has none, and they hold where the workspace is",
        else: ""

    IO.puts("note   the document checks scanned #{seen} children#{tail}")
  end

  defp report(label, []) do
    IO.puts("ok    #{label}")
    false
  end

  defp report(label, bad) do
    IO.puts("FAIL  #{label}")
    for b <- bad, do: IO.puts("        #{b}")
    true
  end

  # Each check paired with an edit that must break it. A gate never shown to fail certifies
  # nothing -- see the Checks section of CLAUDE.md.
  defp self_test(selected, ctx) do
    IO.puts("\nnegative controls (each check must fail on broken input):")

    Enum.count(selected, fn c ->
      broken = c.break.(ctx)

      cond do
        broken == ctx ->
          IO.puts("FAIL  #{c.label}: breakage pattern no longer matches; control is dead")
          true

        c.run.(broken) == [] ->
          IO.puts("FAIL  #{c.label} PASSED on broken input — it is decoration")
          true

        true ->
          IO.puts("ok    #{c.label} fails on broken input")
          false
      end
    end)
  end

  @doc "Replace text in the manifest, for a control that perturbs what the check reads."
  def break_manifest(ctx, old, new), do: %{ctx | mtext: String.replace(ctx.mtext, old, new)}

  @doc "Replace text in the README, for the same reason."
  def break_readme(ctx, old, new), do: %{ctx | rtext: String.replace(ctx.rtext, old, new)}

  defp exit_with(0), do: :ok
  defp exit_with(_), do: System.halt(1)
end
