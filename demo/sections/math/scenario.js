// A staged ten-person story for the math section, run through the real model (model/infer.js).
// Pure data + functions, no DOM, so it also runs in Node (see the checks in math.js's header).
import { inferRisk, doseModel, DEFAULTS } from '../../../model/infer.js';

export const STEP_MIN = 5;
export const START_MS = Date.UTC(2026, 0, 12, 8, 0); // Mon 12 Jan 2026, 08:00 (campus in January)
const MIN = 60000, HOUR = 60 * MIN, DAY = 24 * HOUR;
const at = (day, hh, mm = 0) => START_MS + day * DAY + ((hh - 8) * 60 + mm) * MIN;
export const REPORT_MS = at(2, 9);   // Wed 09:00: every report and test in the story happens here
export const END_MS = at(2, 22);     // Wed 22:00
export const TIMELINE_END_MS = at(3, 8);

// Rows shaped like sim/runs/*/map/rooms.csv (volumes and ventilation as the sim's procedural rooms).
export const ROOMS = new Map([
  ['dorm', { label: 'dorm room', volume_m3: 101.7, ventilation_ach: 2, room_type: 'dorm_quad' }],
  ['study', { label: 'study room', volume_m3: 150, ventilation_ach: 3, room_type: 'study' }],
  ['class', { label: 'classroom', volume_m3: 300, ventilation_ach: 4, room_type: 'classroom' }],
  ['dining', { label: 'dining hall', volume_m3: 900, ventilation_ach: 4, room_type: 'dining' }],
  ['lounge', { label: 'lounge', volume_m3: 360, ventilation_ach: 2, room_type: 'lobby' }],
]);

export const PEOPLE = [
  { id: 'Ana', x: 300, y: 215 }, { id: 'Ben', x: 215, y: 125 }, { id: 'Cam', x: 455, y: 110 },
  { id: 'Dev', x: 420, y: 350 }, { id: 'Eli', x: 190, y: 345 }, { id: 'Fay', x: 60, y: 235 },
  { id: 'Gus', x: 70, y: 50 }, { id: 'Hana', x: 610, y: 70 }, { id: 'Ivy', x: 600, y: 320 },
  { id: 'Jo', x: 645, y: 200 },
];

// One row per meeting. Before Wed 09:00 nobody knows anything; after it, Ana stays in her room.
export const MEETINGS = [
  { a: 'Ben', b: 'Gus', ms: at(0, 18), min: 30, d: 1.5, room: 'lounge', what: 'hanging out' },
  { a: 'Ana', b: 'Ben', ms: at(0, 22), min: 480, d: 3.7, room: 'dorm', what: 'roommates overnight' },
  { a: 'Ana', b: 'Dev', ms: at(1, 10), min: 75, d: 4, room: 'class', what: 'same lecture' },
  { a: 'Dev', b: 'Eli', ms: at(1, 12, 30), min: 40, d: 1, room: 'dining', what: 'lunch together' },
  { a: 'Ana', b: 'Cam', ms: at(1, 14), min: 120, d: 1, room: 'study', what: 'study session' },
  { a: 'Ana', b: 'Ben', ms: at(2, 9, 30), min: 240, d: 3.7, room: 'dorm', what: 'Ana stays in' },
  { a: 'Cam', b: 'Hana', ms: at(2, 11), min: 120, d: 1, room: 'study', what: 'study session' },
  { a: 'Ben', b: 'Fay', ms: at(2, 12, 30), min: 45, d: 1, room: 'dining', what: 'lunch together' },
  { a: 'Dev', b: 'Ivy', ms: at(2, 13), min: 60, d: 2, room: 'class', what: 'same lecture' },
  { a: 'Hana', b: 'Jo', ms: at(2, 15), min: 90, d: 1, room: 'study', what: 'study session' },
  { a: 'Fay', b: 'Gus', ms: at(2, 16), min: 60, d: 1.5, room: 'lounge', what: 'hanging out' },
  { a: 'Ivy', b: 'Jo', ms: at(2, 17), min: 30, d: 1, room: null, what: 'walk outside' },
];

