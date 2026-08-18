# Measuring negative parallelism, and why no gate was written for it

**Date:** 2026-08-17. **Ask:** ban the "X is Y, not Z" construction with a gate.

The sentence that prompted this was mine: *"The ruler is a branch, not a judgement."*
tropes.fyi catalogues the shape as **Negative Parallelism** and calls it "El Classico", the
single most commonly identified AI writing tell. The line has been removed from
`coastline.md`.

No gate was written, and the measurement is why.

## Apparatus

Two regexes, for the two orders the construction takes:

    A  "is not X, it is Y"    is|are|was|it's not [word][,.;:-] (it|that|this|the)? is
    B  "is Y, not X"          is (a|an|the)? [word], not (a|an|the)? [word]

Run twice over every `*.md` in this repository: once against the raw bytes, once against
prose extracted from a CommonMark AST -- `markdown-it-py` 4.2.0 in `commonmark` mode,
keeping `text` children of `inline` tokens and dropping `code_inline` and `html_inline`.
Word counts are of the extracted prose, so density is per thousand words a reader reads.

## Result 1: the AST finds more, not less

    document                                      raw  ast   rawW   astW
    CLAUDE.md                                       6    6   6920   6545
    logbook/ward/one_core.md                        2    3   3906   3761
    logbook/ward/topology.md                        1    2   2071   2052
    logbook/ward/determinism.md                     2    2    544    529
    logbook/coastline.md                            2    2   1277   1076
    ...
    total                                          16   18

The expectation was that the AST would find **fewer** matches, because it drops fenced code
and inline spans, and a document quoting the trope as an example would stop tripping over
itself. That is real but it is not the dominant effect here.

The dominant effect is **line wrapping**. These documents are hard-wrapped near 95
characters, so a construction that straddles a wrap is invisible to a regex reading raw
bytes and visible once the AST joins the text nodes. Two of the eight documents hid a match
that way, both of them long ones.

So the instrument matters in the opposite direction to the one assumed: raw scanning
under-counts prose tells in wrapped documents, and any gate for this must read the AST or
report a number that is quietly low.

## Result 2: a correction

Density per thousand prose words:

    this repository's own documents   15 matches / 14477 words = 1.04
    the three written this session     3 matches /  2357 words = 1.27

An earlier commit message on this branch says the construction "occurs more in this
workspace's own prose than in mine". **That is wrong, and it is wrong because it compared
raw absolute counts across corpora of very different size** -- 13 against 3 -- without
normalising. Per thousand words the session's prose is about 22% denser, not less dense.

What survives the correction is the conclusion that mattered: both sit near 1 per 1000
words, the same order of magnitude. `CLAUDE.md` carries six, and
`logbook/ward/determinism.md` is the densest document in the repository. The construction is
part of how this workspace already writes.

## Why no gate

A regex that catches the construction catches this repository's own prose at a similar rate
to the prose it was aimed at. A density threshold set to pass the existing corpus has to sit
above 3.68 per thousand -- `determinism.md` -- which passes every document measured here,
including the sentence that prompted the request.

The narrowest form is gateable and nearly worthless. Requiring the negation and its
restatement to be **separate sentences**, which is tropes.fyi's canonical "It's not bold.
It's backwards.", matches **zero** documents in the workspace. It could be adopted at no
cost. It also does not catch the line this started with, so it would be a gate that reports
green on the defect it was built for.

The distinguishing property is not grammatical. This repository's instances contrast
concrete technical referents -- "is booked, not a trailing year", "is allocated, not
summed". The removed line contrasted two abstractions and was built to be quotable, which
tropes.fyi lists separately as *Quotable one-liners*. No regex separates those two, and a
gate that cannot tell them apart would spend its budget failing on `CLAUDE.md`.

`coastline.md` argues that adding a gate lengthens the coastline, because a finer ruler
finds more. This is the case where the detail found is not worth the walking, and the
finding is recorded instead.

## Not measured

- **Only `*.md` was measured.** The `.py` and `.ex` docstrings that carry much of this
  workspace's prose have no CommonMark AST and were excluded, so the corpus is smaller than
  the writing. `ledger.py` and `lib.ex` both contain the construction.
- **One author, two samples.** "Theirs" and "mine" are not independent: the session's
  documents were written to match the house voice deliberately, so a density difference of
  22% is as likely to be imitation succeeding as a tell showing through.
- **Forty-seven other tropes** are catalogued and none was measured. Em-dash addiction is
  the first on the list and cost this workspace a red main earlier the same day, which is
  the one with a measured cost attached rather than a stylistic objection.
