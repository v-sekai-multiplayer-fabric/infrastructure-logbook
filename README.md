# infrastructure-logbook

The fabric's record of itself: the conventions every project here works to, the ledger that books the hours, the gates that decide whether these documents are true, and the logbook.

It sits on the `0-` side because it is not a side. `default.xml`'s opening comment gives the workspace six position words and one packing word; this is neither. Every other project in the manifest is a subject of this one, which is why it sorts before all of them.

```sh
mix check --fast       # the checkout answers these
mix check --slow       # what only a remote can answer
mix check --self-test  # each must fail on broken input
mix check authority    # one concern, and only it
mix dialyzer           # the gate's own types
```

```sh
python3 misc/scripts/ledger.py report --since 90   # SPENT, by lane
python3 misc/scripts/ledger.py path                # HYPOTHETICAL, the critical path
```

## What is here

| | |
|---|---|
| `CLAUDE.md` | the conventions, which hold in every repository under this workspace |
| `logbook/` | dated entries: what was measured, and what was retracted |
| `ledger/` | hours booked from git history, and the plan in a separate commodity |
| `misc/checks` | the gates, one mix module per concern |
| `misc/scripts` | the emitters the gates run |
| `memory/` | OpenUSD layers, validated by the system `usdcat` |

## Where the manifest is

Not here. `fabric` holds `default.xml` and nothing else, and `repo init` clones it to `.repo/manifests` and reads it from there. The gates read it from that checkout, found by looking for `.repo` above this one, and `FABRIC_MANIFEST` overrides that for a bare clone with no workspace around it — which is what CI is.

The two were one repository until the jobs were told apart. A manifest is read by a tool on every sync; a record is read by people and rewritten as the work moves, and keeping both in one place made every entry here a commit against the manifest. `CLAUDE.md` says why each rule exists.
