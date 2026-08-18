#!/usr/bin/env python3
"""Fabric delivery: git history booked as double-entry seconds, checked by tackler.

Ninety days of commits went 5.3% to the mesh being delivered and 27.2% to documents
about it, and nobody noticed because nothing counted. A ledger counts. Double entry is
the right shape for it: an hour cannot be spent without being booked against where it
came from, so the lane split falls out of the file instead of being argued.

Tackler is an operating-system tool here, the way gcc is. `cargo install tackler`,
never vendored and never imported. It replaced beancount, whose GPL-2.0 the licence
policy here files as restricted; Apache-2.0 lifts that constraint, and the arrangement
stays anyway -- the artefact is ours, the validator is the system's, and the validator
is what keeps a hand-written emitter honest. This is the same arrangement the memory
store has with `usdcat`. Strict mode makes the chart of accounts a declaration rather
than a habit, and audit mode requires a UUID on every transaction and stamps every
report with a txn-set checksum, so "the books changed" is a hash comparison.

  ledger.py build            git sessions -> ledger/spent/*.txn and the chart
  ledger.py report [--since N] [--by-project]   the split, in seconds
  ledger.py path             the critical path, computed from ledger/planned/
  ledger.py verify           tackler, then regeneration must be byte-identical
"""
import argparse
import collections
import datetime
import math
import pathlib
import random
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]


def _workspace_root():
    """Where the checkouts sit, which is not where this repository sits.

    The directory that holds `.repo` is the one `repo sync` puts every project under, so
    every project asks the same question and this one is no longer special. It used to test
    for being at `.repo/manifests` and climb two, which was a rule about where the manifest
    repository lands; this repository is now an ordinary project on the `0-` side and that
    rule reads a directory that is not there.

    Getting this wrong is not a loud failure, which is why it is a function with a reason
    attached. When a `path="."` entry was removed and the climb was left assuming the
    projects sat beside this repository, `_checkouts()` found exactly one checkout -- itself
    -- and a rebuild quietly cut the ledger from 326 sessions to 3.

    Same helper `Check.Lib.workspace_root/0` carries, for the same reason.
    """
    for parent in [ROOT, *ROOT.parents]:
        if (parent / ".repo").is_dir():
            return parent
    return ROOT
# The roots are the tackler configs: each names its journal directory, its chart and its
# one commodity, and validating the config validates the whole set. SPENT and PLANNED
# are what `tackler --config` is pointed at; the *_ACCOUNTS charts are generated (spent)
# or hand-written (planned), and Check.Ledger intersects them.
SPENT = ROOT / "ledger" / "spent.toml"
SPENT_ACCOUNTS = ROOT / "ledger" / "spent-accounts.toml"
SPENT_DIR = ROOT / "ledger" / "spent"
PLANNED = ROOT / "ledger" / "planned.toml"
PLANNED_ACCOUNTS = ROOT / "ledger" / "planned-accounts.toml"
PLANNED_DIR = ROOT / "ledger" / "planned"


def _planned_text():
    """Every planned book's text, since the tasks live in the per-project files.

    The root holds what is common -- the budget, the deliverable, the chart -- and the
    tasks sit in the book of the repository each will be done in, matching ledger/spent/.
    Reading only the root found no tasks at all and `path` failed on an empty sequence,
    which is the right failure: a plan reader that silently reports no critical path
    because it looked in the wrong file is worse than one that stops.
    """
    return "\n".join(f.read_text(encoding="utf-8")
                      for f in sorted(PLANNED_DIR.glob("*.txn")))

# A gap longer than this means somebody went away rather than worked slowly. Same
# definition the PERT table in CLAUDE.md is derived from, so the two agree by construction.
SESSION_GAP_H = 4

# A day holds 86400 seconds and the allocation is a partition of wall clock, so a day's
# books must sum to no more than that. It is not a style rule: the first version of this
# ledger summed each repository's own sessions and charged 2026-08-16 with 144,144 s, which
# is 1.67 days, and nothing objected because nothing was checking. The busiest day now
# books 77,475 s, 89.7% of one, so the margin is thin enough that a regression would look
# plausible rather than absurd.
SECONDS_IN_A_DAY = 86400


