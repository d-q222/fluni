"""Claude-driven agents: a few agents decide their own day instead of following the scheduler's plan.

Each chosen agent is called once per sim day at `day_start_h` (default 4 AM) with its persona, a short
diary of earlier days, how it feels, test results and app notifications, today's classes and invites,
the scheduler's default plan, and a menu of campus places. Claude returns timed blocks (activity +
place) for the next 24 h; they overwrite that agent's columns in `plans` (transit steps inserted the
same way plans.py does), so Behavior moves the agent along the campus paths as usual. Symptom onset,
a test result or app advice triggers a re-plan of the rest of the day.

For these agents the scripted sickness response (reports.py: isolate / Vaden / carry on) and the
intervention's actions are switched off: the agent hears the app's advice as a notification and
decides itself. Self-reports and test results still come from reports.py.

Conversations: when two Claude agents stay within `conversations.radius_m` of each other (no wall
between them), or share a small room (dorm room, small study room), for `min_minutes`, they talk. Turns alternate, one call per line; each speaker
sees only its own persona, health, test results and diary, what is visible about the other (mask,
coughing) and how they know each other, so a sick agent may or may not tell. Afterwards each agent
writes a memory and says whether the talk changes its day; if so it re-plans with the transcript in
its notifications (trigger `conversation`). Memories of recent talks go into later daily plans.
Each spoken line says whether it revealed the speaker's health (`shared_health`).

Notice: a Claude agent awake next to a visibly sick rule-based agent for `notice.min_minutes`, or in a
room with `crowded_occupancy` people, gets an observation in its notifications (trigger `observation`,
at most `max_observations_per_day` re-plans). No API call unless it re-plans.

Messages: plans, re-plans and reflections may return texts to friend-group members (invite / warn /
tell_sick, to one friend or "group"). Claude recipients answer in their next plan (`accept`, trigger
`message`); rule-based ones accept with P = sigmoid(b[kind] + w_A (A - .5) + w_E (E - .5) + w_worry
(worry - baseline) + w_rel[relationship]). An accepted invite goes into the plan (a group invite needs
`group_min` yeses); an accepted warning raises worry and may send a rule-based agent to Vaden.

Worry: plans and reflections return `worry` (1-5), which sets the agent's level in worry.py when the
engine attaches one (`self.worry`). Every measured decision is a row of llm_events.csv (EVENT_COLUMNS).

Determinism: every request is hashed and its response cached under `cache_dir`, so a rerun with the
same seed + config + cache is byte-identical and makes no API calls. `offline: true` never calls the
API (cache misses fall back to the default plan).
"""
import csv
import hashlib
import io
import json
import math
import zlib
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta

import numpy as np

from . import codes
from .codes import ACT, ARCHETYPES, ROOM_OFF_MAP
from .config import ROOT

A_COMMUTE = ACT["commute"]
CHOOSABLE_ACTS = ["sleep", "relax", "class", "lab", "study", "eat", "practice", "gym", "party", "hangout",
                  "event", "study_group", "outdoor_leisure", "off_campus", "isolate", "health_visit", "rest"]
WEEKDAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
ARCHETYPE_TEXT = {
    "studious": "a studious student who cares about grades and spends a lot of time in the library",
    "social": "a very social student who loves parties, hangouts and being around friends",
    "athlete": "a varsity athlete whose days revolve around practice, lifting and team life",
    "stem": "a STEM major with heavy problem sets and evening lab work",
    "commuter": "a commuter who lives off campus and comes in mainly for classes",
    "homebody": "a homebody who prefers staying in their dorm room and keeps a small circle",
}
SICK_TEXT = {
    "stay_home": "When you feel sick you usually stay in and rest.",
    "visit_vaden_then_isolate": "When you feel sick you usually get checked at Vaden Health Center, then stay in.",
    "carry_on": "When you feel sick you usually push through and keep your normal schedule.",
}
SYMPTOMS = {
    "influenza": "fever, chills, cough, sore throat and body aches",
    "covid19": "fever, cough, sore throat, fatigue",
    "norovirus": "nausea, vomiting, stomach cramps",
}
ADVICE_TEXT = {
    "isolate_until": "advises you to stay home until {until}",
    "wear_mask": "advises you to wear a mask for the next day",
    "leave_location": "advises you to leave where you are now (someone near you may be contagious)",
    "go_to_vaden": "advises you to get tested at Vaden Health Center",
}
SYSTEM = """You are simulating the day-to-day decisions of one Stanford undergraduate inside an epidemic \
simulation of campus life. Researchers use the result to study how real students behave, so realism \
matters more than good behavior: real students skip some classes, stay up late, go to parties, \
sometimes ignore health advice and sometimes go out while sick. Stay in character with the persona and \
tendencies you are given, and keep continuity with your diary.

Each turn you plan the given time window as a list of blocks. Rules:
- Times are 24-hour HH:MM. The day runs from the window start to the same time the next day; times \
earlier than the window start mean after midnight.
- Blocks must be in order, should not overlap, and should cover the whole window (gaps mean you stay \
where you were). Walking between places is added automatically; do not plan travel blocks.
- `place` must be one of the listed place ids. Classes and events only happen at their listed times.
- Sleep at home (commuters: off_campus). Use `isolate` or `rest` at home when staying in because you are sick.
- `thoughts`: a few sentences of in-character reasoning about today. `diary`: one or two sentences you \
will remember tomorrow (what you plan or did, how you feel, anything notable).
- `worry`: how worried you are right now about getting sick or making others sick, 1 (not at all) to 5 (very).
- `messages`: texts to people in your friend group, usually none. `to` is a friend's id, or "group" for \
the whole friend group. `kind`: `invite` (do something together at `place` at `time`), `warn` (a \
heads-up about illness going around), `tell_sick` (you tell them you are sick). Leave `place` and \
`time` empty unless inviting.
- `accept`: ids of messages you say yes to (an invite you will go to, a warning you take seriously)."""
TALK_SYSTEM = """You are role-playing one Stanford undergraduate inside an epidemic simulation of \
campus life. Another student is right next to you and you may talk. Researchers use the result to study \
how real students influence each other, so realism matters more than good behavior: students chat, make \
plans, talk friends into parties or out of them, warn each other, downplay or hide being sick, or just \
nod at a stranger and say nothing. Stay in character with your persona and diary.

You only know what your prompt tells you. Your symptoms, test results and app status are private unless \
you choose to share them; about the other person you only see what is visible and hear what they say.
- `say`: your next line, short and casual like real speech (empty string to say nothing).
- `end`: true when you are done talking (said goodbye, or don't want to talk).
- `shared_health`: true if this line tells them about your own symptoms, test result or app status.
When asked to reflect after the conversation: `memory` is one or two sentences you will remember (what \
you learned, anything you agreed to do), `replan` is true only if the conversation changes what you \
will do for the rest of today, and `worry` is how worried you are now about getting sick or making \
others sick, 1 (not at all) to 5 (very). `messages`: texts to people in your friend group, usually \
none (`to` a friend's id or "group"; `kind` invite at `place` and `time`, warn, or tell_sick; leave \
`place` and `time` empty unless inviting)."""
TALK_SCHEMA = {"type": "object", "properties": {"say": {"type": "string"}, "end": {"type": "boolean"},
                                                "shared_health": {"type": "boolean"}},
               "required": ["say", "end", "shared_health"], "additionalProperties": False}
WORRY_SCHEMA = {"type": "integer", "enum": [1, 2, 3, 4, 5]}
WORRY_WORDS = ["not worried", "a little worried", "somewhat worried", "quite worried", "very worried"]
MSG_KINDS = ["invite", "warn", "tell_sick"]
RELATIONS = ["friend", "roommate", "dormmate", "teammate", "classmate", "stranger"]
TALK_DEFAULTS = {"on": True, "radius_m": 3.0, "small_room_max_capacity": 8, "min_minutes": 10, "max_turns": 6, "cooldown_h": 6,
                 "max_per_agent_per_day": 4, "memory": 5}
NOTICE_DEFAULTS = {"on": True, "radius_m": 3.0, "small_room_max_capacity": 8, "min_minutes": 5, "crowded_occupancy": 40,
                   "cooldown_h": 6, "max_observations_per_day": 2}
