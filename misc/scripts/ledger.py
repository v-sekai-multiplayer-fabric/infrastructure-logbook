#!/usr/bin/env python3
"""Fabric delivery: git history booked as double-entry seconds, checked by bean-check.

Ninety days of commits went 5.3% to the mesh being delivered and 27.2% to documents
about it, and nobody noticed because nothing counted. A ledger counts. Double entry is
the right shape for it: an hour cannot be spent without being booked against where it
came from, so the lane split falls out of the file instead of being argued.

Beancount is an operating-system tool here, the way gcc is. `brew install beancount`,
never vendored and never imported -- it is GPL-2.0, which this project's licence policy
files as restricted, so keeping it outside the tree is a licence decision as much as a
dependency one. What is tracked is the plain-text accounting file. This is the same
arrangement the memory store has with `usdcat`: the artefact is ours, the validator is the
system's, and the validator is what keeps a hand-written emitter honest.

  ledger.py build            git sessions -> ledger/spent.beancount
  ledger.py report [--since N] [--by-project]   the split, in seconds
  ledger.py path             the critical path, computed from ledger/planned.beancount
  ledger.py verify           bean-check, then regeneration must be byte-identical
"""
import argparse
import collections
import datetime
import math
import pathlib
import random
import subprocess
import sys

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
SPENT = ROOT / "ledger" / "spent.beancount"
SPENT_DIR = ROOT / "ledger" / "spent"
PLANNED = ROOT / "ledger" / "planned.beancount"
PLANNED_DIR = ROOT / "ledger" / "planned"


def _planned_text():
    """Every planned book's text, since the tasks live in the per-project files.

    The root holds what is common -- the budget, the deliverable, the includes -- and the
    tasks sit in the book of the repository each will be done in, matching ledger/spent/.
    Reading only the root found no tasks at all and `path` failed on an empty sequence,
    which is the right failure: a plan reader that silently reports no critical path
    because it looked in the wrong file is worse than one that stops.
    """
    return "\n".join(f.read_text(encoding="utf-8")
                      for f in sorted(PLANNED_DIR.glob("*.beancount")))

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
    """Seconds booked per calendar day, across every project's book."""
    d = collections.Counter()
    for day, _acct, secs in _postings():
        d[day] += secs
    return d


def overbooked_days():
    """Days that book more seconds than a day contains. Must always be empty."""
    return sorted((day, s) for day, s in day_totals().items() if s > SECONDS_IN_A_DAY)

# The deliverable. One at a time, and it changes only when the previous one is finished.
DELIVERABLE = ("A player draws a closed curve in VR, gets a mesh back, "
               "and the mesh is correct by a check that can fail")

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
OURS = {"ernest.lee@chibifire.com", "fire@users.noreply.github.com"}


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
            seen.append((str(g.parent.relative_to(ws)), g.parent))
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
    events = []
    for rel, path in _checkouts():
        out = subprocess.run(["git", "-C", str(path), "log", "--pretty=%ct\t%ae\t%s"],
                             capture_output=True, text=True).stdout.splitlines()
        for line in out:
            ct, _, rest = line.partition("\t")
            email, _, subj = rest.partition("\t")
            if email not in OURS:
                continue
            try:
                events.append((int(ct), rel, subj))
            except ValueError:
                pass
    events.sort()
    seconds = collections.Counter()
    steps = collections.defaultdict(list)
    # Every commit is recorded; only the intervals between them are charged. Walking pairs
    # alone dropped whichever commit sorted first, because it is never the later half of a
    # pair -- one commit missing out of 564, which is exactly the kind of error a lane total
    # absorbs without trace and a per-project book does not.
    prev = None
    for ct, rel, subj in events:
        day = datetime.datetime.utcfromtimestamp(ct).date().isoformat()
        steps[(day, rel)].append(subj)
        if prev is not None:
            gap = ct - prev
            if 0 < gap <= SESSION_GAP_H * 3600:
                seconds[(day, rel)] += float(gap)
        prev = ct
    for k in steps:
        seconds.setdefault(k, 0.0)
    return seconds, steps