def day_totals():
    """Seconds booked per (calendar day, resource), across every project's book.

    The ceiling belongs to a resource, not the calendar: two resources spend 48 h of effort
    in a 24 h day. A per-day ceiling would fail on that and still hide one resource booked
    twice inside a total with room for it.
    """
    d = collections.Counter()
    for day, _acct, secs, who in _postings():
        d[(day, who)] += secs
    return d


def overbooked_days():
    """(day, resource, seconds) where one resource books more than a day contains.

    Must always be empty, however many resources there are.
    """
    return sorted((day, who, s) for (day, who), s in day_totals().items()
                  if s > SECONDS_IN_A_DAY)

# Which lane a checkout's hours are booked to. The mesh chain is named explicitly because
# it is the one the build asks about; everything else we author falls to Other.
LANES = {
    "2-contract/patch-verify": "Expenses:Delivery:Mesh",
    "3-interactor/triangulation": "Expenses:Delivery:Mesh",
    "3-interactor/cassie": "Expenses:Delivery:Mesh",
    "3-interactor/sketch": "Expenses:Delivery:Mesh",
    "2-contract/manuals": "Expenses:Docs",
    ".repo/manifests": "Expenses:Fabric",
    "0-infrastructure/logbook": "Expenses:Fabric",
    ".": "Expenses:Fabric",
}
DEFAULT_LANE = "Expenses:Other"
ACCOUNTS = ["Income:Sessions", "Expenses:Delivery:Mesh", "Expenses:Docs",
            "Expenses:Fabric", "Expenses:Other"]

# Whose commits are this project's hours. Keyed on the author, not on the repository.
#
# It was a list of checkouts to skip, which is a proxy for "code we did not write" and a
# proxy a fork breaks: 6-datasource/foundationdb was on the list to keep upstream's 2366
# commits out, and it kept our sixteen on portability-consensus out with them, so a day of
# CI work on that repository booked 0.00 h. The author is the thing actually being asked
# about, and it needs no list to stay current.
# email -> resource. A resource owns one timeline: its own spans are apportioned, never
# added. Separate resources overlap freely, so two working at once book two lots of effort
# against one of clock. A map, not a set: several addresses may be one resource, and a
# program that commits is a resource like a person.
#
# The key is interactor-taskweft's entity id (`human_1`, `drone_1`), which HRR/Basic.lean
# also binds memories to. Reuse it; a third spelling cannot be joined to the other two.
# An address absent here is not booked at all.
RESOURCES = {
    "ernest.lee@chibifire.com": "fire",
    "fire@users.noreply.github.com": "fire",
}
OURS = set(RESOURCES)


def _checkouts():
    """Every git checkout in the workspace, named by its path relative to the root.

    Two levels because the manifest puts most children on a side of the hexagon, one
    directory down; a one-level glob finds the few at the root and reports the rest as
    absent, which is the answer this exists to prevent. This repository sits on the `0-`
    side and the same glob finds it, with no case of its own -- the "this repository,
    wherever repo put it" line it used to need went with the special placement.

    `pathlib.glob` matches a leading dot where a shell glob does not, so the two patterns
    also reach `.repo/manifests` and `.repo/repo`. The manifest repository being booked is
    wanted. `.repo/repo` is git-repo itself and is not ours; nothing excludes it here
    because the author filter already does, and a second list to keep current would be a
    proxy for the question that filter actually asks.
    """
    ws = _workspace_root()
    seen = []
    for pat in ("*/.git", "*/*/.git"):
        for g in ws.glob(pat):
            # POSIX separators, always. `relative_to` gives backslashes on Windows, and
            # every lookup keyed on this string -- LANES, the `.repo/manifests` special
            # case, _cff -- is written with forward slashes, so a Windows desk matched
            # none of them and booked the whole workspace to Expenses:Other.
            seen.append((g.parent.relative_to(ws).as_posix(), g.parent))
    # A plain clone is its own workspace and the globs above find nothing.
    if (ROOT / ".git").exists() and ROOT == ws:
        seen.append((".", ROOT))
    return sorted(set(seen))


