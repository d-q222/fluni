# Published behavior rates for validating the sim

These are reference rates for checking simulated student behavior. The data is in `sim/configs/published_rates.json`: 41 entries, keyed by `id`, with exact page, table or quote locations in `notes`.

Rules followed:
- Every number was read in the source. That means the full text, an abstract on PubMed Central (PMC) or Europe PMC, or a report PDF.
- Nothing was estimated. A few summary ratios in the notes are labelled as derived.
- `rate` is `null` when the finding is an effect size or direction rather than a proportion.
- `tolerance` is a suggested ± band. It is wider when the population is less like Stanford undergrads, the sample is small, or the figure is a stated intention.

Some caveats apply throughout:
- **Self-report.** Almost everything is self-reported. Observed behavior (masking) and stated intention (Van 2010, Smith 2021) differ a lot.
- **Era.** COVID-era numbers come from a world with legal or strongly enforced isolation rules. Flu-era (2009 H1N1) numbers come from a mild pandemic with weak norms. FlUni (flu plus an app) sits between the two.
- **Comparability.** No source is Stanford-specific. The closest are other US campuses: Delaware, George Washington University, the University of Arizona, Harvard, and the six CDC-observed universities.

## Summary table

| behavior | context | rate | population | source |
|---|---|---|---|---|
| sick_response | stay_home | 0.064 | Univ. of Delaware students with ARI, 2009 H1N1 | Mitchell et al., 2011, Clin Infect Dis |
| sick_response | carry_on_social_events | 0.447 | Same (attended social events while ill) | Mitchell et al., 2011, Clin Infect Dis |
| sick_response | vaden | 0.386 | GWU students with ILI, Nov 2009 | Katz et al., 2012, J Am Coll Health |
| sick_response | carry_on (missed no class/work) | 0.33 (Table 4: 0.355) | GWU students, single ILI episode | Katz et al., 2012, J Am Coll Health |
| sick_response | vaden | 0.427 (0.374–0.481) | US adults 18–49 with ILI, BRFSS 2011 | Biggerstaff et al., 2014, J Infect Dis |
| sick_response | carry_on (intent) | 0.217 | UNSW students, would attend with flu symptoms | Van et al., 2010, BMC Public Health |
| sick_response | carry_on_exam_due (intent) | 0.665 | UNSW students, flu symptoms + exam due | Van et al., 2010, BMC Public Health |
| sick_response | stay_home (full isolation) | 0.425 (0.397–0.452) | UK 16+, COVID symptoms | Smith et al., 2021, BMJ |
| sick_response | vaden (requested test) | 0.180 (0.166–0.193) | UK 16+, COVID symptoms | Smith et al., 2021, BMJ |
| quarantine_request | stay_home_when_advised | 0.897 (at least partially) | GWU students with ILI told to stay home | Katz et al., 2012, J Am Coll Health |
| quarantine_request | isolate_until | 0.42 (0.37–0.48) | Norway adults asked to quarantine/isolate | Steens et al., 2020, Eurosurveillance |
| quarantine_request | isolate_until_symptomatic | 0.71 | Same, with symptoms | Steens et al., 2020, Eurosurveillance |
| quarantine_request | isolate_until_asymptomatic | 0.28 | Same, without symptoms | Steens et al., 2020, Eurosurveillance |
| app_compliance | go_to_vaden (tested) | 0.575 | WA Notify recipients, follow-up survey | Baseman et al., 2022, Public Health Rep |
| app_compliance | isolate_until (home until result) | 0.391 | WA Notify recipients | Baseman et al., 2022, Public Health Rep |
| app_compliance | isolate_until | 0.40 | Dutch CoronaMelder recipients | Ebbers, 2021, Erasmus Univ. evaluation report |
| app_compliance | go_to_vaden | 0.41 (lower bound) | Dutch CoronaMelder recipients | Ebbers, 2021, Erasmus Univ. evaluation report |
| app_compliance | go_to_vaden | 0.667 (n=18) | Zurich contacts, SwissCovid alert before manual tracing | Ballouz et al., 2022, JMIR Public Health Surveill |
| app_compliance | any_recommended_action | 0.76 | SwissCovid recipients (review) | Daniore et al., 2021, Swiss Med Wkly |
| app_compliance | leave_location | null (no significant change in contact time) | US university app users, 2021 | Citron et al., 2024, Research Square preprint |
| disclosure | share_positive_in_app | 0.55 | Univ. of Arizona positives who had the app | Masel et al., 2021, medRxiv preprint |
| disclosure | share_positive_in_app | 0.89 (n=35) | Dutch CoronaMelder positives | Ebbers, 2021, Erasmus Univ. evaluation report |
| disclosure | conceal_symptoms_screening | 0.204 | US adults, clinic entry screening | Levy et al., 2022, JAMA Netw Open |
| disclosure | avoid_testing_when_suspected | 0.21 | US adults | Levy et al., 2022, JAMA Netw Open |
| disclosure | break_quarantine | 0.225 | US adults told to quarantine | Levy et al., 2022, JAMA Netw Open |
| disclosure | name_contacts | 0.33 | All US COVID cases at 14 health depts, 2020 | Lash et al., 2021, JAMA Netw Open |
| disclosure | share_contacts_intent | 0.791 (0.788–0.795) | UK 16+ | Smith et al., 2021, BMJ |
| disclosure | tell_sick_professor | 0.5 ("half" did not) | GWU students with ILI | Katz et al., 2012, J Am Coll Health |
| influence | peer_effect_health_behavior | null (+8.3 pp per +10% of friends vaccinated) | Harvard undergrads | Rao et al., 2007, FRB Boston WP 07-12 |
| influence | warn | 0.28 | Dutch CoronaMelder recipients warned others | Ebbers, 2021, Erasmus Univ. evaluation report |
| influence | risk_perception_after_contact_infected | null (significant predictor) | 10 countries, Mar 2020 | Dryhurst et al., 2020, J Risk Res |
| worry | worry_peak | 0.329 (range 0.096–0.329) | UK 16+, 36 weekly surveys, 2009 H1N1 | Rubin et al., 2010, Health Technol Assess |
| worry | anxiety_early | 0.61 | Dutch adults, May 2009 | Bults et al., 2011, BMC Public Health |
| worry | anxiety_6wk | 0.40 | Dutch adults, June 2009 (Aug: 0.39/0.36) | Bults et al., 2011, BMC Public Health |
| worry | risk_perception_decline | null (d ≈ −0.2 to −0.7) | Italian young adults (mean age 26) | Savadori & Lauriola, 2022, Soc Sci Med |
| worry | protective_behavior_decay | null (distancing declines; masking rises) | 14 countries, 2020 | Petherick et al., 2021, Nat Hum Behav |
| masking | indoor_mandate | 0.940 | Observed, 6 US universities with mandates | Barrios et al., 2021, MMWR |
| masking | outdoor_mandate_conditional | 0.676 | Same, outdoors | Barrios et al., 2021, MMWR |
| masking | campus_mandate | 0.86 (off campus 0.72) | Observed, East Tennessee State Univ. | Condra et al., 2023, J Community Health |
| masking | symptomatic_no_mandate | null (3.1–5.9% across subgroups) | GWU students with ILI, 2009 | Katz et al., 2012, J Am Coll Health |
| masking | symptomatic_intent | 0.31 ("very willing") | UNSW students | Van et al., 2010, BMC Public Health |

