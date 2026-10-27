"""Turn a raw recording of your Dug impression into clean, transcribed reference clips.

    python prep_reference.py                      # uses data/raw/*
    python prep_reference.py path/to/take.m4a     # or specific files

Writes:
    data/reference/full.wav         everything, cleaned, 24 kHz mono (XTTS uses this)
    data/reference/clip_XX.wav      3-12 s pieces split at pauses (F5-TTS uses one at a time)
    data/reference/clips.jsonl      {"path", "text", "seconds"} per clip, transcribed by Whisper

Check the transcripts in clips.jsonl and fix any mistakes by hand: F5-TTS leans on them heavily.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import pyloudnorm
import soundfile as sf
import torch
import torchaudio.functional as AF

HERE = Path(__file__).parent
RAW_DIR = HERE / "data" / "raw"
OUT_DIR = HERE / "data" / "reference"

SAMPLE_RATE = 24_000
TARGET_LUFS = -20.0
MIN_CLIP_S, MAX_CLIP_S = 3.0, 12.0  # F5-TTS clips references to 12 s anyway
AUDIO_EXTS = {".wav", ".flac", ".mp3", ".m4a", ".aac", ".ogg", ".opus", ".mov", ".mp4"}


def load_audio(path: Path) -> np.ndarray:
    """Any format ffmpeg understands -> float32 mono at SAMPLE_RATE."""
    try:
        audio, sr = sf.read(path, dtype="float32", always_2d=True)
    except Exception:
        if not shutil.which("ffmpeg"):
            sys.exit(f"Can't read {path.name}: install ffmpeg or convert it to .wav first.")
        with tempfile.TemporaryDirectory() as tmp:
            wav = Path(tmp) / "x.wav"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), str(wav)], check=True)
            audio, sr = sf.read(wav, dtype="float32", always_2d=True)
    mono = torch.from_numpy(audio.mean(axis=1))
    if sr != SAMPLE_RATE:
        mono = AF.resample(mono, sr, SAMPLE_RATE)
    return mono.numpy()


def frame_energy_db(audio: np.ndarray, frame: int) -> np.ndarray:
    n = len(audio) // frame
    frames = audio[: n * frame].reshape(n, frame)
    rms = np.sqrt(np.mean(frames**2, axis=1) + 1e-12)
    return 20 * np.log10(rms)


def trim_and_split(audio: np.ndarray) -> tuple[np.ndarray, list[np.ndarray]]:
    """Trims edge silence and splits at the quietest pauses into MIN..MAX second clips."""
    frame = SAMPLE_RATE // 100  # 10 ms
    db = frame_energy_db(audio, frame)
    voiced = db > db.max() - 40
    if not voiced.any():
        sys.exit("The recording looks silent.")
    first, last = np.argmax(voiced), len(voiced) - np.argmax(voiced[::-1])
    pad = 15  # 150 ms
    start, end = max(0, first - pad), min(len(db), last + pad)
    audio = audio[start * frame : end * frame]
    db = db[start:end]

    # Candidate cut points: frames inside pauses (>= 250 ms below the speech level).
    quiet = db < db.max() - 35
    clips, clip_start = [], 0
    run = 0
    for i, q in enumerate(quiet):
        run = run + 1 if q else 0
        length_s = (i - clip_start) / 100
        if run >= 25 and length_s >= MIN_CLIP_S or length_s >= MAX_CLIP_S:
            cut = i - run // 2 if run else i
            clips.append(audio[clip_start * frame : cut * frame])
            clip_start = cut
            run = 0
    tail = audio[clip_start * frame :]
    if len(tail) / SAMPLE_RATE >= MIN_CLIP_S or not clips:
        clips.append(tail)
    elif clips:
        clips[-1] = np.concatenate([clips[-1], tail])[: int(MAX_CLIP_S * SAMPLE_RATE)]
    return audio, clips


def normalize(audio: np.ndarray) -> np.ndarray:
    meter = pyloudnorm.Meter(SAMPLE_RATE)
    loud = pyloudnorm.normalize.loudness(audio, meter.integrated_loudness(audio), TARGET_LUFS)
    peak = np.abs(loud).max()
    return loud * (0.95 / peak) if peak > 0.95 else loud


def transcribe(paths: list[Path]) -> list[str]:
    from faster_whisper import WhisperModel

    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = WhisperModel("large-v3", device=device, compute_type="float16" if device == "cuda" else "int8")
    texts = []
    for p in paths:
        segments, _ = model.transcribe(str(p), language="en", beam_size=5)
        texts.append(" ".join(s.text.strip() for s in segments).strip())
    return texts


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", type=Path, help=f"audio files (default: everything in {RAW_DIR})")
    args = ap.parse_args()

    inputs = args.inputs or sorted(p for p in RAW_DIR.glob("*") if p.suffix.lower() in AUDIO_EXTS)
    if not inputs:
        sys.exit(f"No recordings found. Put them in {RAW_DIR} (any common audio format).")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for old in OUT_DIR.glob("clip_*.wav"):
        old.unlink()

    full, clips = [], []
    for path in inputs:
        print(f"Loading {path.name}")
        trimmed, pieces = trim_and_split(load_audio(path))
        full.append(trimmed)
        clips.extend(pieces)

    gap = np.zeros(int(0.3 * SAMPLE_RATE), dtype=np.float32)
    full_audio = normalize(np.concatenate([x for a in full for x in (a, gap)]))
    sf.write(OUT_DIR / "full.wav", full_audio, SAMPLE_RATE)

    clip_paths = []
    for i, clip in enumerate(clips):
        p = OUT_DIR / f"clip_{i:02d}.wav"
        sf.write(p, normalize(clip), SAMPLE_RATE)
        clip_paths.append(p)

    print(f"Transcribing {len(clip_paths)} clips with Whisper…")
    texts = transcribe(clip_paths)
    with open(OUT_DIR / "clips.jsonl", "w", encoding="utf-8") as f:
        for p, text, clip in zip(clip_paths, texts, clips):
            row = {"path": p.name, "text": text, "seconds": round(len(clip) / SAMPLE_RATE, 2)}
            f.write(json.dumps(row) + "\n")
            print(f"  {p.name}  {row['seconds']:5.1f}s  {text}")

    total = len(full_audio) / SAMPLE_RATE
    print(f"\nWrote {OUT_DIR}  ({total:.0f} s total, {len(clip_paths)} clips)")
    print("Fix any wrong transcripts in clips.jsonl, then run compare_teachers.py")


if __name__ == "__main__":
    main()