def _allocate():
    """Seconds allocated across checkouts with no overlap, as (day, repo) -> (seconds, subjects).

    Summing each repository's sessions double-counts. Work moves between repositories inside
    one sitting, so their spans are concurrent, and adding them charged 2026-08-16 with
    144,144 seconds -- a figure no day contains. Accounting has a name for the fix and it is
    allocation: there is one pool of time, and it is apportioned rather than added.

    The pool is every interval between consecutive commits anywhere in the workspace, and
    the driver is which repository's commit closed the interval. That makes the charge a
    partition -- every interval belongs to exactly one repository, and the day's total is
    the union of the active spans rather than the sum of overlapping ones. The same day now
    costs 8.44 h, and no day in a year exceeds 24.

    The whole history is booked, not a trailing year. A ledger that starts a year ago
    cannot say what a thing has cost, only what it cost recently, and the question the gate
    asks -- did this move -- is worth asking against everything that was ever spent on it.

    An interval longer than four hours is somebody going away rather than working slowly,
    so it is charged to nobody. The first commit after such a gap therefore books nothing,
    which is the censoring the plan's floor exists to answer: a span between commits cannot
    see the work before the first one.
    """
    by_resource = collections.defaultdict(list)
    for rel, path in _checkouts():
        out = subprocess.run(["git", "-C", str(path), "log", "--pretty=%ct\t%ae\t%s"],
                             capture_output=True, text=True, encoding="utf-8").stdout.splitlines()
        for line in out:
            ct, _, rest = line.partition("\t")
            email, _, subj = rest.partition("\t")
            who = RESOURCES.get(email)
            if who is None:
                continue
            try:
                by_resource[who].append((int(ct), rel, subj))
            except ValueError:
                pass

    seconds = collections.Counter()
    steps = collections.defaultdict(list)
    # One walk per resource. A single walk over every commit is the one-worker model: two
    # resources interleave, each closing the other's interval, so concurrent effort is
    # charged once between them instead of twice.
    for who, events in by_resource.items():
        events.sort()
        # Every commit is recorded; only the intervals between them are charged. Walking
        # pairs alone dropped whichever commit sorted first, because it is never the later
        # half of a pair -- one commit missing out of 564, which is exactly the kind of error
        # a lane total absorbs without trace and a per-project book does not.
        prev = None
        for ct, rel, subj in events:
            day = datetime.datetime.utcfromtimestamp(ct).date().isoformat()
            steps[(day, rel, who)].append(subj)
            if prev is not None:
                gap = ct - prev
                if 0 < gap <= SESSION_GAP_H * 3600:
                    seconds[(day, rel, who)] += float(gap)
            prev = ct
    for k in steps:
        seconds.setdefault(k, 0.0)
    return seconds, steps


