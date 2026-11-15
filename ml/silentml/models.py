"""One interface over the two pretrained lip-reading models: USR 2.0 (primary) and Auto-AVSR (fallback).

    reader = load("usr2-large")
    clip = reader.preprocess(session)   # [T, 88, 88] float tensor
    guesses = reader.nbest(clip, n=5)   # best first

Both repos are git submodules in ml/third_party, pinned to one commit. They each ship their own
copy of ESPnet under the same top-level package name, so one process can load models from only
one repo. Run each model in its own process (evaluate.py does).

Checkpoints download from the authors' Google Drive links into
~/Library/Application Support/TacitType/models/lipreading (override with TACIT_MODEL_DIR):

    python -m silentml.models download usr2-large auto-avsr
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace

import numpy as np

# Some ops the models use may lack an MPS kernel. This makes them fall back to the CPU instead of
# failing. It must be set before torch is imported.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

from .preprocess import mouth_rois, model_input  # noqa: E402

THIRD_PARTY = Path(__file__).resolve().parent.parent / "third_party"
DEFAULT_MODEL_DIR = Path("~/Library/Application Support/TacitType/models/lipreading").expanduser()
NBEST = 5


@dataclass(frozen=True)
class Checkpoint:
    repo: str  # folder in ml/third_party
    drive_id: str  # Google Drive file id from the repo's README
    filename: str
    lrs3_wer: float  # visual-only WER the README reports, for reference
    backbone: str | None = None  # USR 2.0 config in conf/model/backbone
    md5_prefix: str | None = None  # Auto-AVSR's README lists the first 5 hex digits


# Links checked against each README at the pinned commit on Nov 15, 2026. The USR 2.0 ones are the
# high-resource fine-tuned checkpoints (LRS3 + VoxCeleb2, and LRS2 + AVSpeech for Huge).
CHECKPOINTS: dict[str, Checkpoint] = {
    "usr2-large": Checkpoint("usr2", "1XDNLfZMv_nn8ALiFmDh3asrJKGC2uHs1", "usr2_large_high.pth", 21.5,
                             backbone="resnet_transformer_large"),
    "usr2-huge": Checkpoint("usr2", "1LzFOTYu45zCLOHGVLQt7pMGjw6jmmo9Y", "usr2_huge_high.pth", 17.6,
                            backbone="resnet_transformer_huge"),
    "usr2-baseplus": Checkpoint("usr2", "18vmJjdem5XPOA8bmizybIW5sLJuHMdRR", "usr2_baseplus_high.pth", 24.8,
                                backbone="resnet_transformer_baseplus"),
    "auto-avsr": Checkpoint("auto_avsr", "1r1kx7l9sWnDOCnaFHIGvOtzuhFyFA88_", "vsr_trlrs2lrs3vox2avsp_base.pth", 20.3,
                            md5_prefix="49f77"),
}


@dataclass
class Hypothesis:
    text: str  # lowercase, as the label normalisation expects
    score: float  # the beam search's total log score


def model_dir() -> Path:
    return Path(os.environ.get("TACIT_MODEL_DIR", DEFAULT_MODEL_DIR)).expanduser()


def checkpoint_path(name: str) -> Path:
    return model_dir() / CHECKPOINTS[name].filename


_active_repo: str | None = None


def _use_repo(repo: str) -> None:
    """Puts one model repo on sys.path. Refuses a second repo, whose packages would clash."""
    global _active_repo
    if _active_repo not in (None, repo):
        raise RuntimeError(f"{_active_repo} is already loaded in this process. Load {repo} models in another process.")
    root = THIRD_PARTY / repo
    if not (root / "README.md").exists():
        raise RuntimeError(f"{root} is empty. Run `git submodule update --init`.")
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    _active_repo = repo


def video_process(name: str):
    """The model repo's own mouth alignment (VideoProcess), without loading the model."""
    repo = CHECKPOINTS[name].repo
    _use_repo(repo)
    if repo == "usr2":
        from preprocessing.video_preprocess import VideoProcess
    else:
        from preparation.detectors.retinaface.video_process import VideoProcess
    return VideoProcess(convert_gray=False)


