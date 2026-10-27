"""The "teacher": a big zero-shot voice-cloning model conditioned on your Dug impression.

Nothing is trained at this stage. With ~30 s of audio, these models clone from the reference
directly; fine-tuning only becomes worthwhile with several minutes of recordings.

A teacher is fully described by a small JSON config (see teacher.json after running
compare_teachers.py), so the dataset generator and say.py reproduce exactly what you picked.
"""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
REF_DIR = HERE / "data" / "reference"
SAMPLE_RATE = 24_000  # both backends output 24 kHz


@dataclass
class TeacherConfig:
    backend: str  # "f5" or "xtts"
    name: str = ""
    # f5: one reference clip (<= 12 s) + its exact transcript. xtts: any number of clips.
    ref_clips: list[str] = field(default_factory=list)
    ref_text: str = ""
    speed: float = 1.0
    # f5
    nfe_step: int = 32
    cfg_strength: float = 2.0
    # xtts
    temperature: float = 0.75
    top_p: float = 0.85
    seed: int | None = 1234

    @classmethod
    def load(cls, path: Path) -> TeacherConfig:
        return cls(**json.loads(Path(path).read_text()))

    def save(self, path: Path):
        Path(path).write_text(json.dumps(asdict(self), indent=2) + "\n")


def reference_clips() -> list[dict]:
    """Rows from clips.jsonl written by prep_reference.py."""
    path = REF_DIR / "clips.jsonl"
    if not path.exists():
        raise SystemExit("No reference clips yet. Run prep_reference.py first.")
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


class Teacher:
    """Loads the backend once; call synthesize() as many times as you like."""

    _models: dict[str, object] = {}

    def __init__(self, config: TeacherConfig):
        self.config = config
        self._xtts_latents = None

    def synthesize(self, text: str) -> np.ndarray:
        """Returns float32 mono audio at SAMPLE_RATE."""
        if self.config.backend == "f5":
            return self._f5(text)
        if self.config.backend == "xtts":
            return self._xtts(text)
        raise ValueError(f"unknown backend {self.config.backend!r}")

    # -- F5-TTS: flow matching; strong timbre match from a single short clip --------------------

    def _f5(self, text: str) -> np.ndarray:
        from f5_tts.api import F5TTS

        model = self._models.get("f5") or self._models.setdefault("f5", F5TTS())
        c = self.config
        wav, sr, _ = model.infer(
            ref_file=str(REF_DIR / c.ref_clips[0]),
            ref_text=c.ref_text,
            gen_text=text,
            nfe_step=c.nfe_step,
            cfg_strength=c.cfg_strength,
            speed=c.speed,
            seed=c.seed,
            show_info=lambda *_: None,
            progress=None,
        )
        assert sr == SAMPLE_RATE
        return np.asarray(wav, dtype=np.float32)

    # -- XTTS-v2: autoregressive; can average conditioning over all your clips -------------------

    def _xtts(self, text: str) -> np.ndarray:
        import torch

        if "xtts" not in self._models:
            os.environ.setdefault("COQUI_TOS_AGREED", "1")  # CPML: non-commercial use
            from TTS.api import TTS

            device = "cuda" if torch.cuda.is_available() else "cpu"
            self._models["xtts"] = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(device)
        model = self._models["xtts"].synthesizer.tts_model

        c = self.config
        if self._xtts_latents is None:
            self._xtts_latents = model.get_conditioning_latents(
                audio_path=[str(REF_DIR / p) for p in c.ref_clips], max_ref_length=30, gpt_cond_len=12
            )
        gpt_latent, speaker_embedding = self._xtts_latents
        if c.seed is not None:
            torch.manual_seed(c.seed)
        out = model.inference(
            text, "en", gpt_latent, speaker_embedding,
            temperature=c.temperature, top_p=c.top_p, speed=c.speed, enable_text_splitting=True,
        )
        return np.asarray(out["wav"], dtype=np.float32)