def _cff(path):
    """A project's CITATION.cff as chart-comment fields, with git filling the gaps.

    A chart that says only "Patch-Verify" makes the reader open another repository to learn
    what it is, what licence it carries and where it lives. CFF already answers that in
    every repository that has one, so the chart carries it: title and abstract for what the
    work was, licence and repository-code for what may be done with it and where, version
    and date-released for which state of it these seconds bought.

    Nineteen of forty-six repositories have a CITATION.cff. For the rest git supplies what
    it can -- the remote and the first commit -- and the absent fields are absent rather
    than guessed, because a citation invented here would be worse than none.

    This is a copy, and a copy diverges. The source is the project's own CITATION.cff and
    it will change without this file changing with it, so every copied block carries
    `cff-copied`, the datetime its CITATION.cff was last committed. That is stable across
    rebuilds, unlike the moment of copying, so it does not break the byte-identical check
    that proves this file is generated -- and it answers the better question: which version
    of the citation this is. A CITATION.cff committed after that stamp is a copy that has
    diverged, and the comparison is two timestamps rather than a guess.

    `cff-commit` pins it exactly. With `repository-code` beside it the source is fetchable
    -- `git show <cff-commit>:CITATION.cff` in that repository returns the bytes this was
    copied from -- so divergence is not merely detectable but resolvable, which a date on
    its own does not give you.
    """
    meta = {}
    cff = path / "CITATION.cff"
    if cff.exists():
        txt = cff.read_text(encoding="utf-8", errors="replace")
        # A tiny reader for the scalars this needs, so nothing here depends on PyYAML.
        for key in ("cff-version", "title", "version", "date-released", "license",
                    "repository-code"):
            for line in txt.splitlines():
                if line.startswith(key + ":"):
                    v = line.split(":", 1)[1].strip().strip('"').strip("'")
                    if v:
                        meta[key] = v
                    break
        block, abstract = False, []
        for line in txt.splitlines():
            if line.startswith("abstract:"):
                block = True
                continue
            if block:
                if line[:1].isalpha() or not line.strip():
                    if abstract:
                        break
                    continue
                abstract.append(line.strip())
        if abstract:
            meta["abstract"] = " ".join(abstract)
    r = subprocess.run(["git", "-C", str(path), "remote", "-v"], capture_output=True, text=True, encoding="utf-8")
    urls = {l.split()[1] for l in r.stdout.splitlines() if len(l.split()) >= 2}
    if len(urls) == 1 and "repository-code" not in meta:
        meta["repository-code"] = urls.pop().removesuffix(".git")
    first = subprocess.run(["git", "-C", str(path), "log", "--reverse", "--pretty=%cs",
                            "--max-parents=0"], capture_output=True, text=True, encoding="utf-8").stdout.split()
    if first:
        meta["first-commit"] = first[0]
    if cff.exists():
        # The datetime CITATION.cff was last committed, not the moment of the copy. "Now"
        # would be honest about when the copy ran and would also change on every rebuild,
        # which breaks the byte-identical regeneration check that proves this file is
        # generated at all. The source's own commit time is stable, and it answers the
        # better question anyway: which version of the citation this is. A CITATION.cff
        # committed after this stamp is a copy that has diverged.
        r = subprocess.run(["git", "-C", str(path), "log", "-1", "--format=%cI%n%H",
                            "--", "CITATION.cff"], capture_output=True, text=True, encoding="utf-8").stdout.split()
        if len(r) == 2:
            meta["cff-copied"], meta["cff-commit"] = r
    return meta


def _account(rel):
    """One book per project, hanging off the lane it belongs to.

    A lane on its own is four totals, and a total absorbs an error silently -- the dropped
    commit above sat inside one for a day. Accounts are hierarchical, so a leaf per project
    gives both: the tree balance report still rolls Expenses:Delivery:Mesh up for the gate,
    and every project's own seconds are auditable against `git log` on their own line.

    Beancount required each component to open with an uppercase letter; tackler does not,
    and the Title-Case stays because the books and their filenames already carry it, and a
    rename that rewrites every line for a style point is diff noise pretending to be work.
    2-contract/patch-verify is Patch-Verify under 2-Contract.
    """
    lane = LANES.get(rel, DEFAULT_LANE)
    leaf = rel.split("/")[-1] if rel not in (".", ".repo/manifests") else "Fabric"
    # A leading dot cannot survive: a tackler account component is an identifier, and
    # `.claude` is not one -- the dot is the decimal separator. The checkout is named for
    # the directory Claude Code reads and the repository is `dot-claude`, so spelling the
    # dot is what the repository already decided.
    if leaf.startswith("."):
        leaf = "dot-" + leaf[1:]
    leaf = "-".join(w[:1].upper() + w[1:] for w in leaf.split("-") if w)
    return f"{lane}:{leaf}" if leaf else lane


def _book_name(acct):
    """The file a book lives in, named for the whole account.

    The leaf alone is unique only until two projects share it: 2-contract/triangulation and
    3-interactor/triangulation differ by lane, and the second silently overwrote the first,
    losing 0.45 h. The account is lane plus leaf and so is already unique.
    """
    return acct.split(":", 1)[1].replace(":", "-") + ".txn"


def _escape(s):
    """Steps ride inside a double-quoted metadata comment, so a quote in a subject ends it."""
    return s.replace("\\", "").replace('"', "'")


def _uuid(day, rel, who):
    """The txn's UUID, derived from its day and project rather than drawn.

    Audit mode requires one on every transaction and folds them into the txn-set checksum.
    A random UUID would change on every rebuild and break the byte-identical check; a
    name-based UUID of (day, project, resource) is stable and unique by construction. The
    resource is in the name because two of them on one project in one day are two txns.
    """
    return uuid.uuid5(uuid.NAMESPACE_URL, f"fabric-spent/{day}/{rel}/{who}")


