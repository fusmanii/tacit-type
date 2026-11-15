"""Scores one lip-reading model on recorded sentence takes: WER, CER and speed.

    python -m silentml.evaluate --data <sessions dir> --model usr2-large --out runs/baseline
    python -m silentml.evaluate --data <sessions dir> --model auto-avsr --out runs/baseline

Each call adds that model to <out>/metrics.json and writes its per-take results to
<out>/<model>.takes.jsonl. After each call the file's "choice" is recomputed: the model with the
lowest silent WER whose speed fits the latency budget, with ties going to USR 2.0 (Phase A).
Run each model in its own call. The two repos can't share a process.
"""

from __future__ import annotations

import argparse
import json
from collections.abc import Iterator
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

# Release to text must take at most 2.5 s for a 5 s utterance. The other stages take the
# 300 ms tail plus 50 ms for the last batches, up to 800 ms of LLM cleanup and 50 ms to insert,
# which leaves 1.3 s for preprocessing and decoding a 5 s clip.
LATENCY_TARGET_S = 2.5
REFERENCE_CLIP_S = 5.0
OTHER_STAGES_S = 0.35 + 0.8 + 0.05
MODEL_BUDGET_S = LATENCY_TARGET_S - OTHER_STAGES_S
# Silent WERs closer than this count as a tie.
TIE = 0.005
SENTENCE_STYLES = ("aloud", "silent")


def normalise(text: str) -> list[str]:
    """Lowercase words with punctuation stripped and apostrophes kept.

    Mirrors `WordErrorRate.normalise` in TacitKit, so Swift and Python score text the same way.
    """
    kept = "".join(c if c.isalpha() or c.isdigit() or c == "'" else " " for c in text.lower())
    return kept.split()


def edit_distance(reference: list, hypothesis: list) -> int:
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        current = [i]
        for j, hyp in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref != hyp)))
        previous = current
    return previous[-1]


def word_errors(reference: str, hypothesis: str) -> tuple[int, int]:
    """(edits, reference words)."""
    ref = normalise(reference)
    return edit_distance(ref, normalise(hypothesis)), len(ref)


def char_errors(reference: str, hypothesis: str) -> tuple[int, int]:
    """(edits, reference characters), over the normalised words joined by single spaces."""
    ref = " ".join(normalise(reference))
    return edit_distance(list(ref), list(" ".join(normalise(hypothesis)))), len(ref)


def sentence_takes(root: Path | str, sittings: list[str] | None = None, test_set: bool = False,
                   styles=SENTENCE_STYLES) -> Iterator:
    """Accepted aloud and silent sentence takes that have mouth video.

    Skips the sync check, neutral takes and dictations (no prompt). test_set keeps only the held-out
    test prompts. Otherwise they are left out, so nothing is ever tuned on them by accident.
    """
    from .data import iter_sessions

    for session in iter_sessions(root):
        manifest = session.manifest
        prompt_id = manifest.get("promptId") or ""
        if manifest.get("speechStyle") not in styles or not manifest.get("promptText"):
            continue
        if prompt_id.startswith(("sync-", "neutral-")) or prompt_id.startswith("test-") != test_set:
            continue
        if sittings and manifest.get("sittingId") not in sittings:
            continue
        if session.mouth is None:
            continue
        yield session


def summarise(takes: list[dict]) -> dict:
    """Corpus WER and CER per speech style, plus speed over all takes."""
    out: dict = {}
    for style in SENTENCE_STYLES:
        rows = [t for t in takes if t["style"] == style and "hypothesis" in t]
        words = sum(t["words"] for t in rows)
        chars = sum(t["chars"] for t in rows)
        out[style] = {
            "takes": len(rows),
            "wer": sum(t["word_edits"] for t in rows) / words if words else None,
            "cer": sum(t["char_edits"] for t in rows) / chars if chars else None,
            "oracle_wer": sum(t["oracle_word_edits"] for t in rows) / words if words else None,
        }
    timed = [t for t in takes if "seconds" in t]
    if timed:
        video = np.array([t["video_s"] for t in timed])
        seconds = np.array([t["seconds"] for t in timed])
        per_second = seconds / video
        if len(set(video.round(2))) > 1:
            slope, intercept = np.polyfit(video, seconds, 1)
            five = float(intercept + slope * REFERENCE_CLIP_S)
        else:
            five = float(np.median(per_second) * REFERENCE_CLIP_S)
        out["speed"] = {
            "seconds_per_video_second_p50": float(np.median(per_second)),
            "seconds_per_video_second_p95": float(np.percentile(per_second, 95)),
            "five_second_clip_s": five,
            "budget_s": MODEL_BUDGET_S,
            "fits": five <= MODEL_BUDGET_S,
        }
    out["skipped"] = sum(1 for t in takes if "error" in t)
    return out


def choose(models: dict) -> dict:
    """Lowest silent WER among models that fit the budget. Ties go to USR 2.0."""
    fitting = {
        name: m for name, m in models.items()
        if m.get("speed", {}).get("fits") and m.get("silent", {}).get("wer") is not None
    }
    if not fitting:
        return {"model": None, "reason": "no model with a silent WER fits the latency budget"}
    best = min(m["silent"]["wer"] for m in fitting.values())
    tied = sorted(n for n, m in fitting.items() if m["silent"]["wer"] - best <= TIE)
    usr = [n for n in tied if n.startswith("usr2")]
    pick = (usr or tied)[0]
    reason = f"lowest silent WER ({fitting[pick]['silent']['wer']:.3f}) among models within the {MODEL_BUDGET_S:.1f} s budget"
    if len(tied) > 1:
        reason += f", tied with {', '.join(n for n in tied if n != pick)}"
    return {"model": pick, "reason": reason}


