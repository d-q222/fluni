"""Run the Stanford campus ground-truth simulation.

  python simulate.py --agents 10 --days 14 --step-min 5 --seed 42 \
      --disease influenza --intervention none --out runs/
  python simulate.py --agents 10 --initial-seeds 1 --set disease.transmission_scale=1.5
"""
import argparse

from campussim.config import load_config
from campussim.engine import run


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agents", type=int)
    ap.add_argument("--days", type=int)
    ap.add_argument("--step-min", type=int)
    ap.add_argument("--seed", type=int)
    ap.add_argument("--disease", default="influenza")
    ap.add_argument("--intervention")
    ap.add_argument("--initial-seeds", type=int)
    ap.add_argument("--out")
    ap.add_argument("--config", help="JSON file deep-merged over the defaults")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="override any parameter, e.g. disease.p_asym=0.4 (repeatable)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    run_over = {k: v for k, v in {
        "n_agents": args.agents, "days": args.days, "step_min": args.step_min, "seed": args.seed,
        "intervention": args.intervention, "initial_seeds": args.initial_seeds, "out_dir": args.out,
    }.items() if v is not None}
    cfg = load_config(args.disease, overrides={"run": run_over}, set_args=args.set, config_file=args.config)
    if 1440 % cfg["run"]["step_min"]:
        ap.error("--step-min must divide 1440")
    run(cfg, quiet=args.quiet)


if __name__ == "__main__":
    main()
