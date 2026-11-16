"""The lip-reading sidecar the Mac app runs for silent dictation.

    python -m silentml.serve --socket <path> --model auto-avsr --beam 10 [--checkpoint <file>] [--no-correction]

It loads one model once, listens on a Unix socket, and answers newline-delimited JSON. Each line is
one request and gets one reply line with the same id. Requests are handled one at a time.

    {"id": 1, "op": "health"}
    {"id": 2, "op": "transcribe", "session": "<folder>", "start": 81234.75, "end": 81239.5, "n": 5}

The shapes mirror Packages/TacitKit/Sources/TacitKit/Sidecar/SidecarProtocol.swift, and
tests/test_serve.py reads the fixture the Swift tests write.

`health` answers "loading" until the model has loaded and decoded one warm-up clip. The sidecar exits
when its stdin closes. The Mac app holds the other end of that pipe, so a crashed app never leaves
an orphan sidecar holding the model in memory.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import socket
import sys
import threading
import time
from pathlib import Path

import numpy as np

from .constants import SIDECAR_PROTOCOL_VERSION
from .preprocess import MIN_FRAMES, PreprocessError

DEFAULT_HYPOTHESES = 5
MAX_HYPOTHESES = 20
WARMUP_FRAMES = 50
# Exit code for a problem a restart won't fix, such as a missing checkpoint. The app stops retrying.
SETUP_FAILED = 2


class RequestError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def error_reply(request_id: int, code: str, message: str) -> dict:
    return {"id": request_id, "error": {"code": code, "message": message}}


def health_reply(request_id: int, info: dict, ready: bool) -> dict:
    health = {
        "state": "ready" if ready else "loading",
        "model": info["model"],
        "beam": info["beam"],
        "device": info["device"],
        "checkpoint": info["checkpoint"],
        "protocolVersion": SIDECAR_PROTOCOL_VERSION,
        "pid": info["pid"],
    }
    # Swift encodes a nil optional by leaving the key out, so these do too.
    for key in ("correction", "correctionCreatedAt"):
        if info.get(key) is not None:
            health[key] = info[key]
    return {"id": request_id, "health": health}


def transcript_reply(request_id: int, hypotheses, frames: int, timings: dict) -> dict:
    return {
        "id": request_id,
        "transcript": {
            "hypotheses": [{"text": h.text, "score": float(h.score)} for h in hypotheses],
            "frames": int(frames),
            "timings": {key: float(timings[key]) for key in ("load_s", "preprocess_s", "decode_s")},
        },
    }


def parse_request(line: bytes | str) -> dict:
    """Checks one request line. Raises RequestError with code bad_request when it's malformed."""
    try:
        request = json.loads(line)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        raise RequestError("bad_request", f"not JSON: {error}") from None
    if not isinstance(request, dict) or not isinstance(request.get("id"), int):
        raise RequestError("bad_request", "a request needs an integer id")
    op = request.get("op")
    if op == "health":
        return request
    if op != "transcribe":
        raise RequestError("bad_request", f"unknown op {op!r}")
    if not isinstance(request.get("session"), str):
        raise RequestError("bad_request", "transcribe needs a session path")
    for key in ("start", "end"):
        if request.get(key) is not None and not isinstance(request[key], (int, float)):
            raise RequestError("bad_request", f"{key} must be a number")
    n = request.get("n", DEFAULT_HYPOTHESES)
    if not isinstance(n, int) or not 1 <= n <= MAX_HYPOTHESES:
        raise RequestError("bad_request", f"n must be 1 to {MAX_HYPOTHESES}")
    request["n"] = n
    return request


def window(session, start: float | None, end: float | None):
    """The session with only the mouth frames whose timestamps fall inside [start, end]."""
    if session.mouth is None or session.mouth_ts is None or len(session.mouth_ts) == 0:
        raise RequestError("no_mouth", f"{session.path} has no mouth video")
    ts = session.mouth_ts
    keep = np.ones(len(ts), dtype=bool)
    if start is not None:
        keep &= ts >= start
    if end is not None:
        keep &= ts <= end
    count = int(keep.sum())
    if count < MIN_FRAMES:
        raise RequestError("too_short", f"clip has {count} frames, the models need at least {MIN_FRAMES}")
    return dataclasses.replace(session, mouth=session.mouth[keep], mouth_ts=ts[keep],
                               mouth_landmarks=session.mouth_landmarks[keep])