def default_device() -> str:
    import torch

    return "mps" if torch.backends.mps.is_available() else "cpu"


def _load_state(path: Path) -> dict:
    """Loads a checkpoint's tensors only. weights_only refuses pickled code, so a bad file can't run anything."""
    import torch

    state = torch.load(path, map_location="cpu", weights_only=True)
    if isinstance(state, dict) and "state_dict" in state:
        state = state["state_dict"]
    if any(k.startswith("_orig_mod.") for k in state):
        state = {k.replace("_orig_mod.", "", 1): v for k, v in state.items()}
    if any(k.startswith("model.backbone.") for k in state):
        state = {k.replace("model.backbone.", "", 1): v for k, v in state.items() if k.startswith("model.backbone.")}
    return state


def _hypotheses(hyps, to_text, n: int) -> list[Hypothesis]:
    """The n best distinct texts. Different token paths can spell the same words."""
    out: list[Hypothesis] = []
    seen: set[str] = set()
    for hyp in hyps:
        text = " ".join(to_text([int(t) for t in hyp.yseq[1:]]).lower().split())
        if text in seen:
            continue
        seen.add(text)
        out.append(Hypothesis(text, float(hyp.score)))
        if len(out) == n:
            break
    return out


class LipReader:
    name: str
    device: str
    beam_size: int

    def __init__(self, video_process):
        self._video_process = video_process

    def rois(self, session) -> np.ndarray:
        """[T, 96, 96] uint8 mouth patches aligned the way this model was trained."""
        if session.mouth is None:
            raise ValueError(f"{session.path} has no mouth video")
        return mouth_rois(session.mouth, session.mouth_ts, session.mouth_landmarks, self._video_process)

    def preprocess(self, session):
        """[T, 88, 88] float tensor, ready for nbest."""
        return model_input(self.rois(session))

    def nbest(self, clip, n: int = NBEST) -> list[Hypothesis]:
        raise NotImplementedError

    def _decode_on_cpu(self) -> None:
        """Moves the beam search's scorers (decoder and CTC) to the CPU and leaves the encoder on device.

        ESPnet's batched CTC prefix scorer only knows CUDA or CPU and would mix MPS and CPU tensors.
        The CTC scorer isn't a torch module, so its CTC layers are moved by hand.
        """
        import torch

        self.model.decoder.to("cpu")
        for name in ("ctc", "ctc_v", "ctc_a", "ctc_av"):
            if isinstance(getattr(self.model, name, None), torch.nn.Module):
                getattr(self.model, name).to("cpu")
        self.beam_search.to("cpu")

    def transcribe(self, session, n: int = NBEST) -> tuple[list[Hypothesis], dict]:
        """Preprocesses and decodes a session. Also returns timings in seconds."""
        import torch

        start = time.perf_counter()
        clip = self.preprocess(session)
        prepared = time.perf_counter()
        with torch.inference_mode():
            hyps = self.nbest(clip, n)
        if self.device == "mps":
            torch.mps.synchronize()
        done = time.perf_counter()
        seconds = len(clip) / 25.0
        return hyps, {"video_s": seconds, "preprocess_s": prepared - start, "decode_s": done - prepared}


