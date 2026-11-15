"""Builds each model with random weights and decodes a synthetic clip end to end.

This checks the wiring into each repo (imports, tensor shapes, the beam search and the n-best list),
not accuracy. Each model runs in its own process because the two repos' packages share names.
"""

import json
import subprocess
import sys
from pathlib import Path

import pytest

from silentml.models import CHECKPOINTS

ML = Path(__file__).resolve().parent.parent

SCRIPT = """
import json, sys
sys.path.insert(0, {tests!r})
from synthetic import session
from silentml import models
reader = models.load({name!r}, checkpoint=None, device="cpu", beam_size=3)
hyps, timing = reader.transcribe(session(count=30), n=5)
print(json.dumps({{"texts": [h.text for h in hyps], "scores": [h.score for h in hyps], "timing": timing}}))
"""


@pytest.mark.parametrize("name", ["usr2-baseplus", "auto-avsr"])
def test_random_weights_decode_end_to_end(name):
    pytest.importorskip("torch")
    if not (ML / "third_party" / CHECKPOINTS[name].repo / "README.md").exists():
        pytest.skip("model repos missing. Run `git submodule update --init`.")
    script = SCRIPT.format(tests=str(ML / "tests"), name=name)
    run = subprocess.run([sys.executable, "-c", script], cwd=ML, capture_output=True, text=True, timeout=600)
    assert run.returncode == 0, run.stderr[-3000:]
    result = json.loads(run.stdout.strip().splitlines()[-1])
    assert 1 <= len(result["texts"]) <= 5
    assert len(set(result["texts"])) == len(result["texts"])  # distinct
    assert result["scores"] == sorted(result["scores"], reverse=True)
    assert result["timing"]["video_s"] == pytest.approx(30 / 25)


def test_a_second_repo_in_one_process_is_refused():
    pytest.importorskip("torch")
    script = (
        "from silentml import models\n"
        "models._use_repo('usr2')\n"
        "try:\n    models._use_repo('auto_avsr')\nexcept RuntimeError:\n    print('refused')\n"
    )
    run = subprocess.run([sys.executable, "-c", script], cwd=ML, capture_output=True, text=True)
    assert run.stdout.strip() == "refused", run.stderr
