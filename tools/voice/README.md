# Dug voice tools

This folder builds a text-to-speech voice from **your own Dug impression**. It runs on a PC with an
NVIDIA GPU (written for a 4090).

The plan:

1. **Teacher** (this step). A large voice-cloning model (F5-TTS or XTTS-v2) conditioned on about
   30 s of your impression. It doesn't train anything; it clones from the reference directly.
2. **Dataset.** The teacher speaks a few thousand lines.
3. **Student.** A small Piper voice fine-tuned on that dataset, exported to ONNX, and run on the
   iPhone through sherpa-onnx.

Only use recordings of your own voice (or of someone who has agreed). No movie audio.

## Setup (once)

Use Python 3.11, either in a venv or with conda.

```sh
cd tools/voice
python -m venv .venv
# Windows: .venv\Scripts\activate     Linux/WSL: source .venv/bin/activate

# PyTorch with CUDA first. Get the current command from https://pytorch.org/get-started/locally/
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128
pip install -r requirements.txt
```

You also need **ffmpeg** on your PATH (`winget install ffmpeg` on Windows) for non-WAV
recordings and for F5-TTS's audio loading. The first run downloads the models, a few GB in total.

XTTS-v2 is licensed for non-commercial use only (Coqui Public Model License). F5-TTS's
pretrained weights are CC-BY-NC as well. A personal costume is fine.

## 1. Record

Record about **30 s** of your Dug voice. Use a quiet room with the phone or mic about a hand's
width from your mouth, and no music or other voices. Variety helps more than length: mix excited
lines, questions, and a calm sentence or two. Short pauses between sentences are good, since
the script splits the audio there.

Put the file(s) in **`tools/voice/data/raw/`**. Any format works (`.m4a` voice memos are fine), and
several takes are fine too. Everything under `data/` and `outputs/` is git-ignored, so your
voice never goes into the public repo.

## 2. Prepare the reference

```sh
python prep_reference.py
```

This cleans the audio (trim, loudness-normalize, 24 kHz mono), splits it into 3–12 s clips, and
transcribes each clip with Whisper into `data/reference/clips.jsonl`. **Read the transcripts and
fix any mistakes.** F5-TTS relies on them exactly.

## 3. Compare teachers

```sh
python compare_teachers.py
```

This renders six test lines with each candidate: F5-TTS once per reference clip, and XTTS-v2 at
two temperatures. It also prints each candidate's speed. Then open
**`outputs/compare/index.html`** in a browser and listen side by side.

Pick the winner:

```sh
python compare_teachers.py --pick f5-clip_02
python say.py "Is that a squirrel costume? Wait. No. It is a cat."
```

What to listen for: does it sound like your *impression* (energy, pitch, breathiness), or only
like your normal voice? Are there glitches on long lines or questions? The best F5 reference clip
is usually your most in-character one. If every candidate loses the character, record a few
minutes and we'll fine-tune the teacher.

## Next

- `make_dataset.py`: generate the student's training set with the chosen teacher.
- Piper fine-tune and ONNX export, then a "Your Dug" voice engine in the app.
