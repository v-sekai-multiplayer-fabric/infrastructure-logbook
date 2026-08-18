# The vocabulary RFD 0111 decided, held against every document in the children.
#
# This concern scans files in the children rather than text passed in, so a breakage that
# edits the manifest or the README cannot reach it. Its control injects a defective document
# instead, which is what makes the control real.
#
#     mix check words

defmodule Check.Words do
  alias Check.Lib

  def checks do
    [
      %{
        label: "no document uses a word RFD 0111 retired",
        kind: :local,
        run: &retired_words/1,
        break:
          &Map.put(&1, :docs, [
            {"1-transport/fanout", "README.md", "An edge plane is a plane with networking.\n"}
          ])
      }
    ]
  end

  # Only the compounds RFD 0111 names. "Control plane" and "data plane" survive it, because
  # they name a class of traffic rather than a process, so a document using either is not a
  # finding.
  @retired [
    {~r/\bedge planes?\b/i, "edge plane -> transport layer"},
    {~r/\bstore planes?\b/i, "store plane -> data source"},
    {~r/\bplane rules?\b/i, "plane rule -> interactor rule"}
  ]

  @doc "RFD 0111 retired plane, edge plane, and domain as nouns for a process."
  def retired_words(ctx) do
    projects = Lib.projects(ctx.mtext)

    for {path, name, text} <- Lib.child_docs(ctx, projects),
        {line, n} <- Enum.with_index(String.split(text, "\n"), 1),
        {pattern, fix} <- @retired,
        Regex.match?(pattern, line) do
      "#{path}/#{name}:#{n} #{fix}"
    end
  end
end

