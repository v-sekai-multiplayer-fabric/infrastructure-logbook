# The coastline paradox, as a rule for when an enhancement is finished

**Date:** 2026-08-17. **Asks:** gate fractal feature enhancements; suggest a fallback
constraint; take the shape from Apple's FoundationDB.

Richardson measured Britain's coast with a 200 km ruler and got 2,400 km; with a 50 km ruler
he got 3,400 km. Neither is wrong. A coastline has no length independent of the ruler used
to walk it, and as the ruler shrinks the measured length grows without bound.

Feature work has the same property, and this repository has the measurement to prove it.

## The measurement, from the ledger

`ledger.py report --since 90`, after the two Windows fixes below made a rebuild possible
here at all:

    Expenses:Other                          954372 s   69.4%
    Expenses:Docs                           252035 s   18.3%
    Expenses:Delivery:Mesh                   99177 s    7.2%
    Expenses:Fabric                          69720 s    5.1%
    TOTAL                                  1375304 s

**Documents about the work cost 2.54x the delivery they document.** That is the coastline:
prose describing a thing refines without limit, and the thing itself does not. `ledger.py`'s
own docstring recorded 5.3% delivery against 27.2% docs when it was written, a ratio of
5.1x, so the number has improved by half and is still the wrong way round.

### A finer ruler on one afternoon

One instruction -- hold `service-zone` out of the manifest until the work reaches it --
produced, in about eight hours: **6 merged pull requests across 3 repositories, 19 commits.**
The chain was not padding. Each step was a real defect found by fixing the one before it:

    hold zone out of the manifest
      -> the README's project count is now wrong          (a gated number)
      -> an em dash crashes xmerl in parse_manifest       (masked every other check)
      -> two linked libraries were never listed read-only (masked by the crash)
      -> ledger.py cannot decode git output on Windows    (cp1252 against UTF-8)
      -> ledger.py keys lookups on backslashed paths      (found by fixing the above)

Every one of those was worth fixing and none was in the original request. That is what a
shrinking ruler feels like from the inside: the work is real, the finding is genuine, and
the length still diverges.

## The shape Apple ships with

FoundationDB is a fair comparison: a database with a portability surface across three
platforms and several compilers, which is a coastline if anything is. Reading `release-7.3`:

    [release-7.3] Process ranges in chunks when evicting stale peers (#13643)
    Backport PR#13381 to release-7.3, relating to DD admission control (#13402)
    Add WriteBufferManager and charge Memtables to the Block Cache (#13361) (#13370)
    Revert WaitStorageMetricsHandleError SevWarn upgrade (#13336) (#13337)
    Release notes for 7.3.{78,79} (#13694)
    update version after 7.3.77 release
    build: clean-up zstd support in boost, fix zstd build
    ci: add github action to check clang-format

Four things carry the discipline, and none of them is "try to finish":

1. **There is a release line, and it is a different place from where work happens.**
   Nothing lands on `release-7.3` by being good. It lands by being *carried* there, and the
   subject says so: `Backport PR#13381 to release-7.3`. The default destination for a new
   finding is main, and the release branch's admission rule is explicit and narrow.
2. **The carry is per-finding and numbered.** Every backport names the pull request it came
   from. There is no "sync release with main"; there is a list of individually justified
   crossings.
3. **The release is an artefact, not an event.** `update version after 7.3.77 release` and
   `Release notes for 7.3.{78,79}` are commits. Something exists to point at.
4. **Reverting is ordinary.** A revert carries its own PR number and no apology. Backing a
   change out is a normal move rather than an admission, which is what makes the narrow
   admission rule affordable.

The ruler, in other words, is not a judgement about scope. It is a *branch*, and the
question "is this in?" has a mechanical answer.

## The gate

**An enhancement is finished when the gates are green at the current resolution -- not when
it is right.** The gates are the ruler. Detail they cannot see is out of scope by
definition, and the honest response to finding it is to *record* it, not to fix it inside
the change that tripped over it.

Concretely, and matching what `service-see-through` already does with `dev -> beta -> rc ->
release`:

- Work targets the trunk. A release line admits a change only by a named carry, one per
  finding, saying where it came from.
- A finding discovered while doing something else gets written down and left. It becomes
  its own change with its own ruler.
- A change that cannot say what it will *not* fix has no ruler and is not ready to start.

Note the direction this cuts. **Adding a gate lengthens the coastline**, because it is a
finer ruler and therefore finds more. That is an argument for gates and a reason to count
them: a new gate should be adopted knowing it will increase measured remaining work, and the
question is whether the detail it reveals is worth the walking.

## The fallback constraint

When no ruler can be agreed -- when nobody can say in advance what "done" means for a piece
of work -- fall back to the ledger, because it is the one constraint here that does not
depend on judgement:

> **Documents may not outspend the delivery they describe.** When `Expenses:Docs` exceeds
> `Expenses:Delivery:*` over the trailing 90 days, prose is the thing that stops.

Today that is **252,035 s against 99,177 s, a ratio of 2.54**, so the constraint is
currently violated and would be red the moment it was enforced. That is the point of
proposing it with the number attached rather than as a principle: it is not aspirational,
it is a description of a debt already owed.

It is a *fallback* rather than the primary rule because it constrains the aggregate and not
the change. It cannot tell you whether this enhancement is finished. It can tell you that
the last ninety days answered that question wrong, which is the thing nobody notices without
counting -- and, per the ledger's own docstring, the thing that went unnoticed before.

This entry is itself booked to `Expenses:Docs`.

## Two defects found on the way here

Both are in `ledger.py`, both are Windows-only, and the second was invisible until the first
was fixed.

- **`subprocess.run(..., text=True)` decodes as cp1252 on Windows.** Git log output is
  UTF-8, so a non-ASCII commit subject killed the reader thread and `.stdout` came back
  `None`. Fixed by naming `encoding="utf-8"` at all five call sites.
- **`relative_to()` yields backslashes on Windows.** Every lookup keyed on that string --
  `LANES`, the `.repo/manifests` special case -- is written with forward slashes, so on this
  desk none of them matched. Fixed with `as_posix()`.

**A correction, since it was reported wrongly first.** The second defect was announced here
as having made the 69.6% `Expenses:Other` figure an artefact. It did not. `report` reads the
committed books, which were generated on a desk where the paths were already correct, so the
split was sound. The near-identical numbers after a Windows rebuild -- 69.6% to 69.4%, Docs
18.4% to 18.3% -- are the evidence that the fix works rather than evidence that anything was
wrong. `Expenses:Fabric` moved 4.7% to 5.1% because `.repo/manifests` is now booked.

**Not measured.** `ledger.py verify` still cannot run here: it shells out to `bean-check`,
and no beancount is installed on this desk. So the books above are built and reported but
not validated, and byte-identical regeneration is unproven on Windows. This is the same gap
`usdcat` had until it was shimmed, and it is the reason the ratio above should be re-read on
a desk with beancount before anybody is held to it.
