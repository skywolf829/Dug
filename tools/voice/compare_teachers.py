"""Render the same test lines with every candidate teacher, then pick the best by ear.

    python compare_teachers.py                 # all candidates
    python compare_teachers.py --only xtts     # just one backend

Open outputs/compare/index.html in a browser to listen side by side. Each candidate's config
is saved next to its audio; copy the winner to teacher.json:

    python compare_teachers.py --pick f5-clip_02
"""

import argparse
import html
import shutil
import time
from pathlib import Path

import soundfile as sf

from teacher import HERE, SAMPLE_RATE, Teacher, TeacherConfig, reference_clips

OUT_DIR = HERE / "outputs" / "compare"

# Original lines in Dug's style, not quotes from the movie. A mix of short bursts, long
# run-ons, questions, and excitement, because that's where cloned voices tend to break.
TEST_LINES = [
    "Hello! I am wearing a costume. It is also my regular collar.",
    "Is that candy? I would like to smell the candy. I will not eat the candy. Probably.",
    "Wait. Wait. Something moved over there. It was a leaf. I am fine.",
    "You smell like pumpkin and also a little bit like cheese. I like you very much.",
    "My people say I am a good dog, and I have decided that they are correct.",
    "Excuse me, is this your house? It is a very nice house. Can I come in?",
]


def candidates(clips: list[dict], only: str | None) -> list[TeacherConfig]:
    out = []
    if only in (None, "f5"):
        # F5 takes one clip at a time, so try each: the most "in character" clip usually wins.
        for c in clips:
            if c["seconds"] >= 4:
                out.append(TeacherConfig(backend="f5", name=f"f5-{Path(c['path']).stem}",
                                         ref_clips=[c["path"]], ref_text=c["text"]))
    if only in (None, "xtts"):
        all_clips = [c["path"] for c in clips]
        for temp in (0.65, 0.85):
            out.append(TeacherConfig(backend="xtts", name=f"xtts-t{temp}", ref_clips=all_clips, temperature=temp))
    return out


def render(configs: list[TeacherConfig]):
    for config in configs:
        folder = OUT_DIR / config.name
        folder.mkdir(parents=True, exist_ok=True)
        config.save(folder / "teacher.json")
        teacher = Teacher(config)
        t0, audio_s = time.time(), 0.0
        for i, line in enumerate(TEST_LINES):
            wav = teacher.synthesize(line)
            sf.write(folder / f"line_{i}.wav", wav, SAMPLE_RATE)
            audio_s += len(wav) / SAMPLE_RATE
        elapsed = time.time() - t0
        print(f"{config.name:24s} {elapsed:6.1f}s for {audio_s:5.1f}s of audio ({audio_s / elapsed:.1f}x real time)")


def write_index(clips: list[dict]):
    names = sorted(p.name for p in OUT_DIR.iterdir() if (p / "teacher.json").exists())
    refs = "".join(
        f"<li><code>{html.escape(c['path'])}</code> {html.escape(c['text'])}<br>"
        f"<audio controls preload=none src='../../data/reference/{c['path']}'></audio></li>"
        for c in clips
    )
    head = "".join(f"<th>{html.escape(n)}</th>" for n in names)
    rows = "".join(
        f"<tr><td>{html.escape(line)}</td>"
        + "".join(f"<td><audio controls preload=none src='{n}/line_{i}.wav'></audio></td>" for n in names)
        + "</tr>"
        for i, line in enumerate(TEST_LINES)
    )
    (OUT_DIR / "index.html").write_text(f"""<!doctype html><meta charset=utf-8><title>Dug teachers</title>
<style>body{{font:14px system-ui;margin:24px}}table{{border-collapse:collapse}}td,th{{border:1px solid #ccc;padding:6px;vertical-align:top}}
th{{position:sticky;top:0;background:#fff}}audio{{width:180px}}td:first-child{{max-width:260px}}</style>
<h1>Dug teacher comparison</h1><h2>Your reference clips</h2><ul>{refs}</ul>
<h2>Candidates</h2><p>Pick the column that sounds most like your Dug, then run
<code>python compare_teachers.py --pick NAME</code>.</p>
<table><tr><th>Line</th>{head}</tr>{rows}</table>""", encoding="utf-8")
    print(f"\nListen: {OUT_DIR / 'index.html'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", choices=["f5", "xtts"])
    ap.add_argument("--pick", metavar="NAME", help="copy a candidate's config to teacher.json")
    args = ap.parse_args()

    if args.pick:
        src = OUT_DIR / args.pick / "teacher.json"
        if not src.exists():
            raise SystemExit(f"No candidate named {args.pick!r} in {OUT_DIR}")
        shutil.copy(src, HERE / "teacher.json")
        print(f"teacher.json <- {args.pick}")
        return

    clips = reference_clips()
    render(candidates(clips, args.only))
    write_index(clips)


if __name__ == "__main__":
    main()
