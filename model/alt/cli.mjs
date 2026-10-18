#!/usr/bin/env node
// model/alt/cli.mjs — run one meeting through the alt flu model.
//
//   node model/alt/cli.mjs --prior 0.01 --p 0.8 --duration 15 --distance 1 \
//        --room 30 --stage 1 --days 2 --humidity 60 [--outdoors] [--temp 10]
//
// Flags: --prior --priorR --p --duration(min) --distance(m) --room(m2)
//        --roomVolume(m3) --ceiling(m) --ach --stage --days --humidity(%)
//        --temp(C) --outdoors --no-talking --json --verbose

import { update, C, STAGE_UNKNOWN_FACTOR } from './flu_alt.mjs';

const NUMERIC = {
  prior: 'prior',
  priorr: 'priorR',
  p: 'p',
  duration: 'duration',
  distance: 'distance',
  room: 'room',
  roomvolume: 'roomVolume',
  ceiling: 'ceilingHeight',
  ceilingheight: 'ceilingHeight',
  ach: 'ach',
  days: 'days',
  humidity: 'humidity',
  temp: 'temp',
  breathingrate: 'breathingRate',
};

function parseArgs(argv) {
  const out = {};
  let json = false;
  let verbose = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new Error(`unexpected argument "${a}"`);
    const key = a.slice(2).toLowerCase();
    if (key === 'json') { json = true; continue; }
    if (key === 'verbose') { verbose = true; continue; }
    if (key === 'help' || key === 'h') return { help: true };
    if (key === 'outdoors' || key === 'outdoor') { out.outdoors = true; continue; }
    if (key === 'indoors') { out.outdoors = false; continue; }
    if (key === 'talking') { out.talking = true; continue; }
    if (key === 'no-talking' || key === 'notalking' || key === 'silent') {
      out.talking = false;
      continue;
    }
    const value = argv[++i];
    if (value === undefined) throw new Error(`--${key} needs a value`);
    if (key === 'stage') {
      const n = Number(value);
      out.stage = Number.isFinite(n) ? n : value;
      continue;
    }
    const field = NUMERIC[key];
    if (!field) throw new Error(`unknown flag --${key} (try --help)`);
    const n = Number(value);
    if (!Number.isFinite(n)) throw new Error(`--${key} expects a number, got "${value}"`);
    out[field] = n;
  }
  return { inputs: out, json, verbose };
}

const USAGE = `node model/alt/cli.mjs [flags]

  --prior <0..1>      my previous P(have the flu)            default 0
  --priorR <0..1>     my P(already recovered this season)    default 0
  --p <0..1>          their P(have the flu)                  default 1
  --duration <min>    minutes of contact                     default 0
  --distance <m>      metres between us                      default 1
  --room <m2>         room floor area (indoors)              default 30
  --roomVolume <m3>   room volume, overrides --room
  --ceiling <m>       ceiling height                         default ${C.CEILING_HEIGHT}
  --ach <1/h>         air changes per hour                   default ${C.ACH_DEFAULT}
  --stage <day|name>  their day of illness, 0 = symptom onset;
                      names: presymptomatic onset peak early mid late recovered;
                      omitted = unknown (illness-average, x${STAGE_UNKNOWN_FACTOR.toFixed(2)})
  --days <d>          days since the meeting                 default 0
  --humidity <%>      OUTDOOR relative humidity              default 50
  --temp <C>          outdoor air temperature                default ${C.OUTDOOR_TEMP_C_DEFAULT}
  --outdoors          the meeting was outdoors               default indoors
  --no-talking        nobody spoke (talking is ON by default)
  --json              machine-readable output
  --verbose           show the dose breakdown`;

function pct(x) {
  return `${(100 * x).toFixed(x < 0.001 ? 4 : x < 0.01 ? 3 : 2)}%`;
}

function main() {
  let parsed;
  try {
    parsed = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(`error: ${err.message}\n\n${USAGE}`);
    process.exit(2);
  }
  if (parsed.help) {
    console.log(USAGE);
    return;
  }
  let r;
  try {
    r = update(parsed.inputs);
  } catch (err) {
    console.error(`error: ${err.message}`);
    process.exit(2);
  }

  if (parsed.json) {
    console.log(JSON.stringify(r, null, 2));
    return;
  }

  const d = r.detail || {};
  console.log(`dose (quanta)        lambda = ${r.lambda.toExponential(3)}`);
  console.log(`  near field                 ${r.lambdaNear.toExponential(3)}`);
  console.log(`  far field                  ${r.lambdaFar.toExponential(3)}`);
  console.log(`P(infected | susceptible, they are infectious)  ${pct(r.pInfectedIfSusceptible)}`);
  console.log(`P(this meeting infected me)                     ${pct(r.pInfectedByMeeting)}  (their P = ${r.pOther})`);
  console.log(`after ${r.days} day(s):`);
  console.log(`  P(have the flu now, E+I)   ${pct(r.pNow)}`);
  console.log(`  P(infectious now, I)       ${pct(r.pInfectious)}`);
  console.log(
    `  states  S ${r.states.S.toFixed(5)}  E ${r.states.E.toFixed(5)}  I ${r.states.I.toFixed(5)}  R ${r.states.R.toFixed(5)}`
  );
  if (parsed.verbose) {
    console.log('\ndose detail:');
    console.log(`  emission            ${(d.eq ?? 0).toFixed(3)} quanta/h (stage x${(d.stageFactor ?? 0).toFixed(2)}, talking=${d.talking})`);
    console.log(`  absolute humidity   ${(d.absoluteHumidity ?? 0).toFixed(2)} g/m^3`);
    console.log(`  RH seen by aerosol  ${(d.rhSeen ?? 0).toFixed(1)}%`);
    console.log(`  inactivation        ${(d.kInact ?? 0).toFixed(2)} /h`);
    console.log(`  susceptibility      x${(d.susceptibility ?? 1).toFixed(3)}`);
    if (d.roomVolume) {
      console.log(`  room volume         ${d.roomVolume.toFixed(1)} m^3`);
      console.log(`  total removal       ${(d.removalRate ?? 0).toFixed(2)} /h`);
    } else {
      console.log('  room                outdoors (no far field)');
    }
    console.log(`  near-field factor   ${(d.nearFieldFactor ?? 0).toFixed(3)} (at ${d.distance} m)`);
  }
}

main();