class Sidecar:
    """Answers requests. The reader arrives once the model has loaded, and until then the sidecar is loading."""

    def __init__(self, info: dict, load_session=None, log=None):
        self.info = info
        self.reader = None
        self._load_session = load_session
        self._log = log or (lambda message: print(message, file=sys.stderr, flush=True))

    def set_reader(self, reader) -> None:
        self.reader = reader

    def handle_line(self, line: bytes | str) -> dict:
        request_id = -1
        try:
            request = parse_request(line)
            request_id = request["id"]
            if request["op"] == "health":
                return health_reply(request_id, self.info, ready=self.reader is not None)
            return self.transcribe(request)
        except RequestError as error:
            if error.code != "bad_request" or request_id >= 0:
                self._log(f"request {request_id}: {error.code}: {error.message}")
            return error_reply(request_id, error.code, error.message)
        except Exception as error:  # a model bug must not kill the sidecar
            self._log(f"request {request_id}: internal: {error!r}")
            return error_reply(request_id, "internal", f"{type(error).__name__}: {error}")

    def transcribe(self, request: dict) -> dict:
        if self.reader is None:
            raise RequestError("not_ready", "the model is still loading")
        import torch

        load_session = self._load_session
        if load_session is None:
            from .data import load_session
        started = time.perf_counter()
        try:
            session = load_session(Path(request["session"]))
        except (OSError, ValueError, KeyError) as error:
            raise RequestError("bad_session", f"couldn't read {request['session']}: {error}") from None
        session = window(session, request.get("start"), request.get("end"))
        loaded = time.perf_counter()
        try:
            clip = self.reader.preprocess(session)
        except PreprocessError as error:
            code = "too_short" if "at least" in str(error) else "bad_session"
            raise RequestError(code, str(error)) from None
        prepared = time.perf_counter()
        with torch.inference_mode():
            hypotheses = self.reader.nbest(clip, request["n"])
        if getattr(self.reader, "device", "cpu") == "mps":
            torch.mps.synchronize()
        done = time.perf_counter()
        if not hypotheses:
            raise RequestError("internal", "the beam search returned no hypotheses")
        timings = {"load_s": loaded - started, "preprocess_s": prepared - loaded, "decode_s": done - prepared}
        session_id = session.manifest.get("sessionId", Path(request["session"]).name)
        self._log(f"request {request['id']}: {session_id} {len(clip)} frames, load {timings['load_s']:.3f} s, "
                  f"preprocess {timings['preprocess_s']:.3f} s, decode {timings['decode_s']:.3f} s")
        return transcript_reply(request["id"], hypotheses, len(clip), timings)


def serve_connection(sidecar: Sidecar, connection: socket.socket) -> None:
    """Answers every line on one connection until the client closes it."""
    with connection, connection.makefile("rb") as reader:
        for line in reader:
            if not line.strip():
                continue
            reply = json.dumps(sidecar.handle_line(line), separators=(",", ":")) + "\n"
            try:
                connection.sendall(reply.encode())
            except OSError:
                return


def bind(path: Path) -> socket.socket:
    """Listens on path. A stale socket file is removed, and a live sidecar already on it is an error."""
    if len(os.fsencode(path)) > 103:
        print(f"socket path is too long for macOS ({len(os.fsencode(path))} bytes, max 103): {path}", file=sys.stderr)
        sys.exit(SETUP_FAILED)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(str(path))
        except OSError:
            path.unlink()
        else:
            probe.close()
            print(f"another sidecar is already listening on {path}", file=sys.stderr)
            sys.exit(SETUP_FAILED)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(str(path))
    os.chmod(path, 0o600)
    server.listen(4)
    return server


def accept_forever(sidecar: Sidecar, server: socket.socket) -> None:
    while True:
        try:
            connection, _ = server.accept()
        except OSError:
            return
        serve_connection(sidecar, connection)


def exit_when_stdin_closes(cleanup) -> None:
    def watch():
        try:
            while sys.stdin.buffer.read(4096):
                pass
        except (OSError, ValueError):
            pass
        cleanup()
        os._exit(0)

    threading.Thread(target=watch, name="stdin-watch", daemon=True).start()


def warm_up(reader) -> None:
    """Decodes one blank clip, so the first real request doesn't pay for MPS kernel compilation."""
    import torch

    with torch.inference_mode():
        reader.nbest(torch.zeros(WARMUP_FRAMES, 88, 88), 1)


def main(argv: list[str] | None = None) -> None:
    from .models import CHECKPOINTS, checkpoint_path, default_device, load

    parser = argparse.ArgumentParser(prog="python -m silentml.serve")
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--model", default="auto-avsr", choices=list(CHECKPOINTS))
    parser.add_argument("--beam", type=int, default=10)
    parser.add_argument("--checkpoint", type=Path, help="a fine-tuned checkpoint instead of the downloaded one")
    parser.add_argument("--no-correction", action="store_true", help="ignore alignment_correction.json")
    parser.add_argument("--device", help="mps or cpu (default: mps when available)")
    parser.add_argument("--no-stdin-watch", action="store_true", help="keep running when stdin closes")
    args = parser.parse_args(argv)

    checkpoint = args.checkpoint or checkpoint_path(args.model)
    if not checkpoint.exists():
        print(f"{checkpoint} is missing. Run `make ml-models` or pick a checkpoint in Settings.", file=sys.stderr)
        sys.exit(SETUP_FAILED)
    info = {"model": args.model, "beam": args.beam, "device": args.device or default_device(),
            "checkpoint": str(checkpoint), "pid": os.getpid()}
    sidecar = Sidecar(info)
    server = bind(args.socket)

    def cleanup():
        try:
            args.socket.unlink()
        except OSError:
            pass

    if not args.no_stdin_watch:
        exit_when_stdin_closes(cleanup)
    threading.Thread(target=accept_forever, args=(sidecar, server), name="accept", daemon=True).start()
    print(f"listening on {args.socket}, loading {args.model} at beam {args.beam} on {info['device']}",
          file=sys.stderr, flush=True)

    try:
        started = time.perf_counter()
        reader = load(args.model, checkpoint=checkpoint, device=info["device"], beam_size=args.beam,
                      correction=None if args.no_correction else "default")
        if reader.correction is not None:
            info["correction"] = reader.correction.meta.get("file")
            info["correctionCreatedAt"] = reader.correction.meta.get("createdAt")
        warm_up(reader)
        sidecar.set_reader(reader)
        print(f"ready in {time.perf_counter() - started:.1f} s, correction "
              f"{info.get('correction') or 'off'}", file=sys.stderr, flush=True)
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    except (FileNotFoundError, RuntimeError, ValueError) as error:
        # A setup problem that a restart won't fix. Exit code 2 tells the app not to retry.
        print(f"couldn't load the model: {error}", file=sys.stderr, flush=True)
        cleanup()
        sys.exit(SETUP_FAILED)
    finally:
        cleanup()


if __name__ == "__main__":
    main()
