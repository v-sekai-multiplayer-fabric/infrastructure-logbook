# The workspace this repository defines: where clones land, and whether this repository can
# tell them apart from its own files.
#
#     mix check workspace

defmodule Check.Workspace do
  alias Check.Lib

  def checks do
    [
      %{
        label: "every project directory is gitignored",
        kind: :local,
        run: &gitignore_covers_projects/1,
        # The checkout directory is `path`, so the edit that breaks this check moves the
        # clone out of an ignored directory. Editing the name instead leaves `path` ignored
        # and the check passes, which makes the control certify nothing.
        break: &Lib.break_manifest(&1, ~s(path="2-contract/triangulation"), ~s(path="not-ignored-xyz"))
      }
    ]
  end

  @doc """
  Every child dir must be ignored, or a clone shows up as untracked in this repo.

  The checkout directory is `path` where a project states one, so this asks about the
  directory a clone lands in rather than the name it has on the remote. The two differ for
  every project that sits on a side of the hexagon.
  """
  def gitignore_covers_projects(ctx) do
    # The manifest repository's `.gitignore` is the one asked, because it is the one that
    # ships beside `default.xml`: a plain clone of it is the workspace root, and its patterns
    # are what decide whether a sibling clone shows up as untracked. `git check-ignore` needs
    # no file on disk, so this reads the patterns rather than the layout.
    root = Lib.manifest_root()

    for p <- Lib.projects(ctx.mtext), not ignored?(root, p.path) do
      "#{p.path} is not gitignored"
    end
  end

  defp ignored?(root, path) do
    {_out, status} = Lib.cmd("git", ["check-ignore", "-q", path <> "/"], cd: root)
    status == 0
  end
end