MSG_DEFAULTS = {"on": True, "max_per_call": 3, "group_min": 2, "invite_hours": 1.5, "worry_baseline": 0.3,
                "vaden_visit_min": 45, "p_vaden": {"warn": 0.2, "tell_sick": 0.1},
                "p_accept": {"b": {"invite": -0.5, "warn": 0.5, "tell_sick": 0.5}, "w_A": 1.0, "w_E": 1.0,
                             "w_worry": {"invite": -1.5, "warn": 1.5, "tell_sick": 1.5},
                             "w_rel": {"friend": 0.5, "roommate": 0.5, "dormmate": 0.0, "teammate": 0.0,
                                       "classmate": -0.5, "stranger": -1.0}}}
EVENT_COLUMNS = ["t", "timestamp", "agent_id", "archetype", "openness", "conscientiousness", "extraversion",
                 "agreeableness", "neuroticism", "compliance", "mask_propensity", "honesty", "worry_before",
                 "worry_after", "severity", "symptomatic", "behavior", "context", "relationship", "other_agent_id",
                 "outcome", "value", "model"]
# room types -> activity of an invite there
INVITE_ACT = {"dining_room": "eat", "cafe": "eat", "reading_room": "study", "study_room": "study", "weight_room": "gym",
              "practice_gym": "gym", "pool": "gym", "outdoor_area": "outdoor_leisure", "waiting_room": "health_visit"}
NAMES = ["Alex", "Jordan", "Taylor", "Sam", "Casey", "Riley", "Morgan", "Avery", "Jamie", "Quinn", "Rowan",
         "Charlie", "Skyler", "Dakota", "Emerson", "Finley", "Hayden", "Kai", "Logan", "Parker", "Reese",
         "Sage", "Drew", "Eden", "Ari", "Noa", "Jules", "Remy", "Robin", "Shay", "Blake", "Cameron", "Devon",
         "Elliot", "Harper", "Jesse", "Kendall", "Lane", "Marley", "Nico", "Oakley", "Peyton", "River",
         "Sasha", "Tatum", "Wren", "Ash", "Bailey", "Billie", "Mika"]


def _hhmm(m):
    m = int(round(m)) % 1440
    return f"{m // 60:02d}:{m % 60:02d}"


def _crc(s):
    return zlib.crc32(s.encode())


def _f(x):
    """Float for llm_events.csv: 4 decimals, '' when missing."""
    return "" if x is None else f"{float(x):.4f}"


