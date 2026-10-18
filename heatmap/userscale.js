// The user map's counting rules, shared by tools/precompute.mjs (node) and app.js (browser) so the presenter's
// "What users see" and FlUni's bundle can't drift apart.
//
// Runs are scaled to a ~7,000-person campus: under 500 agents each counts as 50; up to 5,000 agents each counts
// as 7,000 / n (x7 at 1,000), so buildings clear MIN_PEOPLE; full runs count as themselves.
export const MIN_PEOPLE = 4; // buildings with fewer people (after scaling) are hidden
export const userScale = (nAgents) => (nAgents < 500 ? 50 : nAgents < 5000 ? Math.round(7000 / nAgents) : 1);
