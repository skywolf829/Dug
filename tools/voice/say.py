"""Speak a line with the chosen teacher (teacher.json).

    python say.py "Is that a squirrel costume?"
    python say.py "Hello!" -o hello.wav --speed 1.1
"""

import argparse
from pathlib import Path

import soundfile as sf

from teacher import HERE, SAMPLE_RATE, Teacher, TeacherConfig


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("text")
    ap.add_argument("-o", "--out", type=Path, default=HERE / "outputs" / "say.wav")
    ap.add_argument("--config", type=Path, default=HERE / "teacher.json")
    ap.add_argument("--speed", type=float)
    ap.add_argument("--seed", type=int, help="different seeds give different takes")
    args = ap.parse_args()

    if not args.config.exists():
        raise SystemExit("No teacher.json yet. Run compare_teachers.py and --pick one.")
    config = TeacherConfig.load(args.config)
    if args.speed:
        config.speed = args.speed
    if args.seed is not None:
        config.seed = args.seed

    args.out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(args.out, Teacher(config).synthesize(args.text), SAMPLE_RATE)
    print(args.out)


if __name__ == "__main__":
    main()