class LLMAgents:
    def __init__(self, cfg, campus, pop, plans, sections, events, behavior, reports, client=None):
        self.cfg = c = cfg["llm_agents"]
        self.campus, self.pop, self.plans = campus, pop, plans
        self.sections, self.events, self.beh, self.rep = sections, events, behavior, reports
        rc = cfg["run"]
        self.step_min = rc["step_min"]
        self.spd = 1440 // self.step_min
        self.T = plans.act.shape[1]
        self.start = datetime.fromisoformat(rc["start_date"])
        self.sw = int(rc.get("start_weekday", 0))
        self.disease = cfg["disease"].get("preset", "")
        self.day_start_step = int(round(c["day_start_h"] * 60 / self.step_min)) % self.spd
        self.client = client
        self.cache_dir = ROOT / c["cache_dir"]
        self.log = []

        N = pop.N
        n = min(int(c.get("n_agents") or 0), N)
        rng = np.random.default_rng([int(rc["seed"]), _crc("llm_agents")])
        if c.get("agent_ids"):
            want = set(c["agent_ids"])
            idx = [i for i, a in enumerate(pop.agent_id) if a in want]
        elif c.get("pick", "random") == "friend_groups":
            # whole friend groups, so Claude agents actually run into each other
            fg = np.asarray(pop.friend_group)
            idx = []
            for g in rng.permutation(np.unique(fg)).tolist():
                idx += np.flatnonzero(fg == g).tolist()[: n - len(idx)]
                if len(idx) >= n:
                    break
            idx = sorted(idx)
        else:
            idx = sorted(rng.choice(N, size=n, replace=False).tolist())
        self.idx = [int(i) for i in idx]
        self.mask = np.zeros(N, bool)
        self.mask[self.idx] = True
        reports.llm_controlled = self.mask

        self.diary = {i: [] for i in self.idx}
        self.inbox = {i: [] for i in self.idx}
        self.triggers = {}       # agent -> reason, replanned at the next step
        self.replans = {}        # (agent, day) -> count
        self.window_end = {}     # agent -> end step of the current plan window
        self.places = {}         # agent -> {place_id: (room, act_hint, event, section, label)}
        self.talk = {**TALK_DEFAULTS, **c.get("conversations", {})}
        self.chats = {i: [] for i in self.idx}  # agent -> memories of recent conversations
        self._near = {}          # (i, j) -> consecutive steps within talking distance
        self._last_talk = {}     # (i, j) -> step of their last conversation
        self._talks_day = {}     # (agent, day) -> conversations
        self.convos = []
        self.seed = int(rc["seed"])
        self.worry = None        # set by the engine when worry is on (worry.py): bump / set_measured / level
        self.notice = {**NOTICE_DEFAULTS, **c.get("notice", {})}
        self.mcfg = {**MSG_DEFAULTS, **c.get("messages", {})}
        self._seen = {}          # (claude agent, other) -> consecutive steps next to a visibly sick agent
        self._last_seen = {}     # (claude agent, other) -> step of the last observation about them
        self._in_room = {}       # agent -> (room, consecutive steps)
        self._crowd_done = set() # (agent, room, day) crowded-room observations made
        self._obs = {i: [] for i in self.idx}     # agent -> [(cue, room)] observations not yet planned on
        self._obs_replans = {}   # (agent, day) -> re-plans triggered by observations
        self._advice = {i: [] for i in self.idx}  # agent -> [(advice kind, until_t, room)] since the last plan
        self._onset = set()      # agents whose first plan after symptom onset is still due
        self.msgs = []           # every message (llm_messages.jsonl)
        self._open = {}          # message id -> state while replies are outstanding
        self._awaiting = {i: [] for i in self.idx}  # Claude agent -> message ids it has not answered
        self.commit = {i: [] for i in self.idx}     # Claude agent -> [(s, e, act, room, event, section, text)]
        self.events_rows = []    # llm_events.csv rows
        self._dis = None
        self._now = 0            # first step not yet consumed by Behavior
        self._groups = {}
        for j, g in enumerate(np.asarray(pop.friend_group).tolist()):
            self._groups.setdefault(g, []).append(j)
        self._aid_ix = {a: k for k, a in enumerate(pop.agent_id)}

        self.rtype = campus.rooms["room_type"].to_numpy().astype(str)
        self.bname = campus.buildings["name"].to_numpy().astype(str)
        self.bloc = campus.buildings["location_id"].to_numpy().astype(str)
        self.room_b = np.asarray(campus.room_b, np.int64)
        self.rcap = campus.rooms["capacity"].to_numpy()
        self._fixed = self._fixed_places()

    # ------------------------------------------------------------------ places
    def _room_in(self, b, types, key):
        rs = np.asarray(self.campus.rooms_of(int(b)), np.int64)
        typed = rs[np.isin(self.rtype[rs], list(types))] if len(rs) else rs
        pool = typed if len(typed) else rs
        return int(pool[_crc(key) % len(pool)]) if len(pool) else -1

    def _fixed_places(self):
        """(kind, b) of campus places every agent may choose from, plus the common rooms."""
        out = []
        for kind in ("dining", "library", "gym", "outdoor", "health_center"):
            out += [(kind, int(b)) for b in self.campus.buildings_of_type(kind)]
        self._common_b = np.asarray(self.campus.buildings_of_type("common_room"), np.int64)
        return out

    def _menu(self, i, d, lo_min, hi_min):
        """{place_id: (room, act_hint, event, section, label)} for agent i on day d."""
        pop, aid = self.pop, self.pop.agent_id[i]
        types = {"dining": ("dining_room",), "library": ("reading_room", "study_room"),
                 "gym": ("weight_room", "practice_gym", "pool"), "outdoor": ("outdoor_area",),
                 "health_center": ("waiting_room",), "common_room": ("lounge", "study_room", "cafe", "lobby")}
        m = {}
        home = int(pop.home_room[i])
        if home >= 0:
            m["home"] = (home, None, -1, -1, f"your dorm room in {self.bname[self.room_b[home]]}")
            lob = self._room_in(self.room_b[home], ("lobby", "lounge"), aid + "lobby")
            if lob >= 0 and lob != home:
                m["dorm_lounge"] = (lob, None, -1, -1, f"the lounge of your dorm, {self.bname[self.room_b[home]]}")
        m["off_campus"] = (ROOM_OFF_MAP, "off_campus", -1, -1, "off campus" + (" (home)" if home < 0 else ""))
        for kind, b in self._fixed:
            r = self.beh.vaden_room if kind == "health_center" and self.beh.vaden_room >= 0 else \
                self._room_in(b, types[kind], aid + self.bloc[b])
            if r >= 0:
                m[f"bld:{self.bloc[b]}"] = (r, "health_visit" if kind == "health_center" else None, -1, -1,
                                           f"{self.bname[b]} ({kind.replace('_', ' ')})")
        cb = self._common_b
        if len(cb):
            ref = self.room_b[home] if home >= 0 else int(np.argmin(np.hypot(self.campus.b_x, self.campus.b_y)))
            dist = np.hypot(self.campus.b_x[cb] - self.campus.b_x[ref], self.campus.b_y[cb] - self.campus.b_y[ref])
            near = cb[np.argsort(dist, kind="stable")[: int(self.cfg["common_rooms_per_agent"])]].tolist()
            fav = int(pop.fav_common[i]) if pop.fav_common is not None else -1
            for b in sorted(set(near + ([fav] if fav >= 0 else []))):
                r = self._room_in(b, types["common_room"], aid + self.bloc[b])
                if r >= 0:
                    m[f"bld:{self.bloc[b]}"] = (r, None, -1, -1, f"{self.bname[b]} (common room)")
        # friends' dorms
        fg = np.flatnonzero(np.asarray(pop.friend_group) == pop.friend_group[i])
        for j in fg.tolist():
            hb = int(pop.home_b[j])
            if j != i and hb >= 0 and (home < 0 or hb != self.room_b[home]):
                r = self._room_in(hb, ("lobby", "lounge"), self.bloc[hb] + "lobby")
                if r >= 0:
                    m[f"dorm:{self.bloc[hb]}"] = (r, "hangout", -1, -1, f"the lounge of {self.bname[hb]} (friends live here)")
        # today's classes
        wd = (self.sw + d) % 7
        sec = self.sections
        for s in (pop.class_schedule[i] if pop.class_schedule is not None else []):
            if wd in list(sec.at[s, "weekdays"]):
                a = "lab" if str(sec.at[s, "kind"]) == "lab" else "class"
                r = int(sec.at[s, "r"])
                m[f"class:{sec.at[s, 'section_id']}"] = (
                    r, a, -1, int(s), f"{sec.at[s, 'course']} {sec.at[s, 'kind']}, "
                    f"{_hhmm(sec.at[s, 'start_min'])}-{_hhmm(sec.at[s, 'end_min'])} in {self.bname[self.room_b[r]]}")
        # today's events: invited, or public
        ev = self.events
        if ev is not None and len(ev):
            pub = set(self.cfg["public_event_types"])
            for k in range(len(ev)):
                s0, s1 = int(ev.at[k, "start_min"]), int(ev.at[k, "end_min"])
                if s1 <= lo_min or s0 >= hi_min:
                    continue
                t_ = str(ev.at[k, "type"])
                invited = i in set(int(a) for a in ev.at[k, "attendees"])
                if invited or t_ in pub:
                    r = int(ev.at[k, "r"])
                    act = {"party": "party", "dorm_hangout": "hangout", "study_group": "study_group"}.get(t_, "event")
                    m[f"event:{ev.at[k, 'event_id']}"] = (
                        r, act, k, -1, f"{ev.at[k, 'name']} ({t_.replace('_', ' ')}, {'invited' if invited else 'open to all'}), "
                        f"{_hhmm(s0)}-{_hhmm(s1)} at {self.bname[self.room_b[r]]}")
        return m

    def _plan_rooms(self, i, s0, s1, menu):
        """Adds rooms the default plan uses but the menu lacks (practice, lab, ...) as plan:<room_id>."""
        rid = self.campus.rooms["room_id"].to_numpy()
        have = {v[0] for v in menu.values()}
        for r in np.unique(self.plans.room[i, s0:s1]).tolist():
            if r >= 0 and r not in have:
                menu[f"plan:{rid[r]}"] = (int(r), None, -1, -1, f"{self.bname[self.room_b[r]]} ({self.rtype[r].replace('_', ' ')})")

    # ------------------------------------------------------------------ prompt
    def _blocks_text(self, i, s0, s1, menu):
        by_room = {}
        for pid, v in menu.items():
            by_room.setdefault((v[0], v[2], v[3]), pid)
            by_room.setdefault((v[0], -1, -1), pid)
        P = self.plans
        lines, k = [], s0
        while k < s1:
            if P.act[i, k] == A_COMMUTE:
                k += 1
                continue
            a, r, e, s = int(P.act[i, k]), int(P.room[i, k]), int(P.event[i, k]), int(P.section[i, k])
            j = k
            while j < s1 and P.act[i, j] == a and P.room[i, j] == r:
                j += 1
            pid = by_room.get((r, e, s)) or by_room.get((r, -1, -1), "?")
            lines.append(f"- {self._clock(k)}-{self._clock(j)} {codes.ACTIVITIES[a]} @ {pid}")
            k = j
        return "\n".join(lines) or "- (nothing planned)"

    def _clock(self, t):
        return _hhmm(t * self.step_min)

    def _persona(self, i):
        pop = self.pop
        arch = ARCHETYPES[int(pop.archetype[i])]
        bits = [f"You are {self._name(i)}, a year-{int(pop.class_year[i])} Stanford undergrad: {ARCHETYPE_TEXT.get(arch, arch)}."]
        home = int(pop.home_room[i])
        bits.append(f"You live in {self.bname[self.room_b[home]]} ({self.rtype[home].replace('_', ' ')})." if home >= 0
                    else "You live off campus and commute in.")
        if int(pop.team_id[i]) >= 0:
            bits.append(f"You are on the {pop.teams[int(pop.team_id[i])]['name']} team.")
        bits.append("You bike around campus." if int(pop.transport[i]) == 1 else "You walk around campus.")
        n_fr = int((np.asarray(pop.friend_group) == pop.friend_group[i]).sum()) - 1
        bits.append(f"Your friend group has {n_fr} other people.")
        if getattr(pop, "big_five", None) is not None:
            from .personality import describe
            bits.append(describe(pop.big_five[i]))

        def lvl(v, words):
            return words[min(int(v * len(words)), len(words) - 1)]
        bits.append("You " + lvl(pop.compliance[i], ["rarely", "sometimes", "usually", "almost always"]) +
                    " follow health advice, " + lvl(pop.mask_propensity[i], ["almost never", "occasionally", "often", "usually"]) +
                    " wear a mask indoors, and are " + lvl(pop.honesty[i], ["not very", "fairly", "very"]) +
                    " honest about being sick.")
        bits.append(SICK_TEXT[codes.SICK_PROFILES[int(pop.sick_profile[i])]])
        if bool(pop.has_app[i]):
            bits.append("You have the FlUni app, which warns about close contacts and gives advice.")
        return " ".join(bits)

    def _name(self, i):
        aid = self.pop.agent_id[i]
        return f"{NAMES[_crc(aid) % len(NAMES)]} ({aid})"

    def _health(self, i, dis):
        out = []
        if bool(dis.symptomatic[i]):
            sev = float(dis.severity[i])
            word = "mildly unwell" if sev < 0.35 else ("sick" if sev < 0.7 else "really sick")
            out.append(f"You feel {word} ({SYMPTOMS.get(self.disease, 'fever, cough, fatigue')}).")
        else:
            out.append("You feel fine.")
        ts = codes.TEST_STATUS[int(self.rep.test_status[i])]
        if ts != "none":
            out.append({"pending": "You are waiting on a flu test result.",
                        "positive": "Your last test came back POSITIVE.",
                        "negative": "Your last test came back negative."}[ts])
        ss = codes.SELF_STATUS[int(self.rep.self_status[i])]
        if ss != "none":
            out.append(f"In the app you are marked as: {ss.replace('_', ' ')}.")
        lv = self._wlevel(i)
        if lv is not None:
            out.append(f"Lately you are {WORRY_WORDS[min(int(lv * 5), 4)]} about getting sick.")
        return " ".join(out)

    def _friends(self, i):
        return [j for j in self._groups[self.pop.friend_group[i]] if j != i]

    def _friends_text(self, i):
        return "Friends you can text: " + ", ".join(self._name(j) for j in self._friends(i)) + "."

    def _where(self, i, menu):
        r = int(self.beh.room[i])
        if r == codes.ROOM_TRANSIT:
            return "walking between places"
        for pid, v in menu.items():
            if v[0] == r:
                return f"at {pid}"
        return "off campus" if r == ROOM_OFF_MAP else f"at {self.bname[self.room_b[r]]}"

    def _user_text(self, i, t0, t1, d, menu, dis, reason):
        when = self.start + timedelta(minutes=t0 * self.step_min)
        wd = WEEKDAYS[(self.sw + d) % 7]
        parts = [self._persona(i), "",
                 f"Now: {wd} {when.strftime('%B %-d')}, {self._clock(t0)}. You are {self._where(i, menu) if t0 else 'at home'}.",
                 f"Plan the window {self._clock(t0)} until {self._clock(t1)}" + (" tomorrow." if t1 - t0 >= self.spd - 1 else "."),
                 "", "How you feel: " + self._health(i, dis)]
        if reason and reason != "day":
            parts.append({"symptom_onset": "You just started feeling sick, so you are rethinking the rest of your day.",
                          "test_result": "You just got a test result, so you are rethinking the rest of your day.",
                          "app_advice": "You just got a notification from the FlUni app, so you are rethinking the rest of your day.",
                          "conversation": "You just talked with someone, so you are rethinking the rest of your day.",
                          "message": "You just got a text, so you are rethinking the rest of your day.",
                          "observation": "You just noticed something around you, so you are rethinking the rest of your day.",
                          }.get(reason, ""))
        if self.inbox[i]:
            parts += ["", "Notifications:"] + [f"- {m}" for m in self.inbox[i]]
        if self._awaiting[i]:
            parts += ["", "Texts waiting for your answer (put the id in `accept` to say yes):"] + \
                [f"- [{mid}] {self._msg_line(self._open[mid])}" for mid in self._awaiting[i]]
        if self.commit[i]:
            parts += ["", "Plans you agreed to (kept in your plan):"] + \
                [f"- {self._clock(c[0])}-{self._clock(c[1])} {c[6]}" for c in self.commit[i]]
        if self._can_text(i):
            parts += ["", self._friends_text(i)]
        mem = self.diary[i][-int(self.cfg["memory_days"]):]
        if mem:
            parts += ["", "Your diary:"] + [f"- {m}" for m in mem]
        if self.chats[i]:
            parts += ["", "Recent conversations:"] + [f"- {m}" for m in self.chats[i]]
        parts += ["", "Your usual routine for this window (what you would do on autopilot):",
                  self._blocks_text(i, t0, t1, menu),
                  "", "Places you can go (id: description):"] + [f"- {k}: {v[4]}" for k, v in menu.items()]
        return "\n".join(parts)

    def _schema(self, i, menu):
        props = {
            "thoughts": {"type": "string"},
            "wear_mask": {"type": "boolean"},
            "worry": WORRY_SCHEMA,
            "blocks": {"type": "array", "items": {
                "type": "object",
                "properties": {"start": {"type": "string"}, "end": {"type": "string"},
                               "activity": {"type": "string", "enum": CHOOSABLE_ACTS},
                               "place": {"type": "string", "enum": list(menu)}},
                "required": ["start", "end", "activity", "place"], "additionalProperties": False}},
        }
        if self._can_text(i):
            props["messages"] = self._msg_schema(i, menu)
        if self._awaiting[i]:
            props["accept"] = {"type": "array", "items": {"type": "string", "enum": list(self._awaiting[i])}}
        props["diary"] = {"type": "string"}
        return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}

    def _can_text(self, i):
        return bool(self.mcfg["on"]) and bool(self._friends(i))

    def _msg_schema(self, i, menu):
        to = [self.pop.agent_id[j] for j in self._friends(i)] + ["group"]
        return {"type": "array", "items": {
            "type": "object",
            "properties": {"to": {"type": "string", "enum": to}, "kind": {"type": "string", "enum": MSG_KINDS},
                           "place": {"type": "string", "enum": [""] + list(menu)}, "time": {"type": "string"},
                           "text": {"type": "string"}},
            "required": ["to", "kind", "place", "time", "text"], "additionalProperties": False}}

    def _reflect_schema(self, i, menu):
        props = {"memory": {"type": "string"}, "replan": {"type": "boolean"}, "worry": WORRY_SCHEMA}
        if self._can_text(i):
            props["messages"] = self._msg_schema(i, menu)
        return {"type": "object", "properties": props, "required": list(props), "additionalProperties": False}

    # ------------------------------------------------------------------ API + cache
    def _request(self, user, schema, system=SYSTEM):
        c = self.cfg
        return {"model": c["model"], "max_tokens": int(c["max_tokens"]),
                "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
                "messages": [{"role": "user", "content": user}],
                "output_config": {"effort": c["effort"], "format": {"type": "json_schema", "schema": schema}}}

    def _call(self, req):
        """Parsed response dict, or None (offline miss / API error / refusal / invalid JSON)."""
        return self._call_m(req)[0]

    def _call_m(self, req):
        """(response or None, model that wrote it)."""
        key = hashlib.sha256(json.dumps(req, sort_keys=True).encode()).hexdigest()
        path = self.cache_dir / key[:2] / f"{key}.json"
        if path.exists():
            hit = json.loads(path.read_text())
            return hit["response"], hit.get("model", "")
        if self.cfg.get("offline"):
            return None, ""
        if self.client is None:
            import anthropic
            self.client = anthropic.Anthropic()
        try:
            import anthropic
            msg = self.client.beta.messages.create(betas=["server-side-fallback-2026-07-01"], fallbacks="default", **req)
        except anthropic.APIError as e:
            print(f"llm_agents: API error {type(e).__name__}: {e}", flush=True)
            return None, ""
        if msg.stop_reason in ("refusal", "max_tokens"):
            print(f"llm_agents: stop_reason={msg.stop_reason}", flush=True)
            return None, ""
        text = next((b.text for b in msg.content if b.type == "text"), "")
        try:
            resp = json.loads(text)
        except json.JSONDecodeError:
            return None, ""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"model": msg.model, "response": resp}, indent=1, sort_keys=True))
        return resp, msg.model

    # ------------------------------------------------------------------ applying a plan
    def _parse_min(self, s, base_min, lo_min):
        """'HH:MM' -> absolute sim minute in [lo_min, lo_min + 1440)."""
        try:
            h, m = (int(x) for x in s.strip().split(":"))
        except ValueError:
            return None
        if not (0 <= h <= 24 and 0 <= m < 60):
            return None
        a = base_min + h * 60 + m
        while a < lo_min:
            a += 1440
        while a >= lo_min + 1440:
            a -= 1440
        return a

    def _apply(self, i, t0, t1, resp, menu):
        step = self.step_min
        L = t1 - t0
        lo_min = t0 * step
        day_base = (lo_min // 1440) * 1440
        blocks = []
        for b in resp.get("blocks", []):
            pid = b.get("place")
            if pid not in menu or b.get("activity") not in ACT:
                continue
            s = self._parse_min(b.get("start", ""), day_base, lo_min)
            e = self._parse_min(b.get("end", ""), day_base, lo_min)
            if s is None or e is None:
                continue
            if e <= s:
                e = lo_min + 1440 if b.get("end", "").strip() == _hhmm(lo_min) else e
            if e <= s:
                continue
            blocks.append((s, e, b["activity"], pid))
        blocks.sort(key=lambda x: x[0])
        if not blocks:
            return False
        segs, vaden = [], []
        for s, e, a_name, pid in blocks:
            r, hint, k_ev, k_sec, _ = menu[pid]
            a0 = max(int(round(s / step)) - t0, 0)
            a1 = min(int(round(e / step)) - t0, L)
            if a1 <= a0:
                continue
            a = ACT[a_name]
            if r == ROOM_OFF_MAP:
                a = ACT["off_campus"] if a_name != "sleep" else a
            segs.append((a0, a1, a, r, k_ev, k_sec))
            if r >= 0 and r == self.beh.vaden_room:
                vaden.append((t0 + a0, t0 + a1))
        # invites this agent agreed to stay in its plan
        self.commit[i] = [c for c in self.commit[i] if c[1] > t0]
        for s, e, a, r, k_ev, k_sec, _ in self.commit[i]:
            if s < t1:
                segs.append((max(s - t0, 0), min(e - t0, L), a, r, k_ev, k_sec))
        self._paint(i, t0, t1, segs, fill=True)
        for s, e in vaden:
            if int(self.rep.test_status[i]) not in (1, 2) and i not in self.rep.vaden:  # not pending/positive
                self.rep.register_vaden_visit(i, s, e)
        self.beh.force_mask(i, t1 if resp.get("wear_mask") else t0)
        return True

    def _paint(self, i, t0, t1, segs, fill):
        """Writes segments [(a0, a1, act, room, event, section)] (steps relative to t0) into agent i's plan
        on [t0, t1), re-inserting transit. fill: unpainted steps after the first segment stay where the
        previous step was (a Claude plan); else they keep the existing plan (an inserted invite)."""
        P = self.plans
        L = t1 - t0
        act = P.act[i, t0:t1].copy()
        room = P.room[i, t0:t1].copy()
        ev = P.event[i, t0:t1].copy()
        sec = P.section[i, t0:t1].copy()
        # un-commute the old plan (transit is re-inserted below): commute steps take their destination block's act
        for k in range(L - 2, -1, -1):
            if act[k] == A_COMMUTE and act[k + 1] != A_COMMUTE:
                act[k], ev[k], sec[k] = act[k + 1], ev[k + 1], sec[k + 1]
        painted = np.zeros(L, bool)
        for a0, a1, a, r, k_ev, k_sec in segs:
            act[a0:a1], room[a0:a1], ev[a0:a1], sec[a0:a1] = a, r, k_ev, k_sec
            painted[a0:a1] = True
        if fill and painted.any():
            # gaps between / after blocks: stay where the previous block was
            for k in range(int(np.argmax(painted)) + 1, L):
                if not painted[k]:
                    act[k], room[k], ev[k], sec[k] = act[k - 1], room[k - 1], ev[k - 1], sec[k - 1]
        self._insert_transit(i, t0, act, room, ev, sec)
        P.act[i, t0:t1], P.room[i, t0:t1], P.event[i, t0:t1], P.section[i, t0:t1] = act, room, ev, sec

    def _insert_transit(self, i, t0, act, room, ev, sec):
        """Commute steps before every building change, timed as in plans.py (campus.trip_mode at the agent's speed)."""
        pop, rb = self.pop, self.room_b
        prev = int(self.beh.room[i]) if t0 > 0 else int(room[0])
        if prev == codes.ROOM_TRANSIT:
            prev = int(self.beh._dest[i]) if hasattr(self.beh, "_dest") else int(room[0])
        bc = np.where(room >= 0, rb[np.maximum(room, 0)], -1)
        pb = int(rb[prev]) if prev >= 0 else -1
        full = np.concatenate(([pb], bc))
        ch = np.flatnonzero(full[1:] != full[:-1])
        e_i = int(pop.entry_e[i]) if pop.entry_e[i] >= 0 else 0
        bike = bool(pop.transport[i] == 1)
        w = float((pop.walk_speed if pop.walk_speed is not None else pop.speed_mps)[i])
        bk = float((pop.bike_speed if pop.bike_speed is not None else pop.speed_mps)[i])
        run_start = np.concatenate(([0], ch[:-1])).tolist()
        for c, p0 in zip(ch.tolist(), run_start):
            sb, db = int(full[c]), int(full[c + 1])
            src = ("b", sb) if sb >= 0 else ("e", e_i)
            dst = ("b", db) if db >= 0 else ("e", e_i)
            mode, dist = self.campus.trip_mode(src, dst, bike)
            k = int(math.ceil(dist / (bk if mode == "bike" else w) / (self.step_min * 60))) if dist > 0 else 1
            k = min(k, c - p0 - 1) if c > 0 else 0
            if k <= 0:
                continue
            act[c - k:c] = A_COMMUTE
            room[c - k:c] = room[c]
            ev[c - k:c] = -1
            sec[c - k:c] = -1

    # ------------------------------------------------------------------ conversations
    def _relation(self, i, j):
        pop, bits = self.pop, []
        if pop.friend_group[i] == pop.friend_group[j]:
            bits.append("in your friend group")
        if int(pop.home_room[i]) >= 0 and pop.home_room[i] == pop.home_room[j]:
            bits.append("your roommate")
        elif int(pop.home_b[i]) >= 0 and pop.home_b[i] == pop.home_b[j]:
            bits.append("lives in your dorm")
        if int(pop.team_id[i]) >= 0 and pop.team_id[i] == pop.team_id[j]:
            bits.append("your teammate")
        if pop.class_schedule is not None:
            shared = set(pop.class_schedule[i]) & set(pop.class_schedule[j])
            if shared:
                bits.append("in your " + ", ".join(sorted({str(self.sections.at[s, "course"]) for s in shared})) + " class")
        return ", ".join(bits) if bits else "someone you don't know"

    def _looks(self, j, dis):
        """What anyone next to agent j can see."""
        bits = []
        if bool(dis.symptomatic[j]):
            sev = float(dis.severity[j])
            signs = ("they look a little pale", "they look pale and queasy", "they look really sick, pale and sweaty") \
                if self.disease == "norovirus" else \
                ("they sniffle now and then", "they are coughing and look unwell", "they look really sick, flushed and coughing hard")
            bits.append(signs[0 if sev < 0.35 else 1 if sev < 0.7 else 2])
        if bool(self.beh.masked[j]):
            bits.append("they are wearing a mask")
        return " and ".join(bits)

    def _place_text(self, i):
        r = int(self.beh.room[i])
        if r == codes.ROOM_TRANSIT:
            return "walking on campus"
        if r < 0:
            return "off campus"
        return f"{self.bname[self.room_b[r]]} ({self.rtype[r].replace('_', ' ')})"

    def _talk_head(self, i, j, t, dis):
        """Agent i's side of a conversation with j: everything but the transcript."""
        d = t // self.spd
        when = self.start + timedelta(minutes=t * self.step_min)
        parts = [self._persona(i), "",
                 f"Now: {WEEKDAYS[(self.sw + d) % 7]} {when.strftime('%B %-d')}, {self._clock(t)}. "
                 f"You are at {self._place_text(i)}.",
                 "How you feel (private): " + self._health(i, dis)]
        mem = self.diary[i][-int(self.cfg["memory_days"]):]
        if mem:
            parts += ["", "Your diary:"] + [f"- {m}" for m in mem]
        if self.chats[i]:
            parts += ["", "Recent conversations:"] + [f"- {m}" for m in self.chats[i]]
        end = self.window_end.get(i, t)
        if end > t:
            menu = self._menu(i, d, t * self.step_min, end * self.step_min)
            self._plan_rooms(i, t, end, menu)
            parts += ["", "Your plan for the rest of today:", self._blocks_text(i, t, end, menu)]
        looks = self._looks(j, dis)
        parts += ["", f"Right next to you is {self._name(j)}: {self._relation(i, j)}." +
                  (f" You notice {looks}." if looks else "")]
        return "\n".join(parts)

    def _transcript(self, i, j, lines):
        if not lines:
            return "Nobody has said anything yet."
        return "Conversation so far:\n" + "\n".join(
            f"- {'You' if a == i else self._name(j)}: \"{s}\"" for a, s, _ in lines)

    def _converse(self, i, j, t, dis):
        """Alternating turns, each from the speaker's own point of view, then one reflection each.
        Returns (lines [(speaker, text, shared_health)], {agent: reflection or None}, {agent: model},
        {agent: menu for the messages in its reflection})."""
        heads = {i: self._talk_head(i, j, t, dis), j: self._talk_head(j, i, t, dis)}
        first = _crc(f"{self.pop.agent_id[i]}|{self.pop.agent_id[j]}|{t}") % 2
        order = (i, j) if first == 0 else (j, i)
        lines, models, menus = [], {}, {}
        for k in range(int(self.talk["max_turns"])):
            sp, other = order[k % 2], order[1 - k % 2]
            user = f"{heads[sp]}\n\n{self._transcript(sp, other, lines)}\n\nYour turn: say your next line, or end."
            resp, models[sp] = self._call_m(self._request(user, TALK_SCHEMA, TALK_SYSTEM))
            if resp is None:
                break
            say = str(resp.get("say", "")).strip()
            if say:
                lines.append((sp, say, bool(resp.get("shared_health"))))
            if resp.get("end"):
                break
        refl = {}
        if lines:
            d = t // self.spd
            for sp, other in ((i, j), (j, i)):
                menus[sp] = menu = self._menu(sp, d, t * self.step_min, (t + self.spd) * self.step_min)
                extra = ""
                if self._can_text(sp):
                    extra = ("\n\n" + self._friends_text(sp) + "\nPlaces for invites (id: description):\n" +
                             "\n".join(f"- {k}: {v[4]}" for k, v in menu.items()))
                user = (f"{heads[sp]}\n\n{self._transcript(sp, other, lines)}{extra}\n\n"
                        "The conversation is over. Reflect: what will you remember, and does it change your day?")
                refl[sp], m = self._call_m(self._request(user, self._reflect_schema(sp, menu), TALK_SYSTEM))
                models[sp] = m or models.get(sp, "")
        return lines, refl, models, menus

    def _conversations(self, t, contacts, dis):
        """Starts a conversation for every pair of Claude agents that has been within talking distance
        for min_minutes (neither asleep; per-pair cooldown and a daily cap per agent)."""
        tc = self.talk
        a, b = np.asarray(contacts["a"], np.int64), np.asarray(contacts["b"], np.int64)
        pairs = []
        if len(a):
            r = np.asarray(contacts["r"], np.int64)
            small = np.asarray(contacts["same_room"], bool) & (r >= 0) & \
                (self.rcap[np.maximum(r, 0)] <= int(tc["small_room_max_capacity"]))
            k = self.mask[a] & self.mask[b] & ~np.asarray(contacts["wall"], bool) & \
                ((np.asarray(contacts["dist"]) <= float(tc["radius_m"])) | small)
            pairs = sorted({(min(x, y), max(x, y)) for x, y in zip(a[k].tolist(), b[k].tolist())})
        self._near = {p: self._near.get(p, 0) + 1 for p in pairs}
        need = max(1, math.ceil(float(tc["min_minutes"]) / self.step_min))
        cool = int(round(float(tc["cooldown_h"]) * 60 / self.step_min))
        d = t // self.spd
        asleep = np.asarray(self.beh.act) == ACT["sleep"]
        busy, jobs = set(), []
        for p in pairs:
            if self._near[p] < need or busy & set(p) or asleep[list(p)].any():
                continue
            if t - self._last_talk.get(p, -cool) < cool:
                continue
            if any(self._talks_day.get((x, d), 0) >= int(tc["max_per_agent_per_day"]) for x in p):
                continue
            busy |= set(p)
            jobs.append(p)
        if not jobs:
            return
        for p in jobs:
            self._last_talk[p] = t
            for x in p:
                self._talks_day[(x, d)] = self._talks_day.get((x, d), 0) + 1
        with ThreadPoolExecutor(max_workers=int(self.cfg["max_workers"])) as ex:
            results = list(ex.map(lambda p: self._converse(p[0], p[1], t, dis), jobs))
        when = (self.start + timedelta(minutes=t * self.step_min)).strftime("%a %b %-d %H:%M")
        aid = self.pop.agent_id
        for (i, j), (lines, refl, models, menus) in zip(jobs, results):
            self.convos.append({"t": t, "agents": [aid[i], aid[j]], "place": self._place_text(i),
                                "lines": [{"speaker": aid[s], "say": x, "shared_health": h} for s, x, h in lines],
                                "reflections": {aid[s]: r for s, r in refl.items()}})
            if lines:
                for sp, other in ((i, j), (j, i)):
                    # disclosure: only speakers with something to tell (symptoms, a pending or positive test)
                    if bool(dis.symptomatic[sp]) or int(self.rep.test_status[sp]) in (1, 2):
                        shared = any(h for s, _, h in lines if s == sp)
                        self._event(sp, t, "disclosure", "", outcome=int(shared), other=other, model=models.get(sp, ""))
                        if shared:
                            self._bump(other, "friend_sick", t, other=sp)
            for sp, other in ((i, j), (j, i)):
                r = refl.get(sp)
                if not r:
                    continue
                self._measure(sp, r, t, "conversation", models.get(sp, ""))
                for m in (r.get("messages") or [])[: int(self.mcfg["max_per_call"])]:
                    self._send(sp, t, m, menus[sp], "reflection")
                if r.get("memory"):
                    self.chats[sp] = (self.chats[sp] + [f"{when} with {self._name(other)}: {r['memory']}"]
                                      )[-int(tc["memory"]):]
                if r.get("replan") and "conversation" in self.cfg["replan_on"]:
                    self.inbox[sp].append(f"{self._clock(t)} you talked with {self._name(other)}. "
                                          + self._transcript(sp, other, lines))
                    self.triggers.setdefault(sp, "conversation")

    # ------------------------------------------------------------------ engine hooks
    def before_step(self, t, dis):
        """Plan (at day start) or re-plan (after a trigger) before Behavior reads plans[:, t]."""
        self._dis, self._now = dis, t
        d = t // self.spd
        jobs = []
        if t % self.spd == self.day_start_step:
            for i in self.idx:
                jobs.append((i, t, min(t + self.spd, self.T), "day"))
                self._obs[i] = []  # reactions to observations are measured on re-plans only
            self.triggers.clear()
        elif self.triggers:
            for i in sorted(self.triggers):
                reason = self.triggers[i]
                end = self.window_end.get(i, 0)
                if end <= t or self.replans.get((i, d), 0) >= int(self.cfg["max_replans_per_day"]):
                    continue
                if reason == "observation":
                    if self._obs_replans.get((i, d), 0) >= int(self.notice["max_observations_per_day"]):
                        continue
                    self._obs_replans[(i, d)] = self._obs_replans.get((i, d), 0) + 1
                self.replans[(i, d)] = self.replans.get((i, d), 0) + 1
                jobs.append((i, t, end, reason))
            self.triggers.clear()
        if jobs:
            self._plan(jobs, dis)
        for mid in [m for m, o in self._open.items() if o["deadline"] <= t]:
            self._resolve(mid, t, force=True)

    def _plan(self, jobs, dis):
        prepared = []
        for i, t0, t1, reason in jobs:
            d = t0 // self.spd
            menu = self._menu(i, d, t0 * self.step_min, t1 * self.step_min)
            self._plan_rooms(i, t0, t1, menu)
            user = self._user_text(i, t0, t1, d, menu, dis, reason)
            prepared.append((i, t0, t1, reason, menu, user, list(self._awaiting[i]),
                             self._request(user, self._schema(i, menu))))
        with ThreadPoolExecutor(max_workers=int(self.cfg["max_workers"])) as ex:
            resps = list(ex.map(self._call_m, [p[-1] for p in prepared]))
        P = self.plans
        for (i, t0, t1, reason, menu, user, shown, _), (resp, model) in zip(prepared, resps):
            old = (P.room[i, t0:t1].copy(), P.act[i, t0:t1].copy(), bool(self.beh.masked[i]))
            ok = resp is not None and self._apply(i, t0, t1, resp, menu)
            self.window_end[i] = t1
            self.inbox[i] = []
            if ok and resp.get("diary"):
                when = self.start + timedelta(minutes=t0 * self.step_min)
                self.diary[i].append(f"{when.strftime('%a %b %-d %H:%M')}: {resp['diary']}")
            self.log.append({"t": t0, "agent_id": self.pop.agent_id[i], "trigger": reason,
                             "applied": bool(ok), "prompt": user, "response": resp})
            if ok:
                self._outcomes(i, t0, t1, reason, resp, model or "", menu, shown, old, dis)

    # ------------------------------------------------------------------ measured outcomes (llm_events.csv)
    def _wlevel(self, i):
        w = self.worry
        return None if w is None else float(w.level[i])

    def _rel_kind(self, i, j):
        """Closest relationship of j to i, in RELATIONS order."""
        pop = self.pop
        if pop.friend_group[i] == pop.friend_group[j]:
            return "friend"
        if int(pop.home_room[i]) >= 0 and pop.home_room[i] == pop.home_room[j]:
            return "roommate"
        if int(pop.home_b[i]) >= 0 and pop.home_b[i] == pop.home_b[j]:
            return "dormmate"
        if int(pop.team_id[i]) >= 0 and pop.team_id[i] == pop.team_id[j]:
            return "teammate"
        if pop.class_schedule is not None and set(pop.class_schedule[i]) & set(pop.class_schedule[j]):
            return "classmate"
        return "stranger"

    def _event(self, i, t, behavior, context, outcome="", value="", other=-1, before=None, after=None, model=""):
        pop, dis = self.pop, self._dis
        bf = getattr(pop, "big_five", None)
        lv = self._wlevel(i)
        row = [t, (self.start + timedelta(minutes=t * self.step_min)).isoformat(), pop.agent_id[i],
               ARCHETYPES[int(pop.archetype[i])]]
        row += [_f(x) for x in bf[i]] if bf is not None else [""] * 5
        row += [_f(pop.compliance[i]), _f(pop.mask_propensity[i]), _f(pop.honesty[i]),
                _f(lv if before is None else before), _f(lv if after is None else after),
                _f(dis.severity[i]) if dis is not None else "", int(bool(dis.symptomatic[i])) if dis is not None else "",
                behavior, context, self._rel_kind(i, other) if other >= 0 else "",
                pop.agent_id[other] if other >= 0 else "", outcome, value, model]
        self.events_rows.append(row)

    def _measure(self, i, resp, t, context, model):
        """Claude's own worry answer (1-5) becomes its worry level."""
        w, v = self.worry, resp.get("worry")
        if w is None or not isinstance(v, (int, float)):
            return
        before = self._wlevel(i)
        w.set_measured(i, (min(max(int(v), 1), 5) - 1) / 4, t)
        after = self._wlevel(i)
        self._event(i, t, "worry", "measured", value=_f(after), before=before, after=after, model=model)

    def _bump(self, i, kind, t, other=-1):
        w = self.worry
        if w is None:
            return
        before = self._wlevel(i)
        w.bump(i, kind, t)
        after = self._wlevel(i)
        self._event(i, t, "worry", kind, value=_f(after), other=other, before=before, after=after)

    def _home(self, i):
        h = int(self.pop.home_room[i])
        return h if h >= 0 else ROOM_OFF_MAP

    def _outcomes(self, i, t0, t1, reason, resp, model, menu, shown, old, dis):
        """After an applied plan: replies to texts, the worry answer, new texts, and llm_events rows for the
        sick response, app compliance and reactions to observations."""
        acc = set(resp.get("accept") or [])
        for mid in shown:
            if mid in self._open and mid in self._awaiting[i]:
                self._claude_reply(mid, i, t0, mid in acc, model)
        self._measure(i, resp, t0, reason, model)
        for m in (resp.get("messages") or [])[: int(self.mcfg["max_per_call"])]:
            self._send(i, t0, m, menu, reason)
        P, vr = self.plans, self.beh.vaden_room
        rooms, acts = P.room[i, t0:t1], P.act[i, t0:t1]
        home = self._home(i)
        if i in self._onset:
            self._onset.discard(i)
            end = t1
            t_end = getattr(dis, "t_end", None)
            if t_end is not None and t0 < int(t_end[i]) < t1:
                end = int(t_end[i])
            w = rooms[: end - t0]
            away = w != home
            out = "vaden" if vr >= 0 and (w == vr).any() else \
                "stay_home" if not (away & (w != vr)).any() else "carry_on"
            self._event(i, t0, "sick_response", reason, outcome=out, value=_f(away.sum() * self.step_min / 60),
                        model=model)
        lead = min(max(1, math.ceil(15 / self.step_min)), len(rooms) - 1)
        for kind, until, room_at in self._advice[i]:
            if kind == "isolate_until":
                h = min(until, t1) if until is not None and until >= 0 else t1
                w = rooms[: max(h - t0, 1)]
                ok = not ((w != home) & (w != vr)).any()
            elif kind == "wear_mask":
                ok = bool(resp.get("wear_mask"))
            elif kind == "leave_location":
                ok = int(rooms[lead]) != room_at
            else:  # go_to_vaden
                ok = vr >= 0 and bool((rooms == vr).any())
            self._event(i, t0, "app_compliance", kind, outcome=int(ok), model=model)
        self._advice[i] = []
        if reason != "day":
            o_room, o_act, o_masked = old
            for cue, room_at, other in self._obs[i]:
                left = int(rooms[lead]) != room_at and int(o_room[lead]) == room_at
                masked = bool(resp.get("wear_mask")) and not o_masked
                changed = bool((rooms != o_room).any() or (acts != o_act).any())
                self._event(i, t0, "notice_reaction", cue, outcome=int(left or masked or changed), other=other,
                            model=model)
        self._obs[i] = []

    # ------------------------------------------------------------------ notice
    def _observe(self, i, t, cue, text, other=-1):
        self.inbox[i].append(text)
        self._obs[i].append((cue, int(self.beh.room[i]), other))
        if "observation" in self.cfg["replan_on"]:
            self.triggers.setdefault(i, "observation")

    def _notice(self, t, contacts, dis):
        """Claude agents notice a visibly sick rule-based agent next to them for min_minutes, or a crowded room.
        The observation goes into their notifications (and may trigger a re-plan); no API call by itself."""
        nc = self.notice
        need = max(1, math.ceil(float(nc["min_minutes"]) / self.step_min))
        cool = int(round(float(nc["cooldown_h"]) * 60 / self.step_min))
        asleep = np.asarray(self.beh.act) == ACT["sleep"]
        a, b = np.asarray(contacts["a"], np.int64), np.asarray(contacts["b"], np.int64)
        pairs = []
        if len(a):
            r = np.asarray(contacts["r"], np.int64)
            small = np.asarray(contacts["same_room"], bool) & (r >= 0) & \
                (self.rcap[np.maximum(r, 0)] <= int(nc["small_room_max_capacity"]))
            k = (self.mask[a] ^ self.mask[b]) & ~np.asarray(contacts["wall"], bool) & \
                ((np.asarray(contacts["dist"]) <= float(nc["radius_m"])) | small)
            sym = np.asarray(dis.symptomatic, bool)
            for x, y in zip(a[k].tolist(), b[k].tolist()):
                ci, o = (x, y) if self.mask[x] else (y, x)
                if sym[o] and not asleep[ci]:
                    pairs.append((ci, o))
            pairs = sorted(set(pairs))
        self._seen = {p: self._seen.get(p, 0) + 1 for p in pairs}
        for p in pairs:
            ci, o = p
            if self._seen[p] < need or t - self._last_seen.get(p, -cool) < cool:
                continue
            self._last_seen[p] = t
            rel = self._relation(ci, o)
            who = "The person" if rel == "someone you don't know" else f"{self._name(o)}, {rel},"
            self._observe(ci, t, "sick_nearby", f"{self._clock(t)} {who} has been next to you in {self._place_text(ci)} "
                          f"for {self._seen[p] * self.step_min} minutes: {self._looks(o, dis)}.", other=o)
            self._bump(ci, "saw_sick", t, other=o)
        thr = int(nc["crowded_occupancy"])
        if thr > 0:
            room = np.asarray(self.beh.room, np.int64)
            occ = np.bincount(room[room >= 0], minlength=len(self.rcap))
            d = t // self.spd
            for ci in self.idx:
                r = int(room[ci])
                prev = self._in_room.get(ci)
                n = prev[1] + 1 if prev and prev[0] == r else 1
                self._in_room[ci] = (r, n)
                if r < 0 or n < need or asleep[ci] or occ[r] < thr or (ci, r, d) in self._crowd_done:
                    continue
                self._crowd_done.add((ci, r, d))
                self._observe(ci, t, "crowded", f"{self._clock(t)} {self._place_text(ci)} is crowded: about "
                              f"{int(occ[r])} people are in the room with you.")

    # ------------------------------------------------------------------ messages and group plans
    def _label_for_others(self, label):
        return label.replace("your ", "their ")

    def _msg_line(self, o):
        rec = o["rec"]
        line = (f"{self._clock(rec['t'])} {self._name(o['i'])} texted {'the group' if rec['group'] else 'you'} "
                f"({rec['kind'].replace('_', ' ')}): \"{rec['text']}\"")
        if o["blk"] is not None:
            line += f" (at {self._label_for_others(rec['place_label'])}, {self._clock(o['blk'][0])})"
        return line

    def _send(self, i, t, m, menu, source):
        """A text from Claude agent i. Rule-based recipients answer at once; Claude recipients in their next plan."""
        if not self._can_text(i) or not isinstance(m, dict) or m.get("kind") not in MSG_KINDS:
            return
        kind, to, friends = m["kind"], m.get("to"), self._friends(i)
        if to == "group":
            rec_to = friends
        else:
            j = self._aid_ix.get(to)
            if j is None or j not in friends:
                return
            rec_to = [j]
        blk, label = None, ""
        if kind == "invite":
            pid = m.get("place")
            lo = t * self.step_min
            sm = self._parse_min(str(m.get("time", "")), (lo // 1440) * 1440, lo) if pid in menu else None
            if sm is None:
                return
            s = int(round(sm / self.step_min))
            e = min(s + int(round(float(self.mcfg["invite_hours"]) * 60 / self.step_min)), self.T)
            if e <= max(s, self._now):
                return
            r, hint, k_ev, k_sec, label = menu[pid]
            a = ACT["off_campus"] if r == ROOM_OFF_MAP else ACT[hint or INVITE_ACT.get(self.rtype[r], "hangout")]
            blk = (s, e, a, r, k_ev, k_sec, label)
        aid = self.pop.agent_id
        mid = f"m{len(self.msgs) + 1}"
        rec = {"id": mid, "t": t, "timestamp": (self.start + timedelta(minutes=t * self.step_min)).isoformat(),
               "from": aid[i], "to": [aid[j] for j in rec_to], "group": to == "group", "kind": kind,
               "place": m.get("place", "") if blk else "", "place_label": label,
               "time": m.get("time", "") if blk else "", "text": str(m.get("text", "")), "source": source,
               "responses": [], "outcome": None}
        self.msgs.append(rec)
        self._open[mid] = {"rec": rec, "i": i, "to": rec_to, "blk": blk, "replies": {},
                           "deadline": blk[0] if blk else t + self.spd}
        for j in rec_to:
            if self.mask[j]:
                self._awaiting[j].append(mid)
                if "message" in self.cfg["replan_on"]:
                    self.triggers.setdefault(j, "message")
            else:
                self._rule_reply(mid, j, t)
        self._resolve(mid, t)

    def _p_accept(self, j, kind, rel):
        """sigmoid(b[kind] + w_A (A - .5) + w_E (E - .5) + w_worry[kind] (worry - baseline) + w_rel[rel])."""
        pc = self.mcfg["p_accept"]
        bf = getattr(self.pop, "big_five", None)
        A, E = (float(bf[j][3]), float(bf[j][2])) if bf is not None else (0.5, 0.5)
        x = float(pc["b"][kind]) + float(pc["w_A"]) * (A - 0.5) + float(pc["w_E"]) * (E - 0.5) + \
            float(pc["w_rel"].get(rel, 0.0))
        lv = self._wlevel(j)
        if lv is not None:
            base = getattr(self.worry, "baseline", None)
            base = float(base[j]) if base is not None else float(self.mcfg["worry_baseline"])
            ww = pc["w_worry"]
            x += float(ww[kind] if isinstance(ww, dict) else ww) * (lv - base)
        return 1.0 / (1.0 + math.exp(-x))

    def _rule_reply(self, mid, j, t):
        o = self._open[mid]
        rec, i, kind = o["rec"], o["i"], o["rec"]["kind"]
        p = self._p_accept(j, kind, self._rel_kind(j, i))
        u = np.random.default_rng([self.seed, _crc(f"msg|{mid}|{self.pop.agent_id[j]}")]).random(2)
        acc, vaden = bool(u[0] < p), False
        if acc and kind != "invite":
            self._bump(j, "warning_text", t, other=i)
            if u[1] < float(self.mcfg["p_vaden"].get(kind, 0.0)):
                vaden = self._to_vaden(j)
        o["replies"][j] = acc
        rec["responses"].append({"agent": self.pop.agent_id[j], "t": t, "by": "rule", "p": round(p, 4),
                                 "accepted": acc, "vaden": vaden})
        self._event(j, t, "influence", kind, outcome=int(acc), value=_f(p), other=i, model="rule")

    def _claude_reply(self, mid, j, t, acc, model):
        o = self._open[mid]
        rec, i, kind = o["rec"], o["i"], o["rec"]["kind"]
        self._awaiting[j].remove(mid)
        if acc and kind != "invite":
            self._bump(j, "warning_text", t, other=i)
        o["replies"][j] = acc
        rec["responses"].append({"agent": self.pop.agent_id[j], "t": t, "by": "claude", "accepted": acc})
        self._event(j, t, "influence", kind, outcome=int(acc), other=i, model=model)
        self._resolve(mid, t)

    def _to_vaden(self, j):
        """Sends a rule-based agent to Vaden (as interventions.apply_actions does for go_to_vaden)."""
        rep = self.rep
        if self.beh.vaden_room < 0 or int(rep.test_status[j]) in (1, 2) or j in rep.vaden:
            return False
        n = max(1, int(round(float(self.mcfg["vaden_visit_min"]) / self.step_min)))
        start = rep.next_vaden_slot(self._now, n)
        self.beh.schedule_vaden(j, start, n)
        rep.register_vaden_visit(j, start, start + n)
        return True

    def _resolve(self, mid, t, force=False):
        """Closes a text once every Claude recipient answered (or its time came). A direct invite happens if
        the recipient says yes, a group invite if group_min people do; then it goes into everyone's plan."""
        o = self._open.get(mid)
        if o is None:
            return
        waiting = [j for j in o["to"] if self.mask[j] and j not in o["replies"]]
        if waiting and not force:
            return
        del self._open[mid]
        rec, aid = o["rec"], self.pop.agent_id
        for j in waiting:
            self._awaiting[j].remove(mid)
            rec["responses"].append({"agent": aid[j], "t": t, "by": "claude", "accepted": None})
        acc = [j for j in o["to"] if o["replies"].get(j)]
        rec["accepted"] = [aid[j] for j in acc]
        if o["blk"] is None:
            rec["outcome"] = "delivered"
            return
        happens = len(acc) >= (int(self.mcfg["group_min"]) if rec["group"] else 1)
        rec["outcome"] = "happened" if happens else "off"
        s, e, a, r, k_ev, k_sec, label = o["blk"]
        if happens:
            for j in [o["i"]] + acc:
                self._insert(j, (s, e, a, r, k_ev, k_sec, f"{codes.ACTIVITIES[a]} at "
                                 f"{label if j == o['i'] else self._label_for_others(label)} ({rec['text']})"))
        names = ", ".join(self._name(j) for j in acc) or "nobody"
        for j in [o["i"]] + list(o["to"]):
            if self.mask[j]:
                where = label if j == o["i"] else self._label_for_others(label)
                self.inbox[j].append(f"{self._clock(t)} the plan for {where} at {self._clock(s)} is "
                                     + (f"on: {names} said yes." if happens else f"off (yes: {names})."))

    def _insert(self, j, blk):
        """Puts an accepted invite into agent j's plan from now on (transit re-inserted)."""
        s, e, a, r, k_ev, k_sec, _ = blk
        t0 = self._now
        if e <= t0:
            return
        t1 = min(self.T, e + self.spd // 12)
        self._paint(j, t0, t1, [(max(s - t0, 0), e - t0, a, r, k_ev, k_sec)], fill=False)
        if self.mask[j]:
            self.commit[j].append(blk)

    def after_step(self, t, dev, actions, contacts=None, dis=None):
        """Collects triggers, runs conversations and observations, and turns the intervention's actions for
        LLM agents into notifications. Returns (actions without LLM agents, {agent: timeline action string})."""
        self._dis, self._now = dis if dis is not None else self._dis, t + 1
        on = set(self.cfg["replan_on"])
        if self.talk["on"] and contacts is not None and dis is not None:
            self._conversations(t, contacts, dis)
        if self.notice["on"] and contacts is not None and dis is not None:
            self._notice(t, contacts, dis)
        for i in np.asarray(dev.get("onset", []), np.int64).tolist():
            if self.mask[i]:
                self._onset.add(int(i))
                if "symptom_onset" in on:
                    self.triggers.setdefault(int(i), "symptom_onset")
        if "test_result" in on:
            for ev in self.rep.events[getattr(self, "_n_ev", 0):]:
                i = ev[1] if isinstance(ev, (tuple, list)) else ev.get("agent", -1)
                kind = ev[2] if isinstance(ev, (tuple, list)) else ev.get("event")
                if kind == "test_result" and 0 <= int(i) < len(self.mask) and self.mask[int(i)]:
                    self.triggers[int(i)] = "test_result"
            self._n_ev = len(self.rep.events)
        notes = {}
        if actions:
            kept = {}
            for i, acts in actions.items():
                i = int(i)
                if not self.mask[i]:
                    kept[i] = acts
                    continue
                for a in acts:
                    until = getattr(a, "until_t", -1)
                    u = (self.start + timedelta(minutes=int(until) * self.step_min)).strftime("%a %b %-d %H:%M") \
                        if until is not None and until >= 0 else "further notice"
                    self.inbox[i].append(f"{self._clock(t)} FlUni app " + ADVICE_TEXT.get(a.kind, a.kind).format(until=u))
                    self._advice[i].append((a.kind, until, int(self.beh.room[i])))
                notes[i] = "|".join(f"advised:{a.kind}" for a in acts)
                if "app_advice" in on:
                    self.triggers.setdefault(i, "app_advice")
            actions = kept
        return actions, notes

    def log_lines(self):
        return [json.dumps(r, sort_keys=True) for r in self.log]

    def convo_lines(self):
        return [json.dumps(r, sort_keys=True) for r in self.convos]

    def message_lines(self):
        return [json.dumps(r, sort_keys=True) for r in self.msgs]

    def events_csv(self):
        """llm_events.csv text: EVENT_COLUMNS, one row per measured decision, in the order they happened."""
        buf = io.StringIO()
        w = csv.writer(buf, lineterminator="\n")
        w.writerow(EVENT_COLUMNS)
        w.writerows(self.events_rows)
        return buf.getvalue()
