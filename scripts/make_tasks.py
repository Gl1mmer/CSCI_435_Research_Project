"""Write the task set to data/tasks.jsonl.

    python scripts/make_tasks.py                 seed 435, 30 tasks per family
    python scripts/make_tasks.py --seed 7 --out other.jsonl

The same seed always writes the same file. What a task looks like: src/agentpay/tasks.py.
"""

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# So the script runs from a clean clone without installing the package.
sys.path.insert(0, str(ROOT / "src"))

from agentpay.tasks import make_tasks, save_tasks  # noqa: E402  (needs the line above)


def main():
    parser = argparse.ArgumentParser(description="Write the task set to a JSONL file.")
    parser.add_argument("--seed", type=int, default=435)
    parser.add_argument("--per-family", type=int, default=30)
    parser.add_argument("--out", type=Path, default=ROOT / "data" / "tasks.jsonl")
    args = parser.parse_args()

    tasks = make_tasks(args.seed, args.per_family)
    save_tasks(tasks, args.out)
    # Only the file name: a Windows console cannot always print the full path.
    print(f"wrote {len(tasks)} tasks to {args.out.name}")


if __name__ == "__main__":
    main()