def build():
    """One txn file per project, and the chart of accounts beside them.

    A single file put every project's seconds in one place, so a change to one project
    rewrote lines belonging to forty-three others and a diff said nothing about which
    project moved. Tackler reads the whole of ledger/spent/ as one journal, so the split
    costs nothing: `tackler --config spent.toml` validates the set, while each project's
    history is its own file with its own git blame.

    The chart is generated with the books because strict mode makes it load-bearing: an
    account not declared in spent-accounts.toml is a validation error, so the chart is
    exactly the set of accounts the books use, and each entry's comment block carries the
    project's CITATION.cff -- what the open directive used to carry when the format had one.

    A session that charges nothing books nothing. Tackler refuses a zero-sum posting, and
    it is right to: a transaction that moves nothing is not a transaction. The old format
    tolerated a 0-SECONDS row as a diary line; the commits it recorded are still in git,
    which is the source, and the sessions that do charge carry their subjects in `steps`.
    """
    seconds, steps = _allocate()
    paths = {rel: path for rel, path in _checkouts()}
    entries = sorted((day, rel, who, _account(rel), seconds.get((day, rel, who), 0.0),
                      len(steps[(day, rel, who)]), steps[(day, rel, who)])
                     for (day, rel, who) in steps)

    by_project = collections.defaultdict(list)
    for e in entries:
        by_project[e[1]].append(e)

    SPENT_DIR.mkdir(parents=True, exist_ok=True)
    booked, written, keep, charted = 0, 0, set(), []
    for rel, rows in sorted(by_project.items()):
        acct = _account(rel)
        name = _book_name(acct)
        lines, first_txn = [], True
        for day, _rel, who, account, secs, n, subjects in rows:
            amt = f"{secs:.0f}"
            if amt == "0":
                continue
            lines.append(f"{day} '{_escape(rel)}: {_escape(subjects[-1])[:88]}")
            lines.append(f"    # uuid: {_uuid(day, rel, who)}")
            if first_txn:
                lines.append(f"    ; {_escape(rel)} -- generated by misc/scripts/ledger.py, do not edit.")
                first_txn = False
            lines.append("    ; spent: TRUE")
            # Whose timeline the hour came off. The ceiling is per resource, so the
            # check needs this in the book.
            lines.append(f'    ; resource: "{_escape(who)}"')
            lines.append(f"    ; commits: {n}")
            steps_s = " | ".join(_escape(s)[:72] for s in subjects)
            lines.append(f'    ; steps: "{steps_s[:900]}"')
            lines.append(f"    {account:<34} {amt:>11} SECONDS")
            lines.append("    Income:Sessions")
            lines.append("")
            booked += 1
        # A project whose every session charged zero has no transactions to hold, and a
        # file with none of them will not parse, so it is not written and not charted.
        if not lines:
            continue
        (SPENT_DIR / name).write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
        keep.add(name)
        written += 1
        block = [f"    # {rel}"]
        for k, v in sorted(_cff(paths[rel]).items()):
            block.append(f"    #   {k}: {_escape(str(v))[:220]}")
        block.append(f'    "{acct}",')
        charted.append((acct, block))

    chart = [
        "# Generated by misc/scripts/ledger.py -- do not edit.",
        "#",
        "# The chart of the spent books, one leaf per project. Strict mode makes this a",
        "# declaration rather than a habit: a posting to an account not listed here fails",
        "# validation, so a typo in a lane is an error instead of a new lane. Each entry's",
        "# comment block carries the project's CITATION.cff, so the chart says what the",
        "# work was and what may be done with it without opening the repository.",
        "accounts = [",
        '    "Income:Sessions",',
    ]
    # A project that left the manifest keeps its book. Its checkout is gone, so the seconds
    # cannot be regenerated and the file is the only copy; unlinking it lost 124.56 h of
    # 606.28 h the first time. Chart entries are carried forward from the previous chart
    # (`_cff` needs a checkout too), which strict mode requires and which keeps `build`
    # idempotent.
    departed = sorted(f for f in SPENT_DIR.glob("*.txn") if f.name not in keep)
    if departed:
        previous = _chart_blocks()
        for f in departed:
            acct = _account_in(f)
            if acct is None:
                continue
            # The fallback must declare the account; a comment block alone validates
            # nothing and strict mode rejects the book.
            block = previous.get(acct) or [
                f"    # departed: no chart entry survived",
                f'    "{acct}",',
            ]
            if not any("departed" in ln for ln in block):
                block = block[:-1] + [
                    "    #   departed: left the manifest; book retained, seconds are spent",
                    block[-1],
                ]
            charted.append((acct, block))

    for _acct, block in sorted(charted):
        chart.extend(block)
    chart.append("]")
    SPENT_ACCOUNTS.write_text("\n".join(chart) + "\n", encoding="utf-8")
    return booked, written + len(departed)