export const EVIDENCE = ['none', 'might_be_sick', 'positive', 'negative'];
export const EVIDENCE_LABEL = { none: 'no report', might_be_sick: '“might be sick”', positive: 'positive test', negative: 'negative test' };

const step = (ms) => Math.round((ms - START_MS) / (STEP_MIN * MIN));
export const contactRow = (m) => ({
  t: step(m.ms), agent_a: m.a, agent_b: m.b, distance_m: m.d, distance_tier: m.d < 1 ? 1 : m.d < 2 ? 2 : m.d < 5 ? 3 : 4,
  duration_s: m.min * 60, room_id: m.room || '', indoor: m.room ? 'True' : 'False',
});

// state: { evidence: { id: 'none'|... }, reports: [{ by, target }] }
export function runScenario(state) {
  const t = step(REPORT_MS);
  const reports = [];
  for (const [id, e] of Object.entries(state.evidence)) {
    if (e === 'might_be_sick') reports.push({ t, agent_id: id, event: 'self_report', value: 'might_be_sick' });
    if (e === 'positive' || e === 'negative') reports.push({ t, agent_id: id, event: 'test_result', value: e });
  }
  for (const r of state.reports) reports.push({ t, agent_id: r.by, event: 'report_other', value: 'might_be_sick', target_agent_id: r.target });
  return inferRisk({
    contacts: MEETINGS.map(contactRow), reports, rooms: ROOMS,
    agentIds: PEOPLE.map((p) => p.id), stepMin: STEP_MIN, startMs: START_MS,
  }, FINE);
}
// Only output granularity, not the maths: write every change >= 0.05 points (default 1 point) and list
// contributions down to 0.01 points, so small second-hand flows still show on a ten-person graph.
export const FINE = { minDelta: 0.0005, contribMin: 0.0001 };

// The same dose function the model uses, for the slider calculator.
export function calcDose({ minutes, distance, roomM2, indoor, ach = 2 }) {
  const rooms = new Map([['calc', { volume_m3: roomM2 * DEFAULTS.ceilingM, ventilation_ach: ach, room_type: 'generic' }]]);
  const unit = doseModel({}, rooms);
  const d = unit({ distance_m: distance, duration_s: minutes * 60, room_id: indoor ? 'calc' : '', indoor: indoor ? 'True' : 'False' });
  return { unit: d, info: { ...unit.info, room: unit.info.room && { ...unit.info.room } }, virusDecay: unit.virusDecay };
}

// Tiny made-up timelines, one per flag kind, run through inferRisk so the flag text is the model's.
export function flagExamples() {
  const ids = ['A', 'B', 'C', 'D'];
  const run = (contacts, reports) => inferRisk({ contacts, reports, rooms: ROOMS, agentIds: ids, stepMin: STEP_MIN, startMs: START_MS }).flags;
  const c = (a, b, ms, min, d, room) => contactRow({ a, b, ms, min, d, room });
  const r = (ms, agent_id, event, value, target_agent_id) => ({ t: step(ms), agent_id, event, value, target_agent_id });
  return {
    unexpected_report: run([c('A', 'B', at(0, 10), 30, 3, 'class')], [r(at(1, 9), 'A', 'self_report', 'might_be_sick')]),
    silent_high_risk: run(
      [c('A', 'B', at(0, 9), 480, 1, 'study'), c('C', 'D', at(2, 12), 5, 2, 'lounge')],
      [r(at(0, 8, 30), 'A', 'test_result', 'positive')]),
    suspicious_recovery: run([], [r(at(0, 9), 'A', 'self_report', 'might_be_sick'), r(at(1, 9), 'A', 'self_report', 'recovered')]),
    report_other_unsupported: run([c('A', 'C', at(0, 10), 30, 1, 'lounge')], [r(at(1, 9), 'A', 'report_other', 'might_be_sick', 'B')]),
  };
}

export { DEFAULTS, MIN, HOUR, DAY };
