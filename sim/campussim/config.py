"""Config loading. Every configs/<section>.json becomes cfg[<section>]; configs/diseases.json holds presets,
configs/calibration.json the calibration scenario (scripts/calibration_run.py loads it itself).

cfg = load_config(disease="influenza", overrides={"run": {"n_agents": 10}}, set_args=["disease.p_asym=0.4"])
"""
import copy
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG_DIR = ROOT / "configs"


def deep_update(base, over):
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_update(base[k], v)
        else:
            base[k] = copy.deepcopy(v)
    return base


def _parse_value(s):
    try:
        return json.loads(s)
    except json.JSONDecodeError:
        return s


def apply_set(cfg, assignment):
    """'a.b.c=VALUE' (VALUE parsed as JSON when possible)."""
    key, _, val = assignment.partition("=")
    node = cfg
    parts = key.split(".")
    for p in parts[:-1]:
        node = node.setdefault(p, {})
    node[parts[-1]] = _parse_value(val)


def load_config(disease="influenza", overrides=None, set_args=(), config_file=None):
    cfg = {}
    for f in sorted(CONFIG_DIR.glob("*.json")):
        if f.stem not in ("diseases", "calibration"):
            cfg[f.stem] = json.loads(f.read_text())
    presets = json.loads((CONFIG_DIR / "diseases.json").read_text())
    if disease not in presets:
        raise ValueError(f"unknown disease preset {disease!r}; have {sorted(presets)}")
    cfg["disease"] = copy.deepcopy(presets[disease])
    cfg["disease"]["preset"] = disease
    if config_file:
        deep_update(cfg, json.loads(Path(config_file).read_text()))
    if overrides:
        deep_update(cfg, overrides)
    for a in set_args:
        apply_set(cfg, a)
    return cfg


def config_hash(cfg):
    return hashlib.sha256(json.dumps(cfg, sort_keys=True).encode()).hexdigest()


def code_version():
    """Package version + hash of all source files (deterministic, no git needed)."""
    from . import __version__
    h = hashlib.sha256()
    for f in sorted((ROOT / "campussim").glob("*.py")) + [ROOT / "simulate.py"]:
        if f.exists():
            h.update(f.name.encode())
            h.update(f.read_bytes())
    return f"{__version__}+{h.hexdigest()[:12]}"