def _chart_blocks():
    """{account: [comment lines..., \"Account\",]} from the chart on disk.

    Reads the previous run's output on purpose: a departed project's CITATION.cff is
    unreachable once its checkout is gone, so the last chart that saw it is the only copy.
    """
    if not SPENT_ACCOUNTS.exists():
        return {}
    blocks, cur = {}, []
    for line in SPENT_ACCOUNTS.read_text(encoding="utf-8").splitlines():
        t = line.strip()
        if t.startswith("#") and line.startswith("    "):
            cur.append(line)
        elif t.startswith('"') and t.endswith('",'):
            blocks[t[1:-2]] = cur + [line]
            cur = []
        else:
            cur = []
    return blocks


def _account_in(path):
    """The account a book posts to, read from its first expense posting."""
    for line in path.read_text(encoding="utf-8").splitlines():
        t = line.strip()
        if t.startswith("Expenses:") and "SECONDS" in t:
            return t.split()[0]
    return None


def _postings(since_days=None):
    """(date, account, seconds, resource) for every expense posting, read back from the file.

    Read back rather than recomputed, so `report` and the delivery gate answer from the
    artefact that is committed. A number produced by the generator and never read from
    the file would prove the generator agrees with itself.
    """
    cutoff = None
    if since_days is not None:
        cutoff = datetime.date.today() - datetime.timedelta(days=since_days)
    out, day, who = [], None, "?"
    lines = []
    for f in sorted(SPENT_DIR.glob("*.txn")):
        lines += f.read_text(encoding="utf-8").splitlines()
    for line in lines:
        # A txn header is `YYYY-MM-DD '...`; a posting is an indented account line. The
        # metadata and comments between them start with `#` or `;` and match neither.
        if len(line) > 11 and line[4] == "-" and line[7] == "-" and line[11] == "'":
            try:
                day = datetime.date.fromisoformat(line[:10])
            except ValueError:
                day = None
            # A retained book predates the resource field; the checkout that could name
            # the resource is gone, so supply one rather than fail.
            who = "?"
        elif line.strip().startswith('; resource:'):
            who = line.split('"')[1]
        elif day is not None and line.startswith("    Expenses:"):
            acct, _, amt = line.strip().partition(" ")
            secs = float(amt.replace("SECONDS", "").strip())
            if cutoff is None or day >= cutoff:
                out.append((day, acct, secs, who))
    return out


def docs_ratio(since_days=90):
    """Seconds booked to documents, over seconds booked to the delivery they describe.

    The one number the coastline entry proposes as a brake. Feature work refines without a
    natural stopping point -- every fix reveals a finer one -- and prose about the work
    refines faster, because nothing about a document is ever finished. Counting is what
    tells the two apart, and this is the count.

    Read back from the committed books like everything else here, so the gate judges the
    artefact rather than the generator's opinion of it.

    Returns `(docs, delivery, ratio)` in seconds. Delivery of zero gives a ratio of `inf`,
    which is the honest reading: prose with nothing behind it is not a small ratio.
    """
    docs = delivery = 0.0
    for _day, account, secs, _who in _postings(since_days):
        if account.startswith("Expenses:Docs"):
            docs += secs
        elif account.startswith("Expenses:Delivery:"):
            delivery += secs
    ratio = docs / delivery if delivery else float("inf")
    return docs, delivery, ratio