class USRReader(LipReader):
    """USR 2.0. Mirrors the repo's demo.py, which is its only inference path for one clip."""

    def __init__(self, name: str, checkpoint: Path | None, device: str, beam_size: int = 40,
                 ctc_weight: float = 0.1, penalty: float = 0.0, maxlenratio: float = 1.0, minlenratio: float = 0.0):
        _use_repo("usr2")
        from omegaconf import OmegaConf

        from espnet.nets.batch_beam_search import BatchBeamSearch
        from espnet.nets.pytorch_backend.e2e_asr_transformer import E2E
        from espnet.nets.scorers.length_bonus import LengthBonus
        from utils.utils import UNIGRAM1000_LIST

        super().__init__(video_process(name))
        self.name, self.device, self.beam_size = name, device, beam_size
        self.maxlenratio, self.minlenratio = maxlenratio, minlenratio
        self.tokens = UNIGRAM1000_LIST

        backbone = OmegaConf.load(THIRD_PARTY / "usr2" / "conf" / "model" / "backbone" / f"{CHECKPOINTS[name].backbone}.yaml")
        config = OmegaConf.to_container(OmegaConf.create({"model": {"backbone": backbone}}), resolve=True)
        args = {k: v for k, v in config["model"]["backbone"].items() if k != "_target_"}
        self.model = E2E(len(self.tokens), SimpleNamespace(**args))
        if checkpoint is not None:
            self.model.load_state_dict(_load_state(checkpoint))
        self.model.eval().to(device)

        scorers = self.model.scorers()
        scorers["length_bonus"] = LengthBonus(len(self.tokens))
        self.beam_search = BatchBeamSearch(
            beam_size=beam_size,
            vocab_size=len(self.tokens),
            weights={"decoder": 1.0 - ctc_weight, "ctc": ctc_weight, "length_bonus": penalty},
            scorers=scorers,
            sos=len(self.tokens) - 1,
            eos=len(self.tokens) - 1,
            token_list=self.tokens,
            pre_beam_score_key=None if ctc_weight == 1.0 else "decoder",
        )
        self._decode_on_cpu()

    def _text(self, ids: list[int]) -> str:
        return "".join(self.tokens[i] for i in ids).replace("<eos>", "").replace("▁", " ")

    def nbest(self, clip, n: int = NBEST) -> list[Hypothesis]:
        features = self.model.encoder(xs_v=clip.unsqueeze(0).to(self.device))
        hyps = self.beam_search(x=features.squeeze(0).cpu(), modality="v",
                                maxlenratio=self.maxlenratio, minlenratio=self.minlenratio)
        return _hypotheses(hyps, self._text, n)


class AutoAVSRReader(LipReader):
    """Auto-AVSR visual-only. Mirrors ModelModule.forward and get_beam_search_decoder in lightning.py."""

    def __init__(self, name: str, checkpoint: Path | None, device: str, beam_size: int = 40,
                 ctc_weight: float = 0.1, penalty: float = 0.0):
        _use_repo("auto_avsr")
        from datamodule.transforms import TextTransform
        from espnet.nets.batch_beam_search import BatchBeamSearch
        from espnet.nets.pytorch_backend.e2e_asr_conformer import E2E
        from espnet.nets.scorers.length_bonus import LengthBonus

        super().__init__(video_process(name))
        self.name, self.device, self.beam_size = name, device, beam_size
        self.text_transform = TextTransform()
        tokens = self.text_transform.token_list
        self.model = E2E(len(tokens), "video", ctc_weight=ctc_weight)
        if checkpoint is not None:
            self.model.load_state_dict(_load_state(checkpoint))
        self.model.eval().to(device)

        scorers = self.model.scorers()
        scorers["lm"] = None
        scorers["length_bonus"] = LengthBonus(len(tokens))
        self.beam_search = BatchBeamSearch(
            beam_size=beam_size,
            vocab_size=len(tokens),
            weights={"decoder": 1.0 - ctc_weight, "ctc": ctc_weight, "lm": 0.0, "length_bonus": penalty},
            scorers=scorers,
            sos=self.model.odim - 1,
            eos=self.model.odim - 1,
            token_list=tokens,
            pre_beam_score_key=None if ctc_weight == 1.0 else "decoder",
        )
        self._decode_on_cpu()

    def _text(self, ids: list[int]) -> str:
        import torch

        return self.text_transform.post_process(torch.tensor(ids)).replace("<eos>", "")

    def nbest(self, clip, n: int = NBEST) -> list[Hypothesis]:
        # The repo's VideoTransform yields [T, 1, H, W] and the frontend wants a batch of those.
        x = self.model.frontend(clip.unsqueeze(1).unsqueeze(0).to(self.device))
        x = self.model.proj_encoder(x)
        features, _ = self.model.encoder(x, None)
        hyps = self.beam_search(features.squeeze(0).cpu())
        return _hypotheses(hyps, self._text, n)


