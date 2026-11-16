import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest

from silentml.models import Hypothesis
from silentml.serve import Sidecar, accept_forever, bind, health_reply, parse_request, transcript_reply, error_reply
from synthetic import session

FIXTURE = Path(__file__).parent / "fixtures" / "sidecar"
ML = Path(__file__).parents[1]


def jsonl(name: str) -> list[dict]:
    return [json.loads(line) for line in (FIXTURE / name).read_text().splitlines() if line.strip()]


# The fixture is written by SidecarProtocolTests in Swift. These rebuild the same replies in Python.
def test_requests_from_swift_parse():
    health, windowed, whole = (parse_request(json.dumps(r)) for r in jsonl("requests.jsonl"))
    assert health == {"id": 1, "op": "health"}
    assert windowed["op"] == "transcribe" and windowed["n"] == 5
    assert windowed["start"] == 81234.75 and windowed["end"] == 81239.5
    assert windowed["session"].endswith("0A1B2C3D-0000-4000-8000-000000000001")
    assert whole["n"] == 1 and "start" not in whole and "end" not in whole


def test_replies_match_swift():
    ready, loading, transcript, failure = jsonl("replies.jsonl")
    info = {"model": "auto-avsr", "beam": 10, "device": "mps", "checkpoint": "/models/vsr_trlrs2lrs3vox2avsp_base.pth",
            "pid": 4242, "correction": "/models/alignment_correction.json",
            "correctionCreatedAt": "2026-11-16T01:51:50+00:00"}
    assert health_reply(1, info, ready=True) == ready
    assert health_reply(1, {"model": "auto-avsr", "beam": 10, "device": "cpu", "checkpoint": "/models/x.pth",
                            "pid": 7, "correction": None}, ready=False) == loading
    hyps = [Hypothesis("a small creek cut across the field", -3.25), Hypothesis("a small cricket across the field", -4.5)]
    assert transcript_reply(2, hyps, 119, {"load_s": 0.0625, "preprocess_s": 0.125, "decode_s": 0.5}) == transcript
    assert error_reply(3, "too_short", "clip has 5 frames, the models need at least 12") == failure


@pytest.mark.parametrize("line, message", [
    ("not json", "not JSON"),
    ('{"op": "health"}', "integer id"),
    ('{"id": 1, "op": "dance"}', "unknown op"),
    ('{"id": 1, "op": "transcribe"}', "session path"),
    ('{"id": 1, "op": "transcribe", "session": "/s", "start": "x"}', "start must be a number"),
    ('{"id": 1, "op": "transcribe", "session": "/s", "n": 0}', "n must be"),
])
def test_bad_requests_are_refused(line, message):
    reply = Sidecar(INFO).handle_line(line)
    assert reply["error"]["code"] == "bad_request"
    assert message in reply["error"]["message"]


INFO = {"model": "auto-avsr", "beam": 10, "device": "cpu", "checkpoint": "/x.pth", "pid": 1}


class StubReader:
    device = "cpu"

    def __init__(self):
        self.clips = []

    def preprocess(self, s):
        import torch

        self.clips.append(s)
        return torch.zeros(len(s.mouth), 88, 88)

    def nbest(self, clip, n=5):
        return [Hypothesis("sounds good ship it", -1.5), Hypothesis("sounds good sip it", -2.0)][:n]


def stub_sidecar(clip=None):
    clip = clip or session(count=50, t0=1000.0)
    sidecar = Sidecar(INFO, load_session=lambda path: clip, log=lambda _: None)
    reader = StubReader()
    return sidecar, reader


def test_transcribe_waits_for_the_model():
    sidecar, _ = stub_sidecar()
    assert sidecar.handle_line('{"id": 4, "op": "health"}')["health"]["state"] == "loading"
    reply = sidecar.handle_line('{"id": 5, "op": "transcribe", "session": "/s"}')
    assert reply == {"id": 5, "error": {"code": "not_ready", "message": "the model is still loading"}}


def test_transcribe_reads_only_the_window():
    sidecar, reader = stub_sidecar()
    sidecar.set_reader(reader)
    assert sidecar.handle_line('{"id": 1, "op": "health"}')["health"]["state"] == "ready"
    # Frames are 40 ms apart from t = 1000, so [1000.2, 1001.0] holds frames 5 to 25.
    reply = sidecar.handle_line('{"id": 6, "op": "transcribe", "session": "/s", "start": 1000.2, "end": 1001.0, "n": 1}')
    transcript = reply["transcript"]
    assert reply["id"] == 6
    assert transcript["frames"] == 21
    assert transcript["hypotheses"] == [{"text": "sounds good ship it", "score": -1.5}]
    assert set(transcript["timings"]) == {"load_s", "preprocess_s", "decode_s"}
    assert reader.clips[0].mouth_ts[0] == pytest.approx(1000.2)