def report(since_days, by_project=False):
    """The lane split, or the project split under it.

    Accounts are hierarchical so a project's seconds roll up to its lane, and the lane is
    what answers "where did the time go". The leaves answer "which project", which is the
    question worth asking second and the one that makes a wrong number visible: a lane
    total absorbed a dropped commit for a day, and a project line would not have.
    """
    rows = _postings(since_days)
    tot = collections.Counter()
    for _, acct, secs in rows:
        tot[acct if by_project else acct.rsplit(":", 1)[0]] += secs
    total = sum(tot.values()) or 1.0
    print(f"  SPENT -- {since_days} days, from {SPENT_DIR.relative_to(ROOT)}")
    for acct, secs in sorted(tot.items(), key=lambda x: -x[1]):
        print(f"    {acct:<34} {secs:11.0f} s  {secs / total * 100:5.1f}%")
    print(f"    {'TOTAL':<34} {total:11.0f} s")
    return 0


def delivery_seconds(window_days=30):
    """Seconds booked to the mesh in the trailing window. What the build asks about."""
    return sum(s for _, a, s, _w in _postings(window_days) if a.startswith("Expenses:Delivery"))


def verify():
    bad = 0
    for conf in (SPENT, PLANNED):
        # tackler validates the whole journal a config names -- books, chart, commodities
        # -- and exits non-zero on any error, which is what makes it a gate. The balance
        # report it prints on success opens with the txn-set checksum; the exit code is
        # what is judged here.
        r = subprocess.run(["tackler", "--config", str(conf)],
                           capture_output=True, text=True, encoding="utf-8")
        if r.returncode != 0:
            print(f"  tackler rejects {conf.name}:")
            for line in (r.stderr or r.stdout).strip().splitlines()[:6]:
                print(f"    {line}")
            bad += 1
        else:
            print(f"  tackler ok  {conf.name}")
    over = overbooked_days()
    for day, who, s in over[:5]:
        print(f"  {day} books {s:.0f} s for {who}, and a day holds {SECONDS_IN_A_DAY}")
    bad += len(over)

    generated = lambda: {f.name: f.read_text(encoding="utf-8")
                         for f in [*sorted(SPENT_DIR.glob("*.txn")), SPENT_ACCOUNTS]}
    before = generated()
    build()
    if before != generated():
        print("  the ledger is not what git says; it was hand-edited")
        bad += 1
    else:
        print("  regenerates byte-identical")
    print("SPENT VERIFY PASS" if bad == 0 else f"{bad} problem(s)")
    return bad


def _plan_tasks():
    """The planned tasks, read out of the plan ledger's metadata comments.

    The plan is a ledger file rather than a diagram because a diagram goes stale and
    nothing notices. Here a task is a transaction, its three-point estimate rides in the
    txn's comments, and the path below is computed rather than drawn -- so an estimate
    cannot disagree with the picture of it, which is how 231/234 outlived the code that
    reached 1360/1360. Tackler carries only uuid, location and tags as first-class
    metadata, so the task fields are `;` comments in a fixed key: value shape, and this
    is the one reader of them.
    """
    def stripped():
        for line in _planned_text().splitlines():
            s = line.strip()
            yield s.lstrip(";").strip() if s.startswith(";") else s

    tasks, cur = {}, None
    for s in stripped():
        if s.startswith("task:"):
            cur = s.split('"')[1]
            tasks[cur] = {"id": cur, "depends": "", "o": 0.0, "m": 0.0, "p": 0.0,
                          "what": "", "done": ""}
        elif cur and s.startswith("depends:"):
            tasks[cur]["depends"] = s.split('"')[1]
        elif cur and s.startswith("done:"):
            tasks[cur]["done"] = s.split(":", 1)[1].strip()
        elif cur and s.split(":")[0] in ("optimistic", "likely", "pessimistic"):
            k, _, v = s.partition(":")
            tasks[cur][{"optimistic": "o", "likely": "m", "pessimistic": "p"}[k]] = float(v)
    # The description carries what the task is; re-read to attach it to the id below it.
    narr = None
    for s in stripped():
        if s[:1].isdigit() and "'plan: " in s:
            narr = s.split("'plan: ", 1)[1].strip()
        elif s.startswith("task:") and narr:
            tasks[s.split('"')[1]]["what"] = narr
    for t in tasks.values():
        t["te"] = (t["o"] + 4 * t["m"] + t["p"]) / 6
    return tasks


