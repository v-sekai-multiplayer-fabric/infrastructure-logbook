# infrastructure-logbook

Conventions for every project in this workspace. A `CLAUDE.md` in a parent directory loads for
the directories under it, and this repository sits two levels down at `0-infrastructure/logbook`,
so a reader inside a sibling checkout does not get it by proximity — it is the record every
project here works to, and it is loaded because it is named, not because it is above. A
repository's own `CLAUDE.md` says what that repository is; this says how work is done across all
of them.

This file used to sit in the manifest repository, beside `default.xml`. It does not any more.
A manifest is read by a tool on every sync and a record is rewritten as the work moves, and one
repository doing both meant every entry here was a commit against the manifest. `fabric` now
holds `default.xml` and nothing else; everything else it carried is here.

## The manifest

- `default.xml` MUST state every value it depends on, including the ones that are obvious and
  the ones a tool would default for you. Today that is two: `remote` and `revision`, on every
  project, never inherited from `<default>`.

A value left out is not absent, it is decided somewhere else. An entry with no revision clones
whatever the remote's HEAD happens to be, which the manifest does not record and the remote can
change on its own, so two checkouts made a month apart can differ with nothing here to compare.

Writing the obvious ones is the whole point. If only the unusual entries carry a revision, a
missing one means "the default, probably" and a present one means "look closer", and neither is
checkable. Two of the fifty-three are already not what a reader would guess —
`entities-godot` tracks `gyre` while its own default is `master`, and `contract-http3-queue`
defaults to `master` unlike every other `lean-*`. Stating all of them makes those two ordinary
lines rather than discoveries, and makes the next one visible in a diff.

The rule outlived the file it was written for. It was `.meta`, mateodelnorte's format, where a
per-repo branch rode inside the URL string as a `git clone` flag — a field nobody could see,
which is the defect the conversion to `default.xml` was for. The rule transferred unchanged
because it was never about the format.

## Where the manifest is

`repo init` clones `fabric` to `.repo/manifests` and reads the manifest from there, so that is
the one working copy and edits go in that checkout. This repository finds it by looking for
`.repo` above itself, the way any project on a side would; `FABRIC_MANIFEST` overrides that for
a bare clone with no workspace around it, which is what CI is.

A `path="."` entry is refused, and `Check.Manifest.no_self_checkout/1` is the gate. It gave repo
a second working copy of the manifest at the workspace root: edits to `./default.xml` were
invisible to the tool that never reads that file, and the next `repo sync` checked the manifest
revision out over whatever was there. Both halves fired, and it cost an uncommitted README and a
committed but unpushed `CITATION.cff` reachable only from the reflog.

## Commits

- Commit style: sentence case. Do not use a `type(scope):` prefix.
- Split a branch by concern, not by the order the work happened in. A commit is one idea and
  the whole of it: if a later commit fixes what an earlier one broke, they were one commit.
- A split is not free, and the cost is CI. Every commit must pass on its own, so a branch of
  `n` commits is `n` verifications rather than one, paid again on every push while it lives.
  Most branches are one idea: squash them locally with `git rebase -i` before marking the
  pull request ready, and keep a split only where the concerns are independent enough that
  reading them one at a time is worth what it costs to verify them one at a time.
- Every commit MUST pass CI on its own, not only the last one. This decides some splits for
  you rather than leaving them to taste — a constant and the CI numbers derived from it cannot
  be separated, because neither half passes alone.

A branch split the way the work happened reads as a diary and reviews as one. The reader cannot
tell which commit is the idea and which is the repair, and bisect lands on commits that never
worked.

## Pull requests

- Open a pull request as a **draft** while anything about it is still in flight: a commit not
  pushed, a check not run, a number not yet checked.
- Mark it **ready for review** only when the branch is complete and its checks are green. Ready
  means ready to merge, and nothing else says so.
- A draft cannot be merged by accident, which is the whole point. Ready is a claim, so do not
  make it early and then keep pushing.

The state is the signal because nothing else is. A branch that looks finished and a branch that
is finished are the same branch to a reader, and a pull request whose commits are still arriving
will be merged without them — the merge takes what is there at that moment, not what the author
meant to include. Two commits in this workspace have already been lost that way: a proof merged
without the theorem it was written for, and a rewrite merged before it was rewritten. Neither
review could have caught it, because in both cases what was on screen was correct and what was
missing had not been pushed yet.