def _cff(path):
    """A project's CITATION.cff as beancount metadata, with git filling the gaps.

    A book that says only "Patch-Verify" makes the reader open another repository to learn
    what it is, what licence it carries and where it lives. CFF already answers that in
    every repository that has one, so the book carries it: title and abstract for what the
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
    r = subprocess.run(["git", "-C", str(path), "remote", "-v"], capture_output=True, text=True)
    urls = {l.split()[1] for l in r.stdout.splitlines() if len(l.split()) >= 2}
    if len(urls) == 1 and "repository-code" not in meta:
        meta["repository-code"] = urls.pop().removesuffix(".git")
    first = subprocess.run(["git", "-C", str(path), "log", "--reverse", "--pretty=%cs",
                            "--max-parents=0"], capture_output=True, text=True).stdout.split()
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
                            "--", "CITATION.cff"], capture_output=True, text=True).stdout.split()
        if len(r) == 2:
            meta["cff-copied"], meta["cff-commit"] = r
    return meta


def _account(rel):
    """One book per project, hanging off the lane it belongs to.

    A lane on its own is four totals, and a total absorbs an error silently -- the dropped
    commit above sat inside one for a day. Beancount accounts are hierarchical, so a leaf
    per project gives both: `bean-query` still rolls Expenses:Delivery:Mesh up for the gate,
    and every project's own seconds are auditable against `git log` on their own line.

    Account components must start with an uppercase letter, so a path becomes Title-Case
    and keeps its hyphens: 2-contract/patch-verify is Patch-Verify under 2-Contract.
    """
    lane = LANES.get(rel, DEFAULT_LANE)
    leaf = rel.split("/")[-1] if rel not in (".", ".repo/manifests") else "Fabric"
    leaf = "-".join(w[:1].upper() + w[1:] for w in leaf.split("-") if w)
    return f"{lane}:{leaf}" if leaf else lane


def _escape(s):
    """Beancount narration is a double-quoted string, so a quote in a subject ends it."""
    return s.replace("\\", "").replace('"', "'")


def build():
    """One beancount file per project, and a root that includes them.

    A single file put every project's seconds in one place, so a change to one project
    rewrote lines belonging to forty-three others and a diff said nothing about which
    project moved. Beancount's `include` gives the split for free: bean-check reads the
    root and validates the whole set, while each project's history is its own file with
    its own git blame.

    The root holds what is common -- the options, the counter-account and the includes --
    and each project file opens only its own account. Nothing is duplicated between them.
    """
    seconds, steps = _allocate()
    paths = {rel: path for rel, path in _checkouts()}
    entries = sorted((day, rel, _account(rel), seconds.get((day, rel), 0.0),
                      len(steps[(day, rel)]), steps[(day, rel)])
                     for (day, rel) in steps)
    first = entries[0][0] if entries else datetime.date.today().isoformat()
    today = datetime.date.today().isoformat()

    header = [
        ";; Generated by misc/scripts/ledger.py -- do not edit.",
        ";;",
        ";; SPENT. Every hour below went somewhere; nothing here is an estimate. The",
        ";; estimates are in planned.beancount, booked as liabilities, and the two share",
        ";; no account so that a plan can never read as progress.",
        ";;",
        ";; Time is allocated, not summed. There is one pool -- every interval between",
        ";; consecutive commits anywhere in the workspace -- and each interval is charged",
        ";; to the repository whose commit closed it. That makes the charge a partition, so",
        ";; a day totals the union of the active spans rather than the sum of overlapping",
        ";; ones. Adding each repository's own sessions charged 2026-08-16 with 40.04 h,",
        ";; which no day contains; allocated, the same day costs 30,312 s.",
        ";;",
        ";; An interval over four hours is somebody going away rather than working slowly,",
        ";; and is charged to nobody, so a session's first commit books no time. The ledger",
        ";; cannot see the work before it either: this is a lower bound on effort.",
        ";;",
        ";; Seconds are booked by author, not by repository. A fork holds upstream's commits",
        ";; and ours, and skipping the whole checkout skipped both.",
        "",
    ]

    by_project = collections.defaultdict(list)
    for e in entries:
        by_project[e[1]].append(e)

    SPENT_DIR.mkdir(parents=True, exist_ok=True)
    written, includes = 0, []
    for rel, rows in sorted(by_project.items()):
        acct = _account(rel)
        name = acct.rsplit(":", 1)[-1] + ".beancount"
        lines = [f";; {rel} -- generated by misc/scripts/ledger.py, do not edit.",
                 ";; The open directive carries this project's CITATION.cff, so the book says",
                 ";; what the work was and what may be done with it without opening the repo.",
                 "", f"{first} open {acct}  SECONDS"]
        for k, v in sorted(_cff(paths[rel]).items()):
            if k in ("date-released", "first-commit"):
                lines.append(f"  {k}: {v}")
            else:
                lines.append(f'  {k}: "{_escape(str(v))[:220]}"')
        lines.append("")
        for day, _rel, account, secs, n, subjects in rows:
            lines.append(f'{day} * "{_escape(rel)}" "{_escape(subjects[-1])[:88]}"')
            lines.append("  spent: TRUE")
            lines.append(f"  commits: {n}")
            steps_s = " | ".join(_escape(s)[:72] for s in subjects)
            lines.append(f'  steps: "{steps_s[:900]}"')
            lines.append(f"  {account:<34} {secs:11.0f} SECONDS")
            lines.append("  Income:Sessions")
            lines.append("")
        (SPENT_DIR / name).write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
        includes.append(f'include "spent/{name}"')
        written += 1

    root = header + [
        'option "title" "fabric-spent: seconds booked from git sessions"',
        'option "operating_currency" "SECONDS"',
        "",
        f"{first} open Income:Sessions  SECONDS",
        "",
        f'{today} event "deliverable" "{_escape(DELIVERABLE)}"',
        "",
    ] + sorted(includes)
    SPENT.write_text("\n".join(root).rstrip() + "\n", encoding="utf-8")
    # Files that no longer correspond to a project would keep being included by hand and
    # validated forever; a generated tree must be able to shrink.
    keep = {i.split('"')[1].split("/")[-1] for i in includes}
    for f in SPENT_DIR.glob("*.beancount"):
        if f.name not in keep:
            f.unlink()
    return len(entries), written


def _postings(since_days=None):
    """(date, account, seconds) for every expense posting, read back from the file.

    Read back rather than recomputed, so `report` and the delivery gate answer from the
    artefact that is committed. A number produced by the generator and never read from
    the file would prove the generator agrees with itself.
    """
    cutoff = None
    if since_days is not None:
        cutoff = datetime.date.today() - datetime.timedelta(days=since_days)
    out, day = [], None
    lines = []
    for f in sorted(SPENT_DIR.glob("*.beancount")):
        lines += f.read_text(encoding="utf-8").splitlines()
    for line in lines:
        head = line[:10]
        if len(line) > 11 and line[4] == "-" and line[7] == "-" and " * " in line:
            try:
                day = datetime.date.fromisoformat(head)
            except ValueError:
                day = None
        elif line.startswith("  Expenses:") and day is not None:
            acct, _, amt = line.strip().partition(" ")
            secs = float(amt.replace("SECONDS", "").strip())
            if cutoff is None or day >= cutoff:
                out.append((day, acct, secs))
    return out


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
    print(f"  SPENT -- {since_days} days, from {SPENT.relative_to(ROOT)}")
    for acct, secs in sorted(tot.items(), key=lambda x: -x[1]):
        print(f"    {acct:<34} {secs:11.0f} s  {secs / total * 100:5.1f}%")
    print(f"    {'TOTAL':<34} {total:11.0f} s")
    return 0


def delivery_seconds(window_days=30):
    """Seconds booked to the mesh in the trailing window. What the build asks about."""
    return sum(s for _, a, s in _postings(window_days) if a.startswith("Expenses:Delivery"))


def verify():
    bad = 0
    for f in (SPENT, PLANNED):
        # One file per invocation: bean-check takes a single FILENAME and rejects a second
        # as an extra argument, which reads like a ledger error and is not one.
        r = subprocess.run(["bean-check", str(f)], capture_output=True, text=True)
        if r.returncode != 0:
            print(f"  bean-check rejects {f.name}:")
            for line in (r.stderr or r.stdout).strip().splitlines()[:4]:
                print(f"    {line}")
            bad += 1
        else:
            print(f"  bean-check ok  {f.name}")
    over = overbooked_days()
    for day, s in over[:5]:
        print(f"  {day} books {s:.0f} s, and a day holds {SECONDS_IN_A_DAY}")
    bad += len(over)

    before = {f.name: f.read_text(encoding="utf-8") for f in sorted(SPENT_DIR.glob("*.beancount"))}
    before[SPENT.name] = SPENT.read_text(encoding="utf-8")
    build()
    after = {f.name: f.read_text(encoding="utf-8") for f in sorted(SPENT_DIR.glob("*.beancount"))}
    after[SPENT.name] = SPENT.read_text(encoding="utf-8")
    if before != after:
        print("  the ledger is not what git says; it was hand-edited")
        bad += 1
    else:
        print("  regenerates byte-identical")
    print("SPENT VERIFY PASS" if bad == 0 else f"{bad} problem(s)")
    return bad


def _plan_tasks():
    """The planned tasks, read out of the plan ledger's transaction metadata.

    The plan is a beancount file rather than a diagram because a diagram goes stale and
    nothing notices. Here a task is a transaction, its three-point estimate is metadata,
    and the path below is computed rather than drawn -- so an estimate cannot disagree
    with the picture of it, which is how 231/234 outlived the code that reached 1360/1360.
    """
    tasks, cur = {}, None
    for line in _planned_text().splitlines():
        s = line.strip()
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
    # The narration carries what the task is; re-read to attach it to the id below it.
    narr = None
    for line in _planned_text().splitlines():
        s = line.strip()
        if s.startswith("2") and '"plan"' in s:
            narr = s.split('"plan"')[1].strip().strip('"')
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
    beancount entries the only source and this function a reader of them.
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