def _open_tasks():
    """Tasks still to do. A done task stays in the file as a record and leaves the path."""
    return {k: v for k, v in _plan_tasks().items() if not v["done"]}


def _predictive(task, draws, rng):
    """Draws from a task's posterior predictive, recovered from its three points.

    The plan stores quantiles, not parameters, so the lognormal is read back out of them:
    the median fixes mu, and the ratio of the 99th percentile to the median fixes sigma,
    because ln(p99/m) is 2.326 sigma. Nothing else in the file is needed, which keeps the
    planned books the only source and this function a reader of them.
    """
    m = max(task["m"], 1e-6)
    sigma = max(math.log(max(task["p"], m * 1.0001) / m) / 2.326, 1e-6)
    mu = math.log(m)
    return [math.exp(rng.gauss(mu, sigma)) for _ in range(draws)]


def path(draws=40000):
    """Longest chain of dependent tasks, and when it finishes with 99% probability.

    The chain's total is not a sum of three-point estimates. Lognormals do not add in
    closed form, and adding the p99s would answer a different question -- every task
    simultaneously at its worst, which is far more pessimistic than the chain being late.
    So the tasks are sampled together and the total's own quantiles are read off. The seed
    is fixed, because a plan that changes when you look at it twice is not a plan.
    """
    tasks = _open_tasks()

    def chain(tid, seen=()):
        if tid in seen:
            raise SystemExit(f"plan has a dependency cycle at {tid}")
        t = tasks[tid]
        dep = t["depends"]
        prev = chain(dep, seen + (tid,)) if dep else []
        return prev + [tid]

    chains = {tid: chain(tid) for tid in tasks}
    longest = max(chains.values(), key=lambda c: sum(tasks[i]["te"] for i in c))
    span = sum(tasks[i]["te"] for i in longest)
    oncrit = set(longest)

    rng = random.Random(20260816)
    sims = [_predictive(tasks[i], draws, rng) for i in longest]
    totals = sorted(sum(c) for c in zip(*sims))
    q = lambda f: totals[min(len(totals) - 1, int(f * len(totals)))]

    print(f"  HYPOTHETICAL -- estimates of work not done; nothing here was spent")
    print(f"  critical path  {' -> '.join(longest)}")
    print(f"    te (sum of three-point)   {span:>10.0f} s")
    print(f"    50% done by               {q(.50):>10.0f} s")
    print(f"    99% done by               {q(.99):>10.0f} s")
    print(f"     1% done by               {q(.01):>10.0f} s")
    print()
    print(f"  {'':<4} {'task':<38} {'o':>8} {'m':>8} {'p':>8} {'te':>8} {'slack':>8}")
    for tid, t in sorted(tasks.items(), key=lambda x: (x[0] not in oncrit, x[0])):
        on = tid in oncrit
        slack = 0.0 if on else span - sum(tasks[i]["te"] for i in chains[tid])
        print(f"  {'path' if on else '':<4} {t['what'][:38]:<38} {t['o']:>8.0f} {t['m']:>8.0f} "
              f"{t['p']:>8.0f} {t['te']:>8.0f} {slack:>8.0f}")
    done = [v for v in _plan_tasks().values() if v["done"]]
    if done:
        print()
        for d in sorted(done, key=lambda x: x["done"]):
            print(f"  done {d['what'][:42]:<42} {d['done']}")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("build")
    r = sub.add_parser("report")
    r.add_argument("--since", type=int, default=90)
    r.add_argument("--by-project", action="store_true", help="one line per project, not per lane")
    sub.add_parser("path")
    sub.add_parser("verify")
    a = p.parse_args()
    if a.cmd == "build":
        n, files = build()
        print(f"booked {n} sessions into {files} project ledgers under {SPENT_DIR.relative_to(ROOT)}")
        return 0
    if a.cmd == "report":
        return report(a.since, a.by_project)
    if a.cmd == "path":
        return path()
    return 1 if verify() else 0


if __name__ == "__main__":
    sys.exit(main())