def load(name: str, checkpoint: Path | str | None = "default", device: str | None = None,
         beam_size: int = 40) -> LipReader:
    """Builds a model by name (a key of CHECKPOINTS).

    checkpoint "default" reads the downloaded file, a path reads that file (a fine-tuned run, say),
    and None keeps random weights, which only the tests want.
    """
    if name not in CHECKPOINTS:
        raise KeyError(f"unknown model {name!r}. Known: {', '.join(CHECKPOINTS)}")
    if checkpoint == "default":
        checkpoint = checkpoint_path(name)
        if not checkpoint.exists():
            raise FileNotFoundError(f"{checkpoint} is missing. Run `python -m silentml.models download {name}`.")
    path = None if checkpoint is None else Path(checkpoint)
    device = device or default_device()
    reader_type = USRReader if CHECKPOINTS[name].repo == "usr2" else AutoAVSRReader
    return reader_type(name, path, device, beam_size=beam_size)


def _file_digest(path: Path, algorithm: str) -> str:
    digest = hashlib.new(algorithm)
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def download(name: str) -> Path:
    """Fetches a checkpoint from Google Drive. Checks Auto-AVSR's MD5 prefix and prints the SHA-256."""
    import gdown

    spec = CHECKPOINTS[name]
    target = checkpoint_path(name)
    if target.exists():
        print(f"{name}: already at {target}")
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(".partial")
    gdown.download(id=spec.drive_id, output=str(partial), quiet=False)
    if spec.md5_prefix and not _file_digest(partial, "md5").startswith(spec.md5_prefix):
        partial.unlink()
        raise RuntimeError(f"{name}: MD5 doesn't start with {spec.md5_prefix}, so the download is not the published file")
    partial.rename(target)
    print(f"{name}: {target} ({target.stat().st_size / 1e6:.0f} MB, sha256 {_file_digest(target, 'sha256')})")
    return target


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="python -m silentml.models")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list", help="show the models and which checkpoints are on disk")
    fetch = commands.add_parser("download", help="download checkpoints")
    fetch.add_argument("names", nargs="+", choices=list(CHECKPOINTS))
    read = commands.add_parser("transcribe", help="print the n-best list for session folders")
    read.add_argument("--model", required=True, choices=list(CHECKPOINTS))
    read.add_argument("--beam", type=int, default=40)
    read.add_argument("sessions", nargs="+", type=Path)
    args = parser.parse_args(argv)

    if args.command == "list":
        for name, spec in CHECKPOINTS.items():
            state = "downloaded" if checkpoint_path(name).exists() else "not downloaded"
            print(f"{name:14} {spec.repo:10} LRS3 WER {spec.lrs3_wer:4.1f}%  {state}")
    elif args.command == "download":
        for name in args.names:
            download(name)
    else:
        from .data import load_session

        reader = load(args.model, beam_size=args.beam)
        for path in args.sessions:
            session = load_session(path)
            hyps, timing = reader.transcribe(session)
            print(f"{path.name}  {session.manifest.get('promptText')!r}  "
                  f"{timing['decode_s'] + timing['preprocess_s']:.2f} s for {timing['video_s']:.1f} s of video")
            for hyp in hyps:
                print(f"  {hyp.score:8.2f}  {hyp.text}")


if __name__ == "__main__":
    main()