## How well each behavior compares to Stanford undergrads

**sick_response.** This is the strongest student evidence. It comes from three 2009 campus surveys (Delaware, GWU, UNSW). Students with flu-like illness rarely stayed home fully (6.4% at Delaware), and nearly half went to social events. About 39% sought care at GWU, which is close to the general rate for 18–49-year-olds (43%). Stanford's Vaden is free and nearby, so care seeking could be somewhat higher. COVID-era figures (Smith 2021) show more isolation (42.5%) under much stronger norms; treat them as an upper reference for a "high-alert" scenario. An exam or deadline sharply raises stated intent to attend while sick (21.7% → 66.5%). This intent data is the only quantitative check on academic pressure.

**quarantine_request.** When students were told to stay home, about 90% complied at least partially (GWU). Norway shows that adherence to a formal request depends strongly on symptoms: 71% with symptoms versus 28% without. This is the best available "severity" modifier.

**app_compliance.** No study reports compliance with a university app. The evidence comes from national apps (WA Notify, CoronaMelder, SwissCovid). These consistently show that about 40% of recipients quarantine or stay home and 40–58% get tested. The University of Arizona campus study (Citron 2024 preprint) found no measurable drop in contact time after a notification. This suggests notified students may not actually leave or avoid locations; only positives cut contact, by about 29%. Young people complied less in several sources (Smith 2021; CoronaMelder p.17). Tolerances are ±0.15 to ±0.20.

