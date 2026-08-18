# What the two-budget ratchet actually catches, and how often it cries wolf

**Date:** 2026-08-17. **Subject:** `7-service/see-through`, `seconds/ratchet.py`.

`seconds/ratchet.py` gates the release ladder on two budgets that may only go down. It has
29 passing proofs in `proof/`, and all of them ask *behavioural* questions — does a
regression fail, does an equivocal run leave the floor alone — on hand-picked numbers. None
asks the *statistical* question, which is the one a gate in CI lives or dies by: **how often
does it go red when nothing is wrong?**

The answer is about one run in twelve, which is roughly twice what the module's own prose
implies.

## Hypotheses

Each is the module's own claim, quoted from its docstrings.

| | claim | source |
|---|---|---|
| H1 | `Z = 2.0` is "about 95% one-sided", so the null failure rate is ~2.3% | `Z` comment |
| H2 | "a min-of-one ratchet fails on noise and then gets ignored" | module docstring |
| H3 | "the evidence to lower the floor is the evidence to fail against it, so the gate cannot be easier to please than to trip" | `Z` comment |
| H4 | `MIN_SAMPLES = 5` is enough to move or fail the gate | `MIN_SAMPLES` comment |

## Apparatus

`ratchet.compare` imported directly — the function the gate actually calls, not a
reimplementation of it. Durations drawn lognormally, which is the same assumption
`_log_stats` makes and the reason it works in log space.

    base           171.26 s     the one real datum, seconds.json working.run.seconds
    sigma          0.02 0.05 0.10 0.20      log-space spread, ~2% to ~20% CV
    n              5 10 20      candidate and baseline sample sizes
    ratio          1.0 ... 2.0  how much slower the candidate really is
    trials         20 000 per cell
    seed           20260818     fixed; the whole run reproduces
    wall           4 m 09 s

`sigma` is the one number here that is **not** measured. The endpoint was torn down on
2026-08-17 and both budget floors are empty, so the real spread of a see-through
decomposition is unknown and the range is a bracket around plausible values — a warm worker
is tight, a cold start is not. Every conclusion below is conditional on it.

Script: `scratchpad/ratchet_calibration.py` (not committed; it is 90 lines and reproduces
from the parameters above).

## Result 1 — H1 is refuted at the sample size the gate actually uses

P(gate says "worse") when baseline and candidate are drawn from the *same* distribution:

| sigma | n=5 | n=10 | n=20 |
|---|---|---|---|
| 0.02 | 0.0427 | 0.0296 | 0.0262 |
| 0.05 | 0.0389 | 0.0271 | 0.0295 |
| 0.10 | 0.0430 | 0.0305 | 0.0263 |
| 0.20 | 0.0391 | 0.0310 | 0.0249 |

Nominal is 0.023. At `MIN_SAMPLES=5` the measured rate is **0.039–0.043**, about **1.8x**
the claim; it converges toward nominal as n grows, reaching ~0.026 by n=20. The rate is
flat in sigma, which is the signature of the cause: `compare` divides by a standard error
built from standard deviations *estimated from the samples*, then compares to a fixed 2.0 as
though sigma were known. At n=5 that statistic has visibly heavier tails than the normal the
threshold assumes. It is the textbook z-versus-t error, and it costs a factor of about two
at the sample size the module recommends.

**What it means in CI.** The ladder checks two budgets independently, so a clean run goes red
with probability 1-(1-0.041)^2 ~ **0.080** — about **one run in twelve**, for no reason at
all. That is comfortably inside the range where a gate gets a reputation and then gets
switched off, which is the exact failure `ratchet.py` was written to avoid.

## Result 2 — H2 is confirmed, and understated

The same null, judged by the min-of-one rule the module warns about:

| sigma | n=5 | n=10 | n=20 |
|---|---|---|---|
| 0.02 | 0.4991 | 0.5046 | 0.4961 |
| 0.05 | 0.5030 | 0.5034 | 0.4973 |
| 0.10 | 0.5017 | 0.4968 | 0.5038 |
| 0.20 | 0.4993 | 0.5034 | 0.4993 |