After a merge, check that the work reached the target branch rather than that it was pushed.
`git diff <branch-tip> origin/main` should be empty: the tree is the thing that had to
arrive, and comparing trees answers that whatever the merge did to the commits.

Do not use `git log origin/main..<branch>` for this. It asks whether the commit is an
ancestor, which a rewritten tip always makes false -- a squash or a rebase merge gives the
merge a new SHA, so the branch tip is unreachable from main even when every byte landed. It
cried wolf on #50, #52 and #53 in one day, each time on a merge that was complete. A check
that is red on every correct merge is one nobody reads by the fourth time, which is the
failure it was written to prevent.

RFD 0021 now disables squash and rebase merging here, so a tip stops being rewritten and
reachability starts holding again. The tree comparison stays the check anyway: history
already holds the squashed merges above, and a check indifferent to how a merge was made
keeps working if somebody turns a setting back on.

`gh pr view --json commits` still says what the merge took, and it is the number to trust
for which commits were included.

## Citation

- Every repository MUST carry a `CITATION.cff`, and its `references:` MUST name what the
  repository is built on: the designs it implements, the code it clones or vendors, and the
  repositories its constants are read from.
- Add the reference in the same commit that adds the dependency. A `CITATION.cff` written once
  and never touched again is a worse claim than none, because it reads as current.

Fourteen repositories here already have one and the rest do not, which makes the file look like a
habit of the `lean-*` hexagons rather than a rule. It is a rule, and the reason is what the
manifest's reason is: a value left out is not absent, it is recorded somewhere else. Provenance
stated only in prose is stated once, in whichever paragraph happened to need it, and a reader
asking "what is this made of" has to read the whole `README.md` and trust that nothing was
dropped. `interactor-ward` is the case that makes it plain — a clone of one repository,
vendoring a second and a third, implementing somebody else's published design, against numbers
proved in four Lean hexagons. None of that is visible in a dependency file, because there is no
dependency file that could hold a journal article.

## Where a thing is built and run

- Build and test **locally** by default. Reach for CI when the work overflows what this machine
  has — cores, wall clock, memory, disk, or the platforms it is not — and then let the cloud
  scale it out.
- Do NOT push a branch so that CI will compile it for you when the machine in front of you can.
  CI is the overflow, not the first attempt.
- Cap a long compile so the machine stays usable. `-j4` for a Godot build here, not `-j16`: the
  desk is also what the headset is plugged into and what a test client runs on.

Local is cheaper for a reason that has nothing to do with who pays for the runner. A local build
is **incremental** and a CI build is always cold. The Godot editor build in `entities-godot`
is the case that shows it: an interrupted run left 2389 objects and a 19 MB `.sconsign5.dblite`,
so resuming cost minutes where CI would have started from nothing on every push. The second run
of anything is where local wins, and there is always a second run.

The feedback loop is the other half. A failure on this machine is a file and a line, now, with
the tree still in the state that produced it. The same failure in CI is a log to download, a
tree you cannot poke at, and a queue between every attempt — so a two-line fix costs a
round-trip instead of a rebuild.

And some things simply cannot go to CI. `contract-wt` drives the transport against a
Godot server on loopback, and `bench_players` measures a pinned core; a shared runner whose
neighbour is busy is not a core worth recording. That is why `bench_players` reports the budget
and only asserts it under `--gate`.

CI earns its keep where the machine runs out: the platforms this desk is not (Linux, macOS,
Android, web), the matrix that would take all afternoon serially, and the check that the branch
builds somewhere other than where it was written. `entities-godot`'s `runner.yml` triggers on
any push to any branch, so that is available the moment it is wanted — after the local run, not
instead of it.

### Driving Godot locally

`transport-godot-mcp` is the local harness for anything Godot, and it is available here rather
than being something to build each time. Vendor it into a project as
`addons/vsekai_godot_mcp` from the repository's `addon-root` branch — Godot only scans
`res://addons/*/plugin.cfg`, so the whole repository subtreed puts it one level too deep and
the editor never finds it.

Both halves run at once, on purpose:

