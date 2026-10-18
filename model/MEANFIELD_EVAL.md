# Mean-field evaluation log

`node model/meanfield-eval.mjs <run>` scores P(ever infected by the end of day d) against the sim's infections:
**KL** = KL(y ‖ p) per person in nats, which for a 0/1 label is the log loss, and **AUC**. "Oracle const" is the
best constant guess (that day's true share infected), which no model can know in advance.

Runs: the twelve 1,000-agent, 14-day runs. The nine training runs (`689ae9f0` = the fixed 1k, `f4bf301c`, `a986df0a`,
`22a44427`, `9214956b`, `f4573d76`, `2329d271`, `291f8efd`, `14859125`) commit only five files, so they were rerun from
their own `config.json` params (`sim/simulate.py --config <params.json> --set output.by_agent=false`; `infections.csv`
byte-identical) to get `reports_tests.csv` and `map/`. Plus `25fe957a`, `183f262b`, `f12e71fa`. 5–79% infected,
transmission scale 1.2–4.0, 5–50 initial cases. Contacts: `uv run model/tools/contacts_cache.py <run>`.

Means over the 12 runs (per-run numbers in the commit messages):

| Version | mean KL | final-day KL | mean AUC | final AUC | \|expected − actual\| / actual |
|---|---|---|---|---|---|
| oracle constant | 0.3426 | | | | |
| before: prior = seed count / N (from the sim's config), lambdaScale 0.901 | 0.3331 | 0.5014 | 0.670 | 0.751 | 0.46 |
| 1: self-calibrated online from reports (prior, lambdaScale), mass-rescaled, `priorAge=new` | 0.3243 | 0.4438 | 0.654 | 0.752 | 0.13 |

## Iterations after the first full run (each tested on a randomly chosen run, against the previous version there)

| # | Change | Test run | mean KL before → after | final AUC before → after |
|---|---|---|---|---|
| 2 | "recovered" ends an infection without asserting one (keeps P_S; `recoveredCertain` restores the SI's P_R = 1); likelihood ratios 60 / 20 (were 20 / 4) | `689ae9f0` (fixed 1k) | 0.1345 → 0.1038 (oracle const 0.1164) | 0.710 → 0.691 |
| 3 | negative test as a likelihood (infected mass × 0.3, the sim test's miss rate); `negFnr: 0` restores the SI's P_S = 1 | `25fe957a` | 0.3295 → 0.3228 (oracle const 0.3812) | 0.717 → 0.739 |
| 4 | `test_taken` as evidence (likelihood ratio 200; app-visible per the sim's app policy; all 616 tests in the runs were taken by infected people); a second kind of evidence about one illness updates the posterior on its first dating | `25fe957a` | 0.3229 → 0.3189 | 0.739 → 0.750 |
| 5 | a positive drops that person's earlier report clamps from its dating on (a symptom report just before a positive no longer lowers its P_I = 1; paper re-check issue 1) | `22a44427` | 0.1553 → 0.1546 (oracle const 0.1601) | 0.760 → 0.761 |