**disclosure.** The Arizona campus figure (55% of infected app users shared their result in the app) is the most comparable. Concealment data comes from US adults (Levy 2022): about 20% each for hiding symptoms at screening, avoiding testing, and breaking quarantine. Ages 18–29 had about 4.9 times the odds of at least one such behavior, so expect higher concealment among students. Disclosure to friends specifically has no good number. The closest are 28% of CoronaMelder recipients warning others, and half of GWU students with ILI not notifying professors.

**influence.** Rao 2007 gives a causal peer effect among Harvard undergraduates, an elite residential campus very similar to Stanford. It covers vaccination, not testing or isolation: up to +8.3 percentage points per +10% of friends vaccinated. Dryhurst 2020 supports the direction (friends and family raise risk perception) but gives no rate.

**worry.** Flu-pandemic worry was low and volatile: 10–33% "very/fairly worried" in the UK. Dutch anxiety dropped by about a third within 6 weeks (61% → 40%), then plateaued at 36–39%. Young-adult risk perception and distancing declined after the COVID peak, while cheap habits (hygiene, masks) persisted or rose (Savadori 2022; Petherick 2021). No source gives a half-life; validate the shape (fast early drop, then plateau) rather than a decay constant.

**masking.** Direct observation on US campuses under mandates gives high indoor masking (94%) and lower outdoor masking (68%). A campus with a weaker surrounding norm showed 86% on campus versus 72% off campus. Without a mandate in 2009, symptomatic students almost never masked (3–6%), even though 31% said they were "very willing." Stanford flu-season masking without a mandate should be near the 2009 figures, not the COVID figures.

## Gaps (no good published source found)

- **Severity gradient for flu sick behavior in students.** Nothing measures stay-home or care-seeking by fever or severity level. The only proxy is symptomatic versus asymptomatic adherence in Norway (Steens 2020).
- **Masking after an app notification** (`app_compliance/wear_mask`). CoronaMelder asked about advice adherence, but the results are only in a figure. No transcribable rate was found.
- **Leaving a location after a notification** (`leave_location`). Only the null contact-time result (Citron 2024 preprint) exists. There is no proportion.
- **Telling friends or close contacts that you are sick or positive** (`influence/tell_sick`). No direct rate exists. Proxies are CoronaMelder's 28% warned others, Lash's 33% named contacts to tracers, and in-app sharing.
- **Peer influence on testing or isolation after a friend's warning or diagnosis.** No quantitative estimate exists; the only causal peer effect found is for flu vaccination (Rao 2007).
- **Peer effects on going to social events while sick.** No source found.
- **Honesty of symptom self-reports on campus daily screeners.** No student-specific prevalence; only general-adult data (Levy 2022).
- **Decay half-life of worry or protective behavior.** Only direction and shape are documented (Bults 2011; Petherick 2021; Savadori 2022).
- **University app compliance** (quarantine or testing after a campus app alert). The Clemson Safer Together study has a protocol only; no results were found.
- **Inviting others** (`influence/invite`). No source found.

## Source access notes

- Abstracts marked `europepmc.org/abstract/MED/...` were read through the Europe PMC REST API.
- The CoronaMelder report (`eur.nl/media/94469`) is in Dutch. It was read from the PDF text, and page numbers are the report's printed page numbers.
- The Dryhurst 2020 publisher page returned HTTP 403, so its abstract was read through OpenAlex.
- Two sources are preprints and one is a working paper: Masel 2021 (medRxiv), Citron 2024 (Research Square) and Rao 2007 (FRB Boston WP).
- The full text of Mitchell 2011 and Nichol 2008 was not available. Nichol 2008 was left out because its abstract has no ILI-specific rate of missed class or care seeking.
