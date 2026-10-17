"""Shared enumerations. Arrays store the integer index into these lists; output maps to strings."""

ARCHETYPES = ["studious", "social", "athlete", "stem", "commuter", "homebody"]

DISEASE_STATES = ["S", "E", "I_pre", "I_sym", "I_asym", "R"]
S, E, I_PRE, I_SYM, I_ASYM, R = range(6)
INFECTIOUS_STATES = (I_PRE, I_SYM, I_ASYM)

# Output strings match the d2 mock run (eat/relax/commute/idle/arrived_early).
ACTIVITIES = [
    "sleep", "relax", "class", "lab", "study", "eat", "practice", "gym", "party",
    "hangout", "event", "study_group", "outdoor_leisure", "commute", "off_campus",
    "isolate", "health_visit", "rest", "idle", "arrived_early",
]
ACT = {name: i for i, name in enumerate(ACTIVITIES)}
# Activities a sick "carry on" agent may drop, and that go away when an agent leaves a location.
OPTIONAL_ACTIVITIES = {ACT[a] for a in ("party", "hangout", "event", "study_group", "gym", "outdoor_leisure", "study")}

LOCATION_TYPES = [
    "dorm", "classroom", "lecture_hall", "dining", "library", "gym", "lab", "party_venue",
    "event_venue", "common_room", "outdoor", "health_center", "other",
]

SELF_STATUS = ["none", "might_be_sick", "tested_positive", "recovered"]
TEST_STATUS = ["none", "pending", "positive", "negative"]
# agents_static.sickness_behavior_profile values (agent's dominant response; per-episode draw still varies)
SICK_PROFILES = ["stay_home", "visit_vaden_then_isolate", "carry_on"]
SICK_RESPONSES = SICK_PROFILES
TRANSPORT = ["walk", "bike"]
BEDROOM_TYPES = ("dorm_single", "dorm_double", "dorm_triple", "dorm_quad")
# distance_tier values in contacts output
TIER_LT1, TIER_1_2, TIER_2_5, TIER_SAME_ROOM_FAR = 1, 2, 3, 4

# Special room / location sentinels used in per-agent int arrays
ROOM_OFF_MAP = -1
ROOM_TRANSIT = -2
