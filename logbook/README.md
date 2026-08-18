# Logbook

The engineering record. An entry says what was **measured**, not what was intended, and it carries enough of the apparatus to re-run the test rather than only its conclusion.

An entry that turned out to be invalid stays, and says why. A run that is deleted teaches nothing twice, and a retraction sitting next to what it retracts is the only form a reader arriving later can trust.

A physical measurement is paired with a household-object equivalent, because "4.3 mm" does not tell a reader whether an error matters and "about three stacked pennies" does.

## What is here

| | |
|---|---|
| `ward/` | the `interactor-ward` bench log: topology, scaling, determinism, curves, one-core, filming, borrowed tricks |

`ward/` lived in that repository's `docs/logbook/`, where it was read by whoever was already in that checkout and by nobody else. Its topology entry is the argument for moving it: the question came back, nobody could answer it from the record, and the finding was that no topology had been chosen and none of the entries said so. A record that only the current checkout can see is a record that gets asked the same question twice.

## What is deliberately not here

The weftspun cross-project record stays in `weftspun/logbook`, which is private and says why: it cites dataset inventory paths, blocklist rationale, and licensing decisions that were not meant for publication. This repository is public, so folding it in would have published all three by a move nobody would have read as a publication decision.

That is the rule rather than the one-off. A record is copied here only if it can be public, and where it cannot, the pointer is what moves. Nothing was lost to say so: every file is still in its own repository, under the visibility it was written for.