def test_a_short_window_is_too_short():
    sidecar, reader = stub_sidecar()
    sidecar.set_reader(reader)
    reply = sidecar.handle_line('{"id": 7, "op": "transcribe", "session": "/s", "start": 1000.0, "end": 1000.2}')
    assert reply["error"]["code"] == "too_short"


def test_a_session_without_mouth_video_is_refused():
    clip = session()
    clip.mouth = clip.mouth_ts = clip.mouth_landmarks = None
    sidecar, reader = stub_sidecar(clip)
    sidecar.set_reader(reader)
    assert sidecar.handle_line('{"id": 8, "op": "transcribe", "session": "/s"}')["error"]["code"] == "no_mouth"


def test_an_unreadable_session_is_a_bad_session(tmp_path):
    sidecar = Sidecar(INFO, log=lambda _: None)
    sidecar.set_reader(StubReader())
    reply = sidecar.handle_line(json.dumps({"id": 9, "op": "transcribe", "session": str(tmp_path / "missing")}))
    assert reply["error"]["code"] == "bad_session"


def test_a_model_crash_is_an_internal_error_not_a_dead_sidecar():
    sidecar, reader = stub_sidecar()
    reader.nbest = lambda clip, n=5: 1 / 0
    sidecar.set_reader(reader)
    assert sidecar.handle_line('{"id": 10, "op": "transcribe", "session": "/s"}')["error"]["code"] == "internal"
    assert sidecar.handle_line('{"id": 11, "op": "health"}')["health"]["state"] == "ready"


def test_the_fixture_session_reads_through_the_real_loader():
    fixture = ML / "tests/fixtures/sessions/2026-11-05/0A1B2C3D-0000-4000-8000-000000000001"
    sidecar = Sidecar(INFO, log=lambda _: None)
    sidecar.set_reader(StubReader())
    reply = sidecar.handle_line(json.dumps({"id": 12, "op": "transcribe", "session": str(fixture)}))
    # It holds 5 mouth frames, fewer than the models need.
    assert reply["error"]["code"] == "too_short"
    assert "5 frames" in reply["error"]["message"]


def short_socket_path() -> Path:
    # pytest's tmp_path is too long for a Unix socket path on macOS.
    return Path(tempfile.mkdtemp(prefix="tt-", dir="/tmp")) / "s.sock"


def exchange(path: Path, *requests: dict) -> list[dict]:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(str(path))
        client.sendall(b"".join(json.dumps(r).encode() + b"\n" for r in requests))
        client.shutdown(socket.SHUT_WR)
        data = b""
        while chunk := client.recv(65536):
            data += chunk
    return [json.loads(line) for line in data.splitlines()]


def test_socket_answers_lines_in_order():
    sidecar, reader = stub_sidecar()
    sidecar.set_reader(reader)
    path = short_socket_path()
    server = bind(path)
    threading.Thread(target=accept_forever, args=(sidecar, server), daemon=True).start()
    try:
        assert oct(os.stat(path).st_mode & 0o777) == "0o600"
        replies = exchange(path, {"id": 1, "op": "health"}, {"id": 2, "op": "transcribe", "session": "/s", "n": 2})
        assert [r["id"] for r in replies] == [1, 2]
        assert len(replies[1]["transcript"]["hypotheses"]) == 2
        # One connection per request works too, the way the Mac app connects.
        assert exchange(path, {"id": 3, "op": "health"})[0]["id"] == 3
    finally:
        server.close()
        path.unlink()


def test_bind_replaces_a_stale_socket_and_refuses_a_live_one():
    path = short_socket_path()
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(path))
    stale.close()  # the file stays, with nobody listening
    server = bind(path)
    try:
        with pytest.raises(SystemExit):
            bind(path)
    finally:
        server.close()
        path.unlink()


def test_a_missing_checkpoint_exits_with_the_setup_code(tmp_path):
    result = subprocess.run(
        [sys.executable, "-m", "silentml.serve", "--socket", str(short_socket_path()),
         "--checkpoint", str(tmp_path / "missing.pth")],
        cwd=ML, capture_output=True, text=True, timeout=60)
    assert result.returncode == 2
    assert "missing" in result.stderr


def test_the_sidecar_exits_when_stdin_closes(tmp_path, monkeypatch):
    # A tiny stand-in checkpoint is enough to get past the file check. Loading then fails or succeeds
    # slowly, so this only checks that closing stdin ends the process quickly either way.
    checkpoint = tmp_path / "fake.pth"
    checkpoint.write_bytes(b"")
    path = short_socket_path()
    process = subprocess.Popen(
        [sys.executable, "-m", "silentml.serve", "--socket", str(path), "--checkpoint", str(checkpoint), "--device", "cpu"],
        cwd=ML, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 30
    while not path.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.05)
    process.stdin.close()
    assert process.wait(timeout=30) in (0, 2)
    assert not path.exists()
