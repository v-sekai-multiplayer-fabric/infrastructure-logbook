# Whose each repository is, and what that entitles this project to do to it.
#
# The three checks here share one boundary: the organisations we may write to, less the
# mirrors and the read-only entries. Being able to push is not being entitled to, so the
# boundary is stated rather than inferred from an admin bit.
#
#     mix check authority

defmodule Check.Authority do
  alias Check.Lib

  def checks do
    [
      %{
        label: "every project is writable by us or listed read-only",
        kind: :local,
        run: &allowed_orgs/1,
        # Moving a project to an organisation on neither list is the drift this catches.
        # The org comes from the remote, so renaming the project changes nothing -- the
        # first attempt did that and the self-test called it decoration, correctly.
        break:
          &Lib.break_manifest(
            &1,
            ~s(<project name="contract-triangulation" path="2-contract/triangulation" remote="v-sekai-multiplayer-fabric"),
            ~s(<project name="contract-triangulation" path="2-contract/triangulation" remote="meshula")
          )
      },
      %{
        label: "every organisation we may write to exists on GitHub",
        kind: :network,
        run: &owners_exist/1,
        # Asking GitHub cannot be perturbed by editing a file here, so the control replaces
        # the answer: a name on the list that resolves to nothing must be reported.
        break: &Map.put(&1, :owners, %{"weftspun" => nil})
      },
      %{
        label: "every repository we own carries a usable licence",
        kind: :local,
        run: &licences/1,
        break: &Map.put(&1, :licences, %{"transport-fanout" => "AGPL-3.0"})
      },
      %{
        label: "every repository we own carries a CITATION.cff",
        kind: :local,
        run: &citations/1,
        # Reads the children's trees, which no edit here reaches, so the control supplies the
        # reading rather than perturbing a file.
        break: &Map.put(&1, :citations, [{"transport-fanout", :missing}])
      },
      %{
        label: "no repository we may write to carries a .DS_Store",
        kind: :local,
        run: &no_ds_store/1,
        # Reads the tree, which no edit to a document here reaches, so the control supplies
        # the reading -- the exact one this check produced the first time it was run.
        break: &Map.put(&1, :dsstore, [{"contract-triangulation", ".DS_Store"}])
      }
    ]
  end

  @doc """
  Every project MUST be in an organisation this project may write to, or be read-only.

  Being able to push is not being entitled to. Five V-Sekai repositories, one on taskweft
  and one on meshula were renamed from here because `gh api` said admin was true, which is
  a fact about credentials and not about whose work it is.

  So the manifest states it. A project in one of the allowed organisations may be changed;
  anything else has to appear in `read_only/0` with whose it is, and a project from an
  organisation on neither list fails rather than defaulting to either answer. That makes
  adding a dependency from somewhere new a decision somebody writes down.

  The check reads the manifest alone and cannot see a push that already happened. It is a
  statement of what may be done, kept where the projects are listed, not a guard on the
  wire.
  """
  def allowed_orgs(ctx) do
    allowed = Lib.allowed_orgs()
    read_only = Lib.read_only()

    for p <- Lib.projects(ctx.mtext), msg = verdict(p, allowed, read_only), msg != nil do
      msg
    end
    |> Enum.sort()
  end

  defp verdict(p, allowed, read_only) do
    writable? = p.org in allowed
    listed? = Map.has_key?(read_only, p.name)

    cond do
      writable? and listed? ->
        "#{p.name} is in #{p.org}, which is writable, and is also listed read-only; " <>
          "one of the two is wrong"

      not writable? and not listed? ->
        "#{p.name} is in #{p.org}, which this project may not write to, and " <>
          "is not listed read-only"

      true ->
        nil
    end
  end

  @doc """
  Every name on the writable list MUST resolve to a real GitHub account.

  The list decides what this project may change, and nothing checked its contents. The
  check that reads it only ever asks whether a *project's* organisation is on it, so a name
  with no project was an unverified string: six were added on an owner's word and a typo in
  any of them would have sat there until the day a project arrived from that organisation,
  and then failed as "may not write to", which is the wrong answer to the wrong question.

  A resolving name is all this asserts. It does not ask whether we may write there -- that
  is the owner's sentence and no API answers it -- only that the thing named exists, which
  is the half a machine can check.

  User or organisation, either is fine. `fire` is a user account and belongs on the list,
  so the name ALLOWED_ORGS is loose rather than wrong; what the entries have in common is
  being an owner whose repositories are ours, not being an organisation.
  """
  def owners_exist(ctx) do
    types =
      case ctx[:owners] do
        nil ->
          Lib.gh_many(Map.new(Lib.allowed_orgs(), fn o -> {o, ["users/#{o}", "--jq", ".type"]} end))

        injected ->
          Map.new(Lib.allowed_orgs(), fn o -> {o, Map.get(injected, o, "Organization")} end)
      end

    for owner <- Enum.sort(Lib.allowed_orgs()), blank?(types[owner]) do
      "#{owner} is on the writable list, and GitHub has no such user or organisation"
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Google's third-party licence policy.
  # https://opensource.google/documentation/reference/thirdparty/licenses
  #
  # Restricted taints and obliges disclosure. Forbidden cannot be used at all. A repository
  # with no licence is the worst case of the lot: default copyright reserves every right, so
  # nobody may redistribute it, and publishing it openly does not change that.
  @restricted MapSet.new(~w(
    GPL-1.0 GPL-2.0 GPL-3.0 LGPL-2.0 LGPL-2.1 LGPL-3.0 CC-BY-SA-4.0 CERN-OHL-S-2.0
  ))
  @forbidden MapSet.new(~w(
    AGPL-1.0 AGPL-3.0 SSPL-1.0 OSL-3.0 CPAL-1.0 EUPL-1.1 EUPL-1.2
    CC-BY-NC-4.0 CC-BY-NC-SA-4.0 CC-BY-NC-ND-4.0 Watcom-1.0 BUSL-1.1
  ))
  @unset MapSet.new(["", "NONE", "NOASSERTION", "null"])

  # The first line of the licences this policy cares about, which is what identifies them.
  # GitHub runs a classifier over the file; this reads the file. The answers agree on every
  # repository here, and reading beats asking once the file is already on disk.
  @first_lines %{
    "MIT License" => "MIT",
    "                                 Apache License" => "Apache-2.0",
    "Mozilla Public License Version 2.0" => "MPL-2.0",
    "                    GNU GENERAL PUBLIC LICENSE" => "GPL-2.0",
    "                    GNU AFFERO GENERAL PUBLIC LICENSE" => "AGPL-3.0",
    "BSD 2-Clause License" => "BSD-2-Clause",
    "BSD 3-Clause License" => "BSD-3-Clause"
  }

  @doc """
  Every repository this organisation owns MUST carry a usable licence.

  Checked against Google's third-party policy. A restricted licence taints what links it and
  obliges disclosure; a forbidden one cannot be shipped at all. No licence is worse than
  either.

  A checkout that is not on disk is skipped rather than fetched, because a check that
  quietly reaches the network to cover a missing checkout is two checks wearing one name.
  """
  def licences(ctx) do
    ws = Lib.workspace_root()

    for p <- Lib.ours(Lib.projects(ctx.mtext)),
        lic = licence_of(ctx, p.name, Path.join(ws, p.path)),
        lic != nil,
        msg = licence_verdict(p.name, lic),
        msg != nil do
      msg
    end
    |> Enum.sort()
  end

  defp licence_verdict(name, lic) do
    cond do
      MapSet.member?(@unset, lic) ->
        "#{name} has no licence; default copyright reserves every right"

      MapSet.member?(@forbidden, lic) ->
        "#{name} is #{lic}, which the policy forbids outright"

      MapSet.member?(@restricted, lic) ->
        "#{name} is #{lic}, restricted: it taints what links it"

      true ->
        nil
    end
  end

  defp licence_of(ctx, name, path) do
    case ctx[:licences] do
      nil -> read_licence(path)
      injected -> Map.get(injected, name, "MIT")
    end
  end

  defp read_licence(path) do
    ~w(LICENSE LICENSE.md LICENSE.txt COPYING)
    |> Enum.map(&Path.join(path, &1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        if File.dir?(path), do: "NONE", else: nil

      file ->
        first =
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.find(fn l -> String.trim(l) != "" end)
          |> Kernel.||("")
          |> String.trim_trailing()

        Map.get(@first_lines, first, "UNRECOGNISED: #{String.slice(first, 0, 40)}")
    end
  end

  @doc """
  Every repository this organisation owns MUST carry a `CITATION.cff` that says what it is
  made of.

  `CLAUDE.md` has required this since the `meta` conversion and nothing enforced it, which is
  the shape of rule this repository already calls a suggestion: a claim no command can falsify
  does not defend itself. Fourteen repositories carried one and the rest did not, which made
  the file read as a habit of the Lean workspaces rather than as a rule.

  Two things are asked, because presence alone is the weaker half. The file must parse far
  enough to find a `title`, and it must carry a `references:` key -- provenance is the reason
  the file exists, and a `CITATION.cff` with no references is the one that reads as current
  while saying nothing. A repository genuinely built on nothing states `references: []` and
  says so on purpose.

  The boundary is authority, not authorship. A fork this organisation maintains is inside it:
  its README belongs to its upstream and its `CITATION.cff` does not, because the file states
  what *this* copy is made of and this copy is the one with a branch nobody upstream has. A
  read-only entry, on another organisation's remote, is outside it. A child that is not cloned
  is skipped rather than fetched.
  """
  def citations(ctx) do
    case ctx[:citations] do
      nil -> scan_citations(ctx)
      injected -> for {name, why} <- injected, do: citation_message(name, why)
    end
  end

  defp scan_citations(ctx) do
    findings =
      for {name, dir} <- ours(ctx), File.dir?(dir), why = citation_fault(dir), why != nil do
        citation_message(name, why)
      end

    Enum.sort(findings)
  end

  defp citation_fault(dir) do
    file = Path.join(dir, "CITATION.cff")

    cond do
      not File.exists?(file) -> :missing
      true -> citation_content_fault(File.read!(file))
    end
  end

  defp citation_content_fault(text) do
    cond do
      not Regex.match?(~r/^title:/m, text) -> :no_title
      not Regex.match?(~r/^references:/m, text) -> :no_references
      true -> nil
    end
  end

  defp citation_message(name, :missing),
    do: "#{name} carries no CITATION.cff, so what it is built on is stated nowhere checkable"

  defp citation_message(name, :no_title),
    do: "#{name}'s CITATION.cff has no title:, so it does not say what it is"

  defp citation_message(name, :no_references),
    do:
      "#{name}'s CITATION.cff has no references:, which is the half that says what it is " <>
        "made of; a repository built on nothing states references: [] and means it"

  # The boundary the licence, citation and .DS_Store checks share: what this organisation may
  # write to, less the read-only entries, and this repository itself.
  #
  # It does NOT subtract the mirrors, and that is the correction. Authority and authorship are
  # two questions and this list had been answering both with one answer. A fork sitting in our
  # own organisation is ours to write to -- we push builds to it -- while its README stays its
  # upstream's. Excusing it from the licence and CITATION.cff gates as well confused "we did
  # not write the prose" with "we may not add a file", and left the repositories whose
  # provenance most needs stating as the only ones never asked for it.
  #
  # So there are three categories rather than two, and `Lib.mirrors/0` documents them:
  # ours outright, a fork we maintain whose README is upstream's, and another organisation's.
  # Only the third is out of reach here.
  defp ours(ctx) do
    allowed = Lib.allowed_orgs()
    read_only = Lib.read_only()
    ws = Lib.workspace_root()

    # Two repositories that `default.xml` does not list as projects: the manifest, which repo
    # checks out to `.repo/manifests` and which a self-entry may not name, and this one, which
    # is listed but whose checkout is right here and needs no join. Both are ours, so both owe
    # a licence and a CITATION.cff, and naming only the manifest left this one unasked.
    # Deduplicated by name, because this repository is named twice: once explicitly above and
    # once by the manifest, which lists it like any other project. Every finding against it
    # was therefore reported twice, which reads as two problems and is one.
    ([{"fabric", Lib.manifest_root()}, {"infrastructure-logbook", Lib.root()}] ++
       for p <- Lib.projects(ctx.mtext),
           p.org in allowed,
           not Map.has_key?(read_only, p.name) do
         {p.name, Path.join(ws, p.path)}
       end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc """
  No .DS_Store in a repository this project may write to.

  Finder writes one into every directory it is asked to display, so the file arrives without
  anybody deciding it should. It records icon positions on one machine and means nothing on
  any other, which makes it exactly the thing the rest of these checks exist to remove.

  The gate is presence in the checkout rather than whether git tracks it. Ignoring a file
  hides it -- `git status` says nothing about a file it was told to ignore -- so tracking is
  the one reading that cannot tell a clean repository from a quiet one.

  Authority is the boundary, and it is the same one the length and listing rules stop at. A
  stray file inside somebody else's repository is theirs, and deleting it here writes a diff
  we would then carry.
  """
  def no_ds_store(ctx) do
    case ctx[:dsstore] do
      nil ->
        scan_ds_store(ctx)

      injected ->
        for {name, loc} <- injected do
          "#{name} carries #{loc}, which Finder wrote and nothing reads"
        end
    end
  end

  defp scan_ds_store(ctx) do
    # This repository is the one we have most authority over, so `ours/1` includes it and it
    # is checked beside the projects rather than trusted.
    for {name, dir} <- ours(ctx), File.dir?(dir), rel <- ds_stores(dir) do
      "#{name} carries #{rel}, which Finder wrote and nothing reads"
    end
    |> Enum.sort()
  end

  # `find` rather than a hand-rolled walk: it is already installed, it does not follow the
  # .git symlink repo leaves in every checkout, and a tree with mbedtls vendored into it is
  # 3845 files that nothing here needs to read.
  defp ds_stores(dir) do
    case Lib.cmd("find", [dir, "-name", ".DS_Store", "-not", "-path", "*/.git/*"]) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.relative_to(&1, dir))

      _ ->
        []
    end
  end
end