- the **editor plugin** on `127.0.0.1:8788` — the scene as edited, `play_main`, `stop`
- **`MCPRuntime`**, autoloaded into the running game, on `8789` — the scene as it actually is

Two ports because pressing play in an open editor is the ordinary case. When they shared 8788
the game lost the bind, printed `listen failed`, and a client went on questioning the editor
while believing it had reached the game — wrong answers rather than an error. `--mcp-port=` or
`GODOT_MCP_PORT` moves the runtime one.

**Ask the running game, not the editor, when the question is what arrived.** A node's real
transform is the difference between "the packet decoded" and "the object is where the service
put it", and nothing above the socket can tell you the second. The editor answers what the
scene was authored as, which is a different question and often the wrong one.

`claude mcp add --scope project --transport http godot http://127.0.0.1:8788/mcp` registers it,
and `.mcp.json` here already carries that entry.

Two things it will not do. `screenshot` captures the **editor viewport**, not the running game's
window, so it is evidence about the editor and nothing else. And driving the runtime bridge hard
has killed it mid-session — the editor's survived, the game's stopped answering — so a bridge
that goes quiet is a restart rather than a finding about the code under test.

## Checks

- A check MUST **fail the build**. A check that prints and returns zero is not a check, it is
  a log line, and nobody reads the log of a build that passed.
- Assert the **defining property**, not a consequence of it. Ask what would still be true if
  the thing were replaced by something wrong, and test whatever answers no.
- A gate MUST be shown to fail. Break the thing on purpose, watch the build go red, put it
  back. A gate never seen failing is a gate nobody has evidence works.
- Assert the property **where it is consumed**, not only where it is defined. A dependency's
  own tests do not run in your build.
- When the thing under test changes, the gate changes with it. A gate carried across a
  replacement becomes a test that only passes for what was removed.

All five of these were learned in one day, from one bug, and every one of them was already
nominally covered by something that passed.

`Shared.hilbert3D` was not a Hilbert curve. Walking the codes in order, 87.5% of consecutive
pairs were not adjacent cells -- worse locality than the Morton it was chosen over, at five
times the cost. It survived because everything being checked passed: it was a clean bijection,
it round-tripped, `hilbert_of_aabb` carried a `CRASH_COND` round-trip witness that fired on
every call and never once failed, and the docstring cited a paper. None of that distinguishes a
Hilbert curve from any other bijection. The defining property was asserted nowhere, so it was
wrong in five copies at once and in two languages.

**The consequence is not the property.** A round trip closing proves the pair are inverses; it
says nothing about which curve they are. A bijection proves no collisions; it says nothing about
locality. Both are worth asserting and neither is the thing.

`PredictiveBVH::insert` passed a space-filling code of `0u` for every node. The tree's whole
design is to radix-sort by that code, so it sorted a constant and fell back to insertion order.
It returned correct results throughout, which is why it went unnoticed -- the defect was in
ordering quality, and nothing asserted the codes were ever distinct.

**A check that reports is worse than no check**, because it reads as coverage. `CodeGen.lean`
verified its forward and inverse round-tripped at build time. When the forward moved upstream
and the inverse did not, it found the mismatch, printed `HILBERT INVERSE: 7 FAILURES`, and
exited zero. The build was green with a broken pair in it. It now throws.

**Where the check runs is part of the check.** `entities-lean-shared` gates its curve correctly and
that gate did its job -- and it runs nowhere near the failure it needed to catch, because
`lake-manifest.json` pins by rev. An upstream fix merged, the pin did not move, and the
consumer sat on the old code with nothing to notice. Assert the contract against whatever is
actually pinned; `PredictiveBvh.core.CurveContract` is the pattern.

**Verify the gate by breaking the thing.** Every gate written that day was confirmed by staling
the manifest, rebuilding, and watching it go red before being put back. Two readings during that
were confidently wrong from stale `.olean` files pointing in opposite directions, so force the
rebuild before believing any result -- including a result you like.

And when the curve was replaced, its contiguity gate had to be deleted rather than kept: Morton
fails it by design. A gate that outlives what it was written for is a test that passes only for
the thing you removed, which is where this started.

## Documentation is antifragile

The rules above are about code. Prose needs them more, because prose has no compiler and no
test suite, and a README that is wrong looks exactly like a README that is right.

