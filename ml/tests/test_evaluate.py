import json
from pathlib import Path

import numpy as np
import pytest

from silentml.evaluate import (
    MODEL_BUDGET_S,
    char_errors,
    choose,
    normalise,
    sentence_takes,
    summarise,
    update_metrics,
    word_errors,
)

FIXTURES = Path(__file__).parent / "fixtures" / "sessions"


def test_normalise_matches_tacitkit():
    # The same cases as TacitKit's DictationTests, so both sides score text alike.
    assert normalise("The birch canoe, slid! Don't") == ["the", "birch", "canoe", "slid", "don't"]
    assert word_errors("The birch canoe slid", "the birch canoe slid.") == (0, 4)
    assert word_errors("a b c d", "a x c") == (2, 4)
    assert word_errors("a b", "a b c d") == (2, 2)


def test_char_errors():
    assert char_errors("pat", "bat") == (1, 3)
    assert char_errors("sounds good", "sounds good.") == (0, 11)


def take(style, edits, words, seconds=0.5, video=2.0, oracle=None):
    return {"style": style, "hypothesis": "x", "word_edits": edits, "words": words,
            "char_edits": edits, "chars": words * 5, "oracle_word_edits": edits if oracle is None else oracle,
            "seconds": seconds, "video_s": video}


def test_summarise_is_corpus_level():
    result = summarise([take("silent", 1, 4), take("silent", 3, 6, oracle=1), take("aloud", 0, 5), {"style": "aloud", "error": "short"}])
    assert result["silent"]["wer"] == pytest.approx(4 / 10)
    assert result["silent"]["oracle_wer"] == pytest.approx(2 / 10)
    assert result["aloud"]["wer"] == 0
    assert result["skipped"] == 1


def test_summarise_fits_a_line_for_the_five_second_clip():
    takes = [take("silent", 0, 4, seconds=0.2 + 0.1 * v, video=v) for v in (1.0, 2.0, 4.0)]
    speed = summarise(takes)["speed"]
    assert speed["five_second_clip_s"] == pytest.approx(0.7)
    assert speed["fits"] == (0.7 <= MODEL_BUDGET_S)


def model(silent_wer, fits=True):
    return {"silent": {"wer": silent_wer}, "speed": {"fits": fits}}


def test_choose_takes_the_lowest_silent_wer_that_fits():
    choice = choose({"usr2-large": model(0.6), "auto-avsr": model(0.5), "usr2-huge": model(0.3, fits=False)})
    assert choice["model"] == "auto-avsr"


def test_choose_gives_ties_to_usr2():
    assert choose({"auto-avsr": model(0.500), "usr2-large": model(0.503)})["model"] == "usr2-large"


def test_choose_with_nothing_fitting():
    assert choose({"usr2-huge": model(0.3, fits=False)})["model"] is None


def test_sentence_takes_reads_the_fixture():
    takes = list(sentence_takes(FIXTURES))
    # The aloud take has mouth video and a Harvard prompt. The silent one has no mouth video.
    assert [s.manifest["promptId"] for s in takes] == ["harvard-03-07"]
    assert list(sentence_takes(FIXTURES, sittings=["someone-else"])) == []
    assert list(sentence_takes(FIXTURES, test_set=True)) == []


def test_update_metrics_merges_models(tmp_path):
    update_metrics(tmp_path, "usr2-large", model(0.6))
    metrics = update_metrics(tmp_path, "auto-avsr", model(0.5))
    saved = json.loads((tmp_path / "metrics.json").read_text())
    assert set(saved["models"]) == {"usr2-large", "auto-avsr"}
    assert saved["choice"]["model"] == metrics["choice"]["model"] == "auto-avsr"


def test_evaluate_with_a_stub_reader():
    from silentml.evaluate import evaluate
    from silentml.models import Hypothesis
    from synthetic import session

    class Stub:
        def transcribe(self, s, n=5):
            return [Hypothesis("the birch canoe slid", -1.0), Hypothesis("the birch canoe slid on", -2.0)], \
                {"video_s": 1.6, "preprocess_s": 0.01, "decode_s": 0.2}

    clip = session()
    clip.manifest = {"sessionId": "s", "speechStyle": "silent", "promptId": "harvard-01-01",
                     "promptText": "The birch canoe slid on the smooth planks."}
    takes = evaluate(Stub(), [clip], log=lambda _: None)
    assert takes[0]["word_edits"] == 4 and takes[0]["words"] == 8
    assert takes[0]["oracle_word_edits"] == 3
    assert takes[0]["seconds"] == pytest.approx(0.21)
