// Fit meanfield.js's lambdaScale on the full model that gets scored (prior + reports included), so the mean
// P(ever infected) over the train agents equals their observed attack rate. Used by kl_fixed.mjs and
// kl_frankenstein.mjs ("meanfield_fit" mode).
//
// Why: meanfield-cli.mjs --calibrate fits lambdaScale from the true seeds with no reports. Adding the reports for
// scoring then over-predicts ~5x on the 7,500-agent runs (a report pins P = 1 and reaches back to raise contacts,
// on top of the spread the seeds already explain), so the fit has to see the reports too.
//
// Each pass with reports takes ~20 min on a 7,500-agent run, so this uses the Illinois method (regula falsi that
// halves a stuck end's weight) on f(log lambda) = log(mean P_train) - log(target) instead of bisection: ~3-5 passes.
// Known points (lambda, mean P_train) from earlier runs can be passed in to save passes.

export function fitWithReports({ meanFieldRisk, input, params = {}, trainIdx, target, lo, hi, known = [], maxPasses = 5, tol = 0.02, log = console.log }) {
  const prep = {};
  const seen = new Map(known.map(([s, m]) => [s, { m, risk: null }]));
  const meanTrain = (risk) => { let s = 0; for (const i of trainIdx) s += 1 - risk.sFinal[i]; return s / trainIdx.length; };
  let passes = 0;
  const evalAt = (s) => {
    if (seen.has(s)) return seen.get(s).m;
    const t0 = Date.now(), risk = meanFieldRisk({ ...input, prep }, { ...params, lambdaScale: s }), m = meanTrain(risk);
    passes++;
    log(`pass ${passes}: lambdaScale ${s.toFixed(5)} mean P(train) ${m.toFixed(4)} (target ${target.toFixed(4)}), expected infections ${risk.expectedInfections.toFixed(1)}, ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    seen.set(s, { m, risk });
    return m;
  };
  const f = (s) => Math.log(evalAt(s)) - Math.log(target);
  let a = Math.log(lo), b = Math.log(hi), fa = f(lo), fb = f(hi), side = 0;
  if (fa > 0 || fb < 0) log(`warning: target not bracketed (f(lo) ${fa.toFixed(3)}, f(hi) ${fb.toFixed(3)}); keeping the closest point`);
  else {
    while (passes < maxPasses && Math.min(Math.abs(fa), Math.abs(fb)) > Math.log1p(tol)) {
      const c = (a * fb - b * fa) / (fb - fa), fc = f(Math.exp(c));
      if (fc > 0) { b = c; fb = fc; if (side === -1) fa /= 2; side = -1; } else { a = c; fa = fc; if (side === 1) fb /= 2; side = 1; }
    }
  }
  // Best evaluated point with a model result in hand (known points have none; rerun the best one if needed).
  let best = null;
  for (const [s, v] of seen) if (!best || Math.abs(Math.log(v.m / target)) < Math.abs(Math.log(best.m / target))) best = { s, ...v };
  if (!best.risk) { log(`rerunning best known point ${best.s}`); seen.delete(best.s); evalAt(best.s); best.risk = seen.get(best.s).risk; }
  log(`fitted lambdaScale ${best.s.toFixed(5)}: mean P(train) ${best.m.toFixed(4)} vs target ${target.toFixed(4)} after ${passes} passes`);
  return { scale: best.s, risk: best.risk, meanTrain: best.m, passes };
}