Robust documentation survives being wrong. Antifragile documentation gets **stronger** every
time it is wrong, because each error is converted into a check before the fix ships.

- **One source of truth per fact, and it is not the prose.** `default.xml` says what the fleet
  is; the README describes it. Where the two disagree the manifest wins and the prose is the
  bug. The `misc/checks` mix application derives every documented count, name, and branch from the manifest.
- **Every claim is executable or it is decoration.** Counts, tables, branch names, and sizes
  are checked by a command that exits non-zero. A claim no command can falsify does not belong
  in the document. This is the `Checks` rule above, applied to sentences.
- **A found error becomes a check, not just an edit.** Correcting the text is half the fix; the
  other half is the assertion that would have caught it, in the same change. That is the whole
  mechanism -- stress adds checks, so the harness is strongest exactly where documentation has
  failed before.
- **The doc gate ships with a negative control.** `mix check --self-test` breaks each claim
  on purpose and requires the matching check to fail. A gate never seen failing is a gate
  nobody has evidence works, and that applies to a README gate as much as to a build gate.
- **Never hedge to survive.** "Roughly", "should be", and "approximately" on a knowable number
  are ways to make a claim unfalsifiable so the gate cannot fail it. State the number and let
  the gate defend it; where a value is genuinely a range, state the range and check the bound.
- **Prefer generated to maintained.** A table a script can emit from the artefact should be
  emitted, not typed.

This was learned converting this manifest off `meta`. Three defects, each invisible to review:
the per-repo branches existed only as a `git clone` flag smuggled inside a URL string, so a
field nobody could see carried `gyre`, `main-fabric`, `dev`, and two `master`s; the first
`default.xml` would not parse at all, because a flag quoted in an XML comment contains `--`;
and the first doc gate silently matched nothing, because the claim it looked for had wrapped
across two lines. The first was found by conversion, the second by running the tool, the third
by a control that reported its own pattern had gone dead. Only the third one found itself.

### A README is under forty lines

- Every `README.md` in a repository this project is the **primary source** for MUST be
  under 40 lines. `mix check --fast` gates it, offline, at commit stage.
- A **mirror** is exempt. Its README belongs to its upstream, and editing it forks a
  document this project does not own. `MIRRORS` in that script names each one and the
  evidence: `entities-godot` opens "# Godot Engine", `datasource-foundationdb` and `idtx-flow`
  carry GitHub's fork flag. Owning the Windows builds of FoundationDB is not owning
  its code, so its README is not ours to cut.
- Repositories on another organisation's remote are out of scope. The convention
  reaches what this organisation is the source of, and nothing else.
- When a README is over, move the content rather than deleting it. A design goes to an
  RFD, a convention goes here, and a measurement goes to the file that produced it.

Forty lines is about one screen. Past that a README stops being read from the top, and
the part nobody reads is the part that goes stale with nobody noticing — which is the
failure the rest of this section exists to prevent. A short README also has nowhere to
hide a duplicate: `contract-bus` states that a decision written twice drifts and the
stale copy still reads as authoritative, and ten or more READMEs in this workspace
repeated the `Weft` moduledoc's definitions until RFD 0111 pulled them out.

The limit is a forcing function rather than a style preference. It is checked because
an uncheckable rule about prose is a suggestion, and this file already says a check
that prints and returns zero is a log line. The gate ships with its negative control,
which pads the README past the limit and requires the check to go red.

This repository's own README was 91 lines when the rule was written and is 39 now. The
`Use` and `Why not meta` sections went to git history, and the layout it described in
prose now lives in the `default.xml` comment that decides it — one source per fact.

### A found defect becomes a check

Six READMEs were cut by hand before this rule was written down, and the same four defects
turned up in every one: a title naming the repository's old name, a word RFD 0111 retired,
a repository named by a name that now only answers on a GitHub redirect, and a path or line
that had moved. Each was found by reading, fixed once, and left free to reappear in the next
repository. That is the loop this section exists to end.

- A defect found in a document MUST leave behind a check that would have caught it, in the
  same change. Correcting the text is half the fix.
- The check MUST run over every repository this organisation is the primary source of, from
  one place. Nine gates in nine repositories is nine things to keep in step.
- A check that reads a child's files cannot be broken by editing this repository, so its
  negative control MUST inject a defective document instead. `DOC_OVERRIDE` in
  The context each check is handed is that seam, and without it those controls would pass while proving
  nothing.