Exactly the coin flip symmetry predicts, at every spread and every n: **12x to 20x** the z
gate's rate. "Fails on noise" is correct and generous. Note it does not improve with more
samples — it cannot, because the minimum of a larger sample is not a better estimate of
anything, it is just a more extreme order statistic.

## Result 3 — H3 is confirmed

P(better) against P(worse) under the null, at n=5: 0.0396/0.0427, 0.0382/0.0389,
0.0417/0.0430, 0.0416/0.0391. Equal within Monte-Carlo error (+-0.0014 at 20 000 trials)
in all twelve cells. The gate is exactly as hard to please as it is to trip, which is what
the symmetric threshold was for. This one needs no caveat.

## Result 4 — H4 depends entirely on the unmeasured number

Power: P(gate says "worse") when the candidate really is slower.

| sigma | n | x1.05 | x1.10 | x1.25 | x1.50 | x2.00 |
|---|---|---|---|---|---|---|
| 0.02 | 5 | 0.957 | 1.000 | 1.000 | 1.000 | 1.000 |
| 0.05 | 5 | 0.358 | 0.835 | 1.000 | 1.000 | 1.000 |
| 0.10 | 5 | 0.144 | 0.348 | 0.926 | 1.000 | 1.000 |
| 0.20 | 5 | 0.080 | 0.143 | 0.446 | 0.870 | 0.999 |

Smallest real regression caught 80% of the time, bisected:

| sigma | n=5 | n=10 | n=20 |
|---|---|---|---|
| 0.02 | 1.037 (6.3 s) | 1.026 (4.4 s) | 1.018 (3.1 s) |
| 0.05 | 1.095 (16.3 s) | 1.067 (11.4 s) | 1.046 (7.8 s) |
| 0.10 | 1.198 (34.0 s) | 1.138 (23.6 s) | 1.093 (16.0 s) |
| 0.20 | 1.434 (74.2 s) | 1.292 (50.0 s) | 1.199 (34.1 s) |

So five samples is plenty or nearly useless depending on a number nobody has measured yet.
If a decomposition is reproducible to ~2%, five runs catch a 6-second regression — about the
time it takes to read this paragraph. If it varies by ~20%, five runs cannot see anything
smaller than **74 seconds on a 171-second job**, and a regression that nearly doubles the
latency would still slip through one time in eight.

## Conclusions

1. **H1 refuted**, H2 confirmed and understated, **H3 confirmed**, H4 conditional.
2. The first thing worth measuring on the rebuilt endpoint is not a floor, it is **sigma** —
   because it decides whether `MIN_SAMPLES = 5` is generous or useless, and nothing else in
   this file can be settled without it.
3. The z-versus-t gap is worth fixing whichever way sigma lands, and it is cheap: comparing
   against a t critical value at the Welch degrees of freedom, or simply raising the constant
   at small n, brings the null rate back to what the comment already promises. No change is
   proposed here — this entry measures, and the fix is a decision.

## Threats to validity

- **Lognormality is assumed, not observed.** It is the module's own assumption and the right
  family for durations, but the real distribution may be bimodal — cold start against warm —
  and a bimodal sample breaks the single-sigma model these numbers rest on.
- **Baseline and candidate are drawn with the same sigma.** A change that alters the
  *variance* rather than the mean is outside every cell above.
- **The floors are empty**, so none of this is live yet. `check` returns `"first"` for an
  empty budget and sets the floor without judging it, so the calibration only starts to
  matter on the second measurement ever taken.

## One loose thread in the recorded run

`seconds.json` records the working run as 171.26 s, with denoising at "30 steps at about
1.57 s/step". That is 47.1 s, leaving ~124 s of the 171 s unattributed. The note says 171.26
is "the program's own number for the final stage", so the two may simply count different
things — but which 124 seconds those are is not answerable from what is written down, and it
is the difference between a job that is 27% denoising and one that is dominated by it. Worth
resolving before anyone optimises against the wrong stage.
