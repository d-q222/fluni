// The user map's counting rules, shared by tools/precompute.mjs (node) and app.js (browser) so the presenter's
// "What users see" and FlUni's bundle can't drift apart.
//
// Tiny sample runs (under 500 agents) count each agent as 50 so buildings clear MIN_PEOPLE; from 500 agents on,
// agents count as themselves (the product owner: no x7 scaling; the counts must be the sim's own).
export const MIN_PEOPLE = 4; // buildings with fewer people (after scaling) are hidden
export const userScale = (nAgents) => (nAgents < 500 ? 50 : 1);