- A check that finds nothing because it looked at nothing MUST say so. The document checks
  print how many children they scanned, because zero reads exactly like clean.

The redirect check is the one worth copying elsewhere. GitHub answers every old name
forever, so a rename leaves prose that resolves, is wrong, and fails nowhere. RFD 0111 asks
for the pins in the same pass as the rename; asking is not a mechanism, and this is.

## Taking inventory

A workspace of forty-two repositories loses work on disk, not in review. Before changing
lanes, after any long task, and before saying what is left to do, take stock — from the
repositories, never from memory.

```sh
cd P:/fabric
for d in */ */*/; do d=${d%/}; [ -d "$d/.git" ] || continue
  ( cd "$d"
    u=$(git status --porcelain | grep -c '^??')
    m=$(git status --porcelain | grep -vc '^??')
    b=$(git branch --show-current)
    up=$(git rev-parse --verify -q "origin/$b" >/dev/null 2>&1 || echo NO-UPSTREAM)
    ah=$(git rev-list --count "origin/$b..HEAD" 2>/dev/null || echo ?)
    [ "$u$m$ah" != "000" -o -n "$up" ] && printf '%-34s %-30s untracked=%-4s modified=%-4s ahead=%-4s %s\n' \
      "$d" "$b" "$u" "$m" "$ah" "$up" )
done
```

The glob reaches two levels because `default.xml` puts most children on a side of the hexagon,
one directory down. A one-level glob finds the eight projects at the root and reports the other
thirty-four as absent, which is the answer this command exists to prevent. The subshell around
the body keeps the return path correct from either depth.

Then separate the real from the noise, because most of what it prints is noise. A Windows
checkout of a repository with shell scripts in it reports a hundred files `modified` that are
`mode change 100755 => 100644` and zero insertions. `git diff --stat` tells them apart in one
line, and an inventory that does not do that buries three real items under three hundred.

**Rank by risk of loss, not by value.** In order:

1. **Untracked files.** They survive nothing — not a stash, not a branch switch, not a `clean`.
   An untracked file is the only state here with no copy anywhere.
2. **Committed but unpushed**, and branches with no upstream.
3. **Pushed but no pull request**, then open pull requests, then stacks waiting to merge.
4. Everything else, by value.

A thing that exists in one place is worth more attention than a thing that is merely important.

This is written down because it was learned twice in one day. Three files implementing an
interactor sat untracked for hours across two status reports that both claimed to say what was
outstanding. And a pull request was opened describing a test harness whose file had never been
pushed — the description was accurate about the work and wrong about the repository, which is
the failure a reviewer cannot catch.

## Ordering work: PERT and the critical path

Taking inventory says what is open. To decide what to do next, draw the dependency graph and
estimate each task three ways. Do NOT invent a value score and rank by it — a made-up number
divided by another made-up number produces arithmetic that looks objective and only launders
whatever order was already preferred.

**Estimate each task three ways**, because a single number hides how little is known:

    te = (o + 4m + p) / 6

optimistic, most likely, pessimistic. The spread is the useful part. A task estimated
`1h / 2h / 12h` is not a two-hour task, it is an unknown wearing one, and the honest response is
to shrink the pessimistic case first — usually by running the smallest thing that would tell you
which end of the range is real.

### Take the three points from git, not from a feeling

Guessed estimates are the same failure as a made-up score, one step further in. Derive them from
what this org has actually done: group each repository's commits into sessions, where a gap of
more than four hours means somebody went away rather than worked slowly, and take percentiles of
session length by size.

    git -C <repo> log --since=6.months --pretty=%ct --numstat

**Measured across every checkout here, 475 sessions over six months:**

| session size  |   n | o (p10) | m (p50) | p (p90) |          te |
| ------------- | --: | ------: | ------: | ------: | ----------: |
| 2–4 commits   | 220 |  0.02 h |  1.05 h |  3.91 h |  **1.35 h** |
| 5–9 commits   |  66 |  1.14 h |  3.86 h |  8.61 h |  **4.20 h** |
| 10–24 commits | 102 |  1.95 h |  8.14 h | 16.31 h |  **8.47 h** |
| 25+ commits   |  87 |  8.90 h | 14.68 h | 21.10 h | **14.79 h** |