def evaluate(reader, sessions, log=print) -> list[dict]:
    takes = []
    warmed = False
    for session in sessions:
        manifest = session.manifest
        row = {
            "sessionId": manifest["sessionId"],
            "sittingId": manifest.get("sittingId"),
            "promptId": manifest.get("promptId"),
            "style": manifest["speechStyle"],
            "prompt": manifest["promptText"],
        }
        try:
            if not warmed:
                reader.transcribe(session)  # the first call pays for kernel compilation and caches
                warmed = True
            hyps, timing = reader.transcribe(session)
        except ValueError as error:  # PreprocessError, or a take with no mouth video
            row["error"] = str(error)
            takes.append(row)
            log(f"skip {row['promptId']} {row['style']}: {error}")
            continue
        best = hyps[0].text if hyps else ""
        row["hypothesis"] = best
        row["nbest"] = [{"text": h.text, "score": h.score} for h in hyps]
        row["word_edits"], row["words"] = word_errors(row["prompt"], best)
        row["char_edits"], row["chars"] = char_errors(row["prompt"], best)
        # The best any reranker (the LLM cleanup) could do with this n-best list.
        row["oracle_word_edits"] = min((word_errors(row["prompt"], h.text)[0] for h in hyps), default=row["words"])
        row["video_s"] = timing["video_s"]
        row["seconds"] = timing["preprocess_s"] + timing["decode_s"]
        takes.append(row)
        log(f"{row['style']:6} {row['word_edits']}/{row['words']} {row['seconds']:.2f}s  "
            f"{row['prompt']!r} -> {best!r}")
    return takes


def update_metrics(out: Path, name: str, entry: dict) -> dict:
    path = out / "metrics.json"
    metrics = json.loads(path.read_text()) if path.exists() else {"models": {}}
    metrics["models"][name] = entry
    metrics["choice"] = choose(metrics["models"])
    metrics["updatedAt"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    path.write_text(json.dumps(metrics, indent=2) + "\n")
    return metrics


def main(argv: list[str] | None = None) -> None:
    from . import models

    parser = argparse.ArgumentParser(prog="python -m silentml.evaluate")
    parser.add_argument("--data", type=Path, required=True, help="sessions folder (<day>/<sessionId>/)")
    parser.add_argument("--model", required=True, choices=list(models.CHECKPOINTS))
    parser.add_argument("--checkpoint", type=Path, help="a fine-tuned checkpoint instead of the pretrained one")
    parser.add_argument("--label", help="name in metrics.json (default: the model name)")
    parser.add_argument("--out", type=Path, required=True, help="run folder, for example runs/baseline")
    parser.add_argument("--sitting", action="append", help="only this sittingId (repeatable)")
    parser.add_argument("--test-set", action="store_true", help="score the held-out test prompts only")
    parser.add_argument("--beam", type=int, default=40)
    parser.add_argument("--device", help="mps or cpu (default: mps when available)")
    parser.add_argument("--limit", type=int, help="stop after this many takes")
    args = parser.parse_args(argv)

    reader = models.load(args.model, checkpoint=args.checkpoint or "default", device=args.device, beam_size=args.beam)
    sessions = sentence_takes(args.data, sittings=args.sitting, test_set=args.test_set)
    if args.limit:
        sessions = (s for i, s in zip(range(args.limit), sessions))
    takes = evaluate(reader, sessions)
    if not any("hypothesis" in t for t in takes):
        raise SystemExit("no takes were scored")

    name = args.label or args.model
    args.out.mkdir(parents=True, exist_ok=True)
    with open(args.out / f"{name}.takes.jsonl", "w") as file:
        for take in takes:
            file.write(json.dumps(take) + "\n")
    entry = {
        "model": args.model,
        "checkpoint": str(args.checkpoint or models.checkpoint_path(args.model)),
        "beam": args.beam,
        "device": reader.device,
        "sittings": sorted({t["sittingId"] for t in takes if t.get("sittingId")}),
        "testSet": args.test_set,
        **summarise(takes),
    }
    metrics = update_metrics(args.out, name, entry)
    for style in SENTENCE_STYLES:
        s = entry[style]
        if s["wer"] is not None:
            print(f"{style:6} {s['takes']:3} takes  WER {s['wer']:.1%}  CER {s['cer']:.1%}  n-best oracle WER {s['oracle_wer']:.1%}")
    speed = entry.get("speed")
    if speed:
        print(f"5 s clip in {speed['five_second_clip_s']:.2f} s (budget {speed['budget_s']:.1f} s, "
              f"{'fits' if speed['fits'] else 'too slow'}); p50 {speed['seconds_per_video_second_p50']:.2f} s per video second")
    print(f"choice: {metrics['choice']['model']} ({metrics['choice']['reason']})")
    print(f"wrote {args.out / 'metrics.json'}")


if __name__ == "__main__":
    main()
