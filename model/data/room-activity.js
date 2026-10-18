// What people do in each kind of room, as one exposure factor for model/meanfield.js.
// f = (source's emission relative to seated talking) x (listener's breathing / 0.5 m^3/h). Source and listener
// share the room, so the near-field plume and the room's air both scale by the same f. A phone knows the room's
// type from the map (map/rooms.csv room_type), not what anyone is doing, so f is the typical activity there.
//
// Breathing rates (m^3/h, ages 16-30): sleep ~0.3, sedentary/passive ~0.3-0.4, light ~0.7, moderate ~1.6,
// high ~2.9. US EPA, Exposure Factors Handbook (2011), ch. 6, Table 6-2:
//   https://www.epa.gov/expobox/exposure-factors-handbook-chapter-6
// Emission rises with vocalization and exertion (quiet breathing << speaking << loud speaking; heavy exercise
// several x resting): Buonanno, Stabile & Morawska, Environ. Int. 141:105794 (2020),
//   https://doi.org/10.1016/j.envint.2020.105794
// The numbers are the campus simulator's own activity tables (sim/configs/diseases.json:
// emission_multiplier_by_activity x breathing_m3_per_h, which follow the two sources above), mapped from each
// room type to the activity scheduled there, so the model and the sim share one set of assumptions:
//   dorm rooms: f 0.7. Activities there span sleep 0.25 (0.5 x 0.25), rest/isolating at home with flu 0.4-0.6
//     (0.7-0.8 x 0.3-0.35), relax 0.8 (1.0 x 0.4), hangout 1.3 (1.2 x 0.55). Sleep alone (8 h sleep + 2 h relax:
//     0.36) underweighted roommates ~3x against the sim's infections; 0.7 (awake-weighted, with a sick resident
//     home all day) scored about as well as 1 and better than 0.36 on run 25fe957a (model/README.md).
//     Replaces infer.js's quietQuanta 1.5/10 = 0.15, which was set by hand.
//   party 1.5 x 0.9, hangout (lounge) 1.2 x 0.55, study (reading room) 0.7 x 0.45, gym 1.5 x 1.8,
//   practice 1.5 x 2.0, event (arena) 1.3 x 0.6, eat / class / study group 1.0 x 0.5, lab 1.0 x 0.6,
//   rest (waiting room) 0.7 x 0.3.
// Unknown types and outdoors: 1 (seated talking; outdoors the plume is diluted 5x instead).

export const ROOM_ACTIVITY = {
  dorm_single: 0.7, dorm_double: 0.7, dorm_triple: 0.7, dorm_quad: 0.7,
  party_room: 2.7,
  lounge: 1.32,
  reading_room: 0.63,
  study_room: 1.0,
  weight_room: 5.4,
  practice_gym: 6.0, pool: 6.0,
  arena: 1.56,
  dining_room: 1.0, cafe: 1.0,
  classroom: 1.0, seminar: 1.0, lecture_hall: 1.0, exam_room: 1.0,
  lab: 1.2,
  waiting_room: 0.42,
  lobby: 1.0, generic: 1.0, outdoor_area: 1.0,
};

export const activityOf = (roomType) => ROOM_ACTIVITY[roomType] ?? (String(roomType || '').startsWith('dorm') ? 0.7 : 1);