Size a task by the commits it will take — which is a guess about _shape_, and a far easier one
than a guess about hours — and read the row.

Re-derive the table rather than trusting these numbers forever; they are this org, this year,
this way of working.

**Check that the evidence measures the thing.** Merged-PR cycle time was tried first and is
useless here: across 387 merged pull requests the median is **under six minutes**, because a
pull request is opened and merged by the same person in one motion. That measures how long a
review sits, and in a solo workflow the answer is zero. Commit cadence measures work; PR age
measures process. Picking the wrong one produces confident numbers about nothing.

**Expect the correction to be large and in one direction.** Estimates made by feel on this
workspace ran two to four times optimistic against the table — a "half hour" probe sits in the
2–4 commit row at `te` 1.35 h with a p90 near four hours. Optimism is the normal direction, so a
sanity check that only ever confirms the guess is not being run properly.

**Then find the critical path.** The longest chain of dependent tasks is the earliest the whole
thing can finish. Only two facts matter after that:

- Work **on** the path: every hour saved is an hour off the finish.
- Work **off** it has slack: it can be done late, in parallel, or by somebody else, and finishing
  it early buys nothing at all.

That is the whole ranking, and it comes from the graph rather than from a preference. A task can
be genuinely important and have slack — say so and let it wait, rather than promoting it because
it feels urgent.

**Dependencies must be checked, not assumed.** The cheapest thing an inventory does is delete an
edge. Comparing physics topologies against a counting sink turned out to need no transport at
all, so an entire transport lane left the critical path — visible only by reading what the
benchmark actually calls, not by thinking about what a networking comparison ought to need.

**Where the graph forks on an unknown, the probe that resolves it is on the critical path.** If
one branch of the plan depends on a property nothing has measured — determinism, a rate, a
limit — the measurement precedes both branches, because until it lands every downstream estimate
has a pessimistic case that includes "and then throw it away".

## Continuous delivery

Ordering work says what to do next. This says whether it happened, which is a different
question and the one that was never asked.

- **The unit is the SI second, and each project is its own book.** `ledger/spent/` holds
  one `.beancount` per project, included by `ledger/spent.beancount`, so a change to one
  project touches one file and its hours are auditable against `git log` on their own line
  — a lane total absorbed a dropped commit silently, and a per-project book did not. Each
  book's `open` directive carries that project's `CITATION.cff`, so it says what the work
  was and what may be done with it without opening the repository. Seconds because a git
  timestamp is in seconds: nothing in the file is a conversion anybody has to trust.
- The seconds are **booked**, in `ledger/spent/`, generated from git by
  `misc/scripts/ledger.py` and never typed. A session is a run of commits with no gap over
  four hours, and its cost is the span from its first commit to its last.
- **Gate on what is false now, not on what was not done.** A gate that fails because nobody
  worked on something is reporting an intention back to the person who had it, and an
  intention cannot be falsified — only missed. `check_deliverable_moved` did that and is
  gone. What replaced it are present-tense facts with files behind them: an oracle's
  recorded output is byte-identical to its own reference, so a differential over the pair
  cannot fail; and `CHANGELOG.md` forbids `@[extern]` while two Lean files declare one.
  Both are red today for reasons a reader can check in a minute, and both go green when the
  work is done rather than when enough seconds are booked.
- **A README does not list its own directories.** `ls` answers that correctly forever; a
  listing in prose answers it as of whenever somebody last looked, and nothing compares the
  two. Detection is grounded in the filesystem — a fence counts as a listing when two or
  more lines open with a token naming a directory that exists — and reads only unlanguaged
  fences, because `cmake -S . -B build` in a `sh` block tripped it against the `cmake/`
  directory before the language was read.
- The **plan lives in the ledger too**, in `ledger/planned.beancount`: a task is a
  transaction, its three points are metadata, and `ledger.py path` computes the critical
  path from the dependencies rather than from a picture somebody drew.
- **Hypothetical and spent never mix, and the tool is what stops them.** Planned work is
  a liability in `PLANNED-SECONDS`; spent work is an expense in `SECONDS`. Beancount will not
  balance across commodities, so netting one against the other fails at parse time with
  exit 1 — the separation is enforced by the format rather than asked for in prose.
  `check_plan_and_spend_are_separate` intersects accounts and units as belt to that braces,
  because the day somebody unifies the units to tidy them up is the day the tool stops
  refusing.
