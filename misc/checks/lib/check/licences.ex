# What a vendored tree must say about itself.
#
# The root LICENSE of a repository speaks for the code that repository wrote. It does not speak
# for code taken from somewhere else, and a tree that says nothing is read as if it did.
#
#     mix check licences

defmodule Check.Licences do
  alias Check.Lib

  def checks do
    [
      %{
        label: "every vendored tree states its own licence",
        kind: :local,
        run: &vendored_trees_are_licensed/1,
        # Reads the children's trees, which no edit here reaches, so the control supplies the
        # reading rather than editing a file -- the same shape Check.Authority's .DS_Store
        # control uses, and for the same reason.
        break: &Map.put(&1, :licences, [{"interactor-somewhere", "thirdparty/borrowed"}])
      }
    ]
  end

  @vendor_dirs ~w(thirdparty third_party vendor)

  # A file whose name is the licence. Checked first because it is the cheapest answer and the
  # conventional one; REUSE's LICENSES/ directory counts here too.
  @licence_names ~w(LICENSE LICENSE.txt LICENSE.md LICENCE LICENCE.txt COPYING COPYING.txt
                    NOTICE LICENSES LICENSE-MIT LICENSE-APACHE UNLICENSE)

  # A licence stated inside a file rather than beside it. Single-header libraries do this and
  # nothing else, which is the case that made the window matter: `r128.h` carries a public-domain
  # dedication at line 35, and a scan that read only the head of the file called it unlicensed.
  # The whole file is read.
  @licence_marker ~r/SPDX-License-Identifier|mozilla\.org\/MPL|Mozilla Public License|MIT License|Apache License|BSD|GNU General Public|released into the public domain|Unlicense|Boost Software License|Copyright \(c\)|Copyright \d{4}/i

  @readable ~w(.h .hpp .hh .c .cc .cpp .cxx .md .txt .patch .py .ex .exs .lean .rs .go .cmake)

  @doc """
  Every vendored tree in a repository we are the primary source for states its licence.

  Vendoring is how this workspace takes code it did not write, and the terms travel with the
  code rather than with the repository around it. A tree that states nothing is read as being
  under the root `LICENSE`, which is a claim nobody made and which is wrong wherever the two
  differ.

  `interactor-triangulation` is the case this was written from. Its root `LICENSE` is MIT and
  most of `src/` was the DMWT implementation of Zou et al., MPL-2.0, with no notice anywhere in
  the tree -- so the whole checkout read as MIT for as long as it existed. Nothing in the
  repository was lying; nothing in it said the true thing either. `libs/CMakeLists.txt` had
  been excluding geogram components "whose license is incompatible with MPL2" the entire time,
  so the build was already being shaped by a licence that no file declared.

  Three things are accepted, because the question is whether the terms are stated and not how:
  a licence file in the tree, a `LICENSES/` directory in the repository (REUSE states it that
  way), or a licence named inside any file in the tree. A single-header library carries its own
  terms and needs no file beside it.

  The boundary is authorship, not authority, and it is narrower than the CITATION.cff gate's on
  purpose. A mirror's vendored trees are its upstream's, and adding notices to them would fork a
  licence statement this project does not own -- `entities-godot` alone carries about ninety of
  them. `Lib.mirrors/0` names the three that are skipped.
  """
  def vendored_trees_are_licensed(ctx) do
    case ctx[:licences] do
      nil -> ctx |> scan() |> Enum.map(&message/1)
      injected -> Enum.map(injected, &message/1)
    end
  end

  defp scan(ctx) do
    ws = Lib.workspace_root()
    mirrors = Lib.mirrors()

    projects =
      Lib.projects(ctx.mtext)
      |> Lib.ours()
      |> Enum.reject(&Map.has_key?(mirrors, &1.name))

    trees =
      for p <- projects,
          dir = Path.join(ws, p.path),
          File.dir?(dir),
          v <- @vendor_dirs,
          File.dir?(Path.join(dir, v)),
          tree <- File.ls!(Path.join(dir, v)) |> Enum.sort(),
          full = Path.join([dir, v, tree]),
          File.dir?(full),
          do: {p.name, dir, "#{v}/#{tree}", full}

    case length(trees) do
      0 -> IO.puts("note   the licence check found 0 vendored trees; nothing here was examined")
      n -> IO.puts("note   the licence check read #{n} vendored trees")
    end

    for {name, repo, rel, full} <- trees, not licensed?(repo, full), do: {name, rel}
  end

  defp licensed?(repo, tree) do
    Enum.any?(@licence_names, &File.exists?(Path.join(tree, &1))) or
      File.dir?(Path.join(repo, "LICENSES")) or
      stated_inside?(tree)
  end

  defp stated_inside?(tree) do
    Path.wildcard(Path.join(tree, "**/*"))
    |> Stream.filter(&(Path.extname(&1) in @readable and File.regular?(&1)))
    |> Enum.any?(fn f ->
      case File.read(f) do
        {:ok, text} -> String.valid?(text) and Regex.match?(@licence_marker, text)
        {:error, _} -> false
      end
    end)
  end

  defp message({name, rel}),
    do:
      "#{name}/#{rel} states no licence; vendored code carries its own terms, and a tree that " <>
        "says nothing is read as being under the root LICENSE, which is a claim nobody made"
end
