# The manifest's own shape: what every project must state, what nothing may inherit, and
# what a path must rebuild. Every check here reads default.xml and nothing else, so this is
# the one concern that answers without a checkout, a network, or a ledger.
#
#     mix check manifest

defmodule Check.Manifest do
  alias Check.Lib

  def checks do
    [
      %{
        label: "every project states remote and revision",
        kind: :local,
        run: &explicit_attrs/1,
        break: &Lib.break_manifest(&1, ~s( remote="meshula" revision="dev"), "")
      },
      %{
        label: "<default> sets sync-j so fetches are not serial",
        kind: :local,
        run: &sync_j/1,
        break: &Lib.break_manifest(&1, ~s(<default sync-j="16" />), "<default />")
      },
      %{
        label: "no project checks this repository out twice",
        kind: :local,
        run: &no_self_checkout/1,
        # Re-adding the self-entry is the defect, so the control adds one.
        break:
          &Lib.break_manifest(
            &1,
            ~s(<project name="transport-asset"),
            ~s(<project name="fabric" path="." remote="v-sekai-multiplayer-fabric" revision="main" />\n  <project name="transport-asset")
          )
      },
      %{
        label: "every path recomposes to its repository name",
        kind: :local,
        run: &path_recomposes/1,
        # Moving a project to a directory its name does not rebuild is exactly the drift
        # this gate exists to catch.
        break: &Lib.break_manifest(&1, ~s(path="4-entities/images"), ~s(path="4-entities/pictures"))
      }
    ]
  end

  @doc """
  Every project states its own remote and revision, and `<default>` states neither.

  A value left out is not absent, it is decided somewhere else. Writing the obvious ones is
  the whole point: if only the unusual entries carry a branch, a reader cannot tell a
  deliberate choice from an inherited accident.
  """
  def explicit_attrs(ctx) do
    {default, _remotes, projects} = Lib.parse_manifest(ctx.mtext)

    missing =
      for p <- projects, key <- [:remote, :revision], is_nil(Map.get(p, key)) do
        "project #{p.name} missing #{key}"
      end

    inherited =
      case default do
        nil ->
          []

        d ->
          for key <- [:remote, :revision], Map.get(d, key) do
            "<default> carries #{key}; it must inherit nothing"
          end
      end

    missing ++ inherited
  end

  @doc "Without sync-j, repo fetches serially (jobs_network=1)."
  def sync_j(ctx) do
    case Lib.parse_manifest(ctx.mtext) do
      {nil, _, _} ->
        ["<default> has no sync-j; without it repo fetches serially (jobs_network=1)"]

      {%{sync_j: nil}, _, _} ->
        ["<default> has no sync-j; without it repo fetches serially (jobs_network=1)"]

      _ ->
        []
    end
  end

  @doc """
  No project may take `path="."`, because it gives repo two copies of this repository.

  This check previously required the opposite, and was wrong. `repo init` already clones
  this repository to `.repo/manifests` and reads the manifest from there, so a self-entry
  produces a second working copy at the workspace root: edits to `./default.xml` are
  invisible to repo, which never reads that file, and `repo sync` treats the root as a
  project and checks the manifest revision out over whatever is there.

  Both halves fired. A manifest rewrite at the root changed nothing, and the next sync
  discarded it along with an uncommitted README and reset HEAD, leaving a committed but
  unpushed CITATION.cff reachable only from the reflog.

  So the rule is one working copy of this repository, and it is the one repo reads.
  """
  def no_self_checkout(ctx) do
    for p <- Lib.projects(ctx.mtext), p.path == "." do
      ~s(#{p.name} takes path=".", which gives repo a second working copy of this ) <>
        "repository at the workspace root; edits there are ignored and then overwritten"
    end
  end

  @doc """
  A directory and its child MUST recompose to the repository name.

  `1-transport/gateway-c` is `transport-gateway-c`, and the leading digit sorts the ring
  rather than naming anything. This is what stops the checkout drifting from the names
  RFD 0111 decided: a path that no longer rebuilds its own name means one of the two moved
  without the other.

  The exceptions are in `fixed_names/0`, and each is a fact rather than a taste: that name
  belongs to another organisation, so no rename here can make the path rebuild it.
  """
  def path_recomposes(ctx) do
    fixed = Lib.fixed_names()

    for p <- Lib.projects(ctx.mtext),
        not Map.has_key?(fixed, p.name),
        rebuilt = rebuild(p.path),
        rebuilt != p.name do
      "#{p.path} rebuilds to #{rebuilt}, but the repository is #{p.name}"
    end
  end

  defp rebuild(path) do
    case String.split(path, "/", parts: 2) do
      [dir, child] -> String.replace(dir, ~r/^\d-/, "") <> "-" <> child
      [only] -> only
    end
  end
end