- **The whole history is booked, not a trailing year.** A ledger that starts a year ago can
  say what a thing cost recently and not what it has cost. 479.8 h since 2020, of which
  42.70 h is the mesh.
- Beancount is an **operating-system tool, like gcc**. `brew install beancount`. Never
  vendored and never imported — it is GPL-2.0, which the licence policy here files as
  restricted, so keeping it outside the tree is a licence decision as well as a dependency
  one. Only the accounting files are tracked. `bean-check` ends `sys.exit(1 if errors
  else 0)`, which is what makes it a gate rather than a report.

Every gate in this repository asked whether a document was true. None asked whether
anything was delivered, and the difference is the whole failure. Measured over ninety days:
**21.2% of hours went to documents about the mesh and 7.4% to the mesh**, and every gate was
green throughout. One day inside that window merged nineteen pull requests, none of them on
the critical path. A green gate closes a check, not a deliverable.

### Estimate at the 1st and 99th percentile, and Bayesian

The three points are quantiles of a **posterior predictive**, not of the observed sample.
Session length is lognormal with a Jeffreys prior, so the estimate carries uncertainty
about the parameters as well as spread.

This is not pedantry, it is the difference between a plan and a flattering one. The
empirical 1st and 99th percentiles of the 5–9 commit bucket are its smallest and largest
observations — one session each — and a plan read off a single observation reports a p99 of
14.09 h where the predictive says 25.52 h. The wider number is the honest one, and it is
wider exactly where the evidence is thin, which is the property that makes it worth having.

1 to 99 rather than 5 to 95 for the reason the Daniels fit memo gives: an average-pilot
cockpit fits nobody, and the F-35 sized its adjustment range 1st to 99th.

**A chain's total is not the sum of its p99s.** Lognormals do not add in closed form, and
adding the worst cases answers a question nobody asked — every task simultaneously at its
worst. Sample the chain and read the total's own quantiles. `P0 → E → A` is 5.72 h at the
median and **31.37 h at the 99th**, where summing three-point estimates said 10.89 h.

**Say what a plan fits in.** At 99% confidence almost nothing fits a day: `P0` alone is 98%
inside eight hours, `P0 → E` is 94.4%, and the full path is 68.8%. A day of work is one
small task, and a plan that says otherwise is arithmetic nobody checked.

**Shrink the pessimistic case first.** A p99 is wide because the evidence is thin, so the
move that buys the most is the smallest one that says which end is real — which is the same
rule the critical path already states, arriving from the other direction.

### State the modelling choice that dominates the answer

A session's span excludes everything before its first commit, so spans near zero are
censored rather than short. Flooring them at fifteen minutes is a judgement, and it decides
the answer: the p99 for a 2–4 commit task reads **38.91 h at a one-minute floor, 10.91 h at
fifteen, and 7.49 h at thirty**. The floor is stated in `planned.beancount` alongside that
sensitivity, because a number this load-bearing that is chosen silently is a number nobody
can argue with. A censored likelihood would replace both the floor and the argument.


## Comments

- Match the comment density of FoundationDB, which is 12 to 14 percent of non-blank lines in
  `fdbserver`, `fdbclient` and `flow` at 7.3. Comment why the code does a thing, not what it
  does.

Most of this workspace is above that today. It comes down as files are touched, not in a sweep:
a commit that only reflows comments costs a review and proves nothing.

## How to deploy Godot Engine

- `scons production=yes precision=double debug_symbols=yes accesskit=yes`

## Six sides to the workspace

RFD 0111 gives this stack six words that name a position in the code:
transport layer, contract, interactor, entity, repository, and data
source.

"Service" names a deployment set, and ring, port, actor, and
controller name runtime things.

Six position words make six sides, so the workspace is one hexagon and the numbered directories are its sides.

- 1-transport the input that triggers an interactor
- 2-contract what a transport layer and an interactor compose against
- 3-interactor a process that performs actions on entities
- 4-entities the simulated things, and the actions on them
- 5-repository an interface that gets, creates, and changes entities
- 6-datasource an implementation of a repository
